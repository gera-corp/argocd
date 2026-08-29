#!/bin/bash
# Усыновление тома драйвером csi-driver-nfs без копирования данных.
# Использование: adopt-to-csi.sh <ns> <workload|none> <pvc>
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/talos}
NS=$1; WL=$2; PVC=$3
say() { echo "  [$(date +%H:%M:%S)] $*"; }
echo "=========== $NS/$PVC ==========="

# --- снять параметры до любых изменений
OLDPV=$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.volumeName}')
PATH_NFS=$(kubectl get pv "$OLDPV" -o jsonpath='{.spec.nfs.path}')
SERVER=$(kubectl get pv "$OLDPV" -o jsonpath='{.spec.nfs.server}')
CAP=$(kubectl get pv "$OLDPV" -o jsonpath='{.spec.capacity.storage}')
MODES=$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.accessModes}')
[ "$SERVER" = "192.168.1.155" ] || { echo "!! PV не на целевом сервере"; exit 1; }
case "$PATH_NFS" in
  /k8s-storage/*) ;;
  *) echo "!! неожиданный путь: $PATH_NFS"; exit 1;;
esac
python3 -c "import yaml" 2>/dev/null || { echo "!! нужен python3 с PyYAML"; exit 1; }
say "каталог: $PATH_NFS  размер: $CAP  режимы: $MODES"
mkdir -p /tmp/csi-adopt
kubectl -n "$NS" get pvc "$PVC" -o yaml > "/tmp/csi-adopt/$NS-$PVC.pvc.yaml"
kubectl get pv "$OLDPV" -o yaml   > "/tmp/csi-adopt/$NS-$PVC.pv.yaml"

# --- погасить нагрузку
REPL=0
if [ "$WL" != "none" ]; then
  REPL=$(kubectl -n "$NS" get "$WL" -o jsonpath='{.spec.replicas}')
  say "останавливаю $WL (реплик $REPL)"
  kubectl -n "$NS" scale "$WL" --replicas=0
  for _ in $(seq 1 60); do
    used=$(kubectl -n "$NS" get pod -o jsonpath="{range .items[*]}{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{'\n'}{end}{end}" 2>/dev/null | grep -c "^${PVC}$" || true)
    [ "$used" = "0" ] && break; sleep 3
  done
  [ "$used" = "0" ] || { echo "!! под всё ещё держит PVC $PVC после ожидания — СТОП"; exit 1; }
fi

# --- КРИТИЧНО: защитить каталог до удаления PVC
say "ставлю reclaimPolicy=Retain на $OLDPV"
kubectl patch pv "$OLDPV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
got=$(kubectl get pv "$OLDPV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')
[ "$got" = "Retain" ] || { echo "!! Retain не применился — СТОП"; exit 1; }

# --- удалить старые объекты (каталог остаётся нетронутым)
kubectl -n "$NS" delete pvc "$PVC" --wait=true --timeout=180s
kubectl delete pv "$OLDPV" --wait=true --timeout=180s

# --- создать статический CSI-PV и PVC
SUB=${PATH_NFS#/k8s-storage/}
NEWPV="csi-${NS}-${PVC}"
NEWPV=$(echo "$NEWPV" | cut -c1-253)
say "создаю $NEWPV -> $PATH_NFS"
python3 - "$NEWPV" "$NS" "$PVC" "$CAP" "$MODES" "$SUB" <<'PY' | kubectl apply -f -
import json, sys, yaml
pv, ns, pvc, cap, modes, sub = sys.argv[1:7]
modes = json.loads(modes)
share = "/k8s-storage/" + sub
print(yaml.safe_dump_all([
 {"apiVersion":"v1","kind":"PersistentVolume","metadata":{"name":pv},
  "spec":{"capacity":{"storage":cap},"accessModes":modes,
    "persistentVolumeReclaimPolicy":"Retain","storageClassName":"nfs-csi",
    "claimRef":{"namespace":ns,"name":pvc},
    "csi":{"driver":"nfs.csi.k8s.io",
      "volumeHandle":"192.168.1.155#k8s-storage/%s#" % sub,
      "volumeAttributes":{"server":"192.168.1.155","share":share}}}},
 {"apiVersion":"v1","kind":"PersistentVolumeClaim","metadata":{"name":pvc,"namespace":ns},
  "spec":{"accessModes":modes,"storageClassName":"nfs-csi","volumeName":pv,
    "resources":{"requests":{"storage":cap}}}},
]))
PY

for _ in $(seq 1 60); do
  [ "$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Bound" ] && break
  sleep 2
done
ph=$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.status.phase}')
drv=$(kubectl get pv "$NEWPV" -o jsonpath='{.spec.csi.driver}')
say "PVC=$ph driver=$drv"
[ "$ph" = "Bound" ] && [ "$drv" = "nfs.csi.k8s.io" ] || { echo "!! не привязался — СТОП"; exit 1; }

# --- поднять нагрузку
if [ "$WL" != "none" ] && [ "$REPL" != "0" ]; then
  kubectl -n "$NS" scale "$WL" --replicas="$REPL"
  kubectl -n "$NS" rollout status "$WL" --timeout=300s
fi
echo "  ГОТОВО: $NS/$PVC на nfs-csi, каталог $PATH_NFS"

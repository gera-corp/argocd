# Переход на csi-driver-nfs — план выполнения

> **Для исполнителя:** реализуется задача за задачей. Шаги отмечаются чекбоксами.
> Роль теста здесь играет проверочная команда с ожидаемым выводом: сначала
> убеждаемся, что проверка не проходит, затем выполняем действие, затем что проходит.

**Цель:** перевести 19 томов с `nfs-subdir-external-provisioner` на `csi-driver-nfs`
без копирования данных и удалить старый провизионер.

**Подход:** статическое усыновление. Новый PV направляется на тот же каталог NFS
через `volumeHandle {server}#{share}#{subdir}`. Данные не двигаются ни при
переезде, ни при откате.

**Стек:** Talos v1.13.9, Kubernetes v1.36.4, ArgoCD, Helm, NFS 192.168.1.155:/k8s-storage

**Спека:** `docs/migrations/2026-08-29-csi-driver-nfs-design.md`

## Глобальные ограничения

- NFS-сервер: `192.168.1.155`, экспорт `/k8s-storage`
- Новый StorageClass: `nfs-csi`, provisioner `nfs.csi.k8s.io`, `onDelete: archive`
- Чарт `csi-driver-nfs` версии `4.13.4`, репозиторий
  `https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts`
- Namespace драйвера: `csi`
- `kubeletDir` оставить по умолчанию `/var/lib/kubelet` (Talos использует его же)
- Снапшоты **вне объёма**: `externalSnapshotter.enabled: false`
- `KUBECONFIG=~/.kube/talos`
- Старый провизионер (helm-релиз `openmediavault` в ns `csi`) не трогать
  до Задачи 7 — он единственный путь отката
- ArgoCD `home-lab` работает с `selfHeal`, ручные правки откатываются;
  на время работ автоматику снимать не нужно, так как PVC и PV не описаны
  в Git напрямую (кроме перечисленных манифестов)

---

### Задача 1: Установить драйвер и проверить его на одноразовом томе

Смысл задачи — убедиться, что CSI-драйвер вообще работает на Talos, **до** того как
трогать настоящие данные.

**Файлы:**
- Создать: `home_cluster/helm_app/csi-nfs/application.yaml`

- [ ] **Шаг 1: Убедиться, что драйвера сейчас нет**

```bash
export KUBECONFIG=~/.kube/talos
kubectl get csidrivers
```
Ожидается: пусто (`No resources found`).

- [ ] **Шаг 2: Создать Application**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: csi-driver-nfs
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  destination:
    name: in-cluster
    namespace: csi
  project: default
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
  source:
    repoURL: 'https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts'
    chart: csi-driver-nfs
    targetRevision: 4.13.4
    helm:
      valuesObject:
        externalSnapshotter:
          enabled: false          # снапшоты — отдельный этап
        controller:
          enableSnapshotter: false
        storageClass:
          create: true
          name: nfs-csi
          parameters:
            server: 192.168.1.155
            share: /k8s-storage
            onDelete: archive     # повторяет archiveOnDelete=true у старого класса
          reclaimPolicy: Delete
          volumeBindingMode: Immediate
          annotations: {}
```

- [ ] **Шаг 3: Закоммитить и синхронизировать**

```bash
git add home_cluster/helm_app/csi-nfs/application.yaml
git commit -m "csi: deploy csi-driver-nfs alongside the legacy provisioner"
git push origin main
kubectl -n argocd annotate application home-lab argocd.argoproj.io/refresh=hard --overwrite
```

- [ ] **Шаг 4: Проверить, что драйвер зарегистрирован**

```bash
kubectl get csidrivers
kubectl -n csi get pod -l app.kubernetes.io/name=csi-driver-nfs
kubectl get sc nfs-csi
```
Ожидается: `nfs.csi.k8s.io` в списке; поды controller и node — `Running` на всех 7 узлах;
класс `nfs-csi` существует. Старый класс `openmediavault-nfs-client` остаётся на месте.

- [ ] **Шаг 5: Проверить драйвер одноразовым динамическим томом**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: csi-smoketest, namespace: csi}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: nfs-csi
  resources: {requests: {storage: 64Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: csi-smoketest, namespace: csi}
spec:
  restartPolicy: Never
  nodeSelector: {kubernetes.io/arch: amd64}
  containers:
  - name: sh
    image: alpine:3.20
    command: ["sh","-c","echo csi-ok > /data/probe && cat /data/probe && sleep 60"]
    volumeMounts: [{name: d, mountPath: /data}]
  volumes:
  - name: d
    persistentVolumeClaim: {claimName: csi-smoketest}
EOF
kubectl -n csi wait --for=condition=Ready pod/csi-smoketest --timeout=180s
kubectl -n csi logs csi-smoketest
```
Ожидается: под становится Ready, в логе `csi-ok`. Это доказывает, что монтирование
CSI-тома на Talos работает.

- [ ] **Шаг 6: Убрать одноразовый том**

```bash
kubectl -n csi delete pod csi-smoketest --wait=true
kubectl -n csi delete pvc csi-smoketest --wait=true
kubectl -n csi get pvc csi-smoketest 2>&1 | grep -q NotFound && echo "убрано"
```
Каталог на NFS останется как `archived-*` из-за `onDelete: archive` — это ожидаемо,
удалить вручную.

---

### Задача 2: Скрипт усыновления и пилот на lldap

**Файлы:**
- Создать: `docs/migrations/adopt-to-csi.sh`

- [ ] **Шаг 1: Написать скрипт**

```bash
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
```

- [ ] **Шаг 2: Проверить синтаксис**

```bash
bash -n docs/migrations/adopt-to-csi.sh && echo "синтаксис OK"
chmod +x docs/migrations/adopt-to-csi.sh
```

- [ ] **Шаг 3: Зафиксировать эталон данных lldap до переезда**

```bash
kubectl -n lldap exec deploy/lldap -- sh -c 'ls -la /data; md5sum /data/users.db'
```
Записать вывод — после переезда должен совпасть.

- [ ] **Шаг 4: Выполнить усыновление**

```bash
./docs/migrations/adopt-to-csi.sh lldap deploy/lldap lldap-data
```
Ожидается: `ГОТОВО`, PVC `Bound`, `driver=nfs.csi.k8s.io`.

- [ ] **Шаг 5: Проверить, что данные те же и сервис жив**

```bash
kubectl -n lldap exec deploy/lldap -- sh -c 'ls -la /data; md5sum /data/users.db'
kubectl -n lldap logs deploy/lldap --tail=20 | grep -i "Starting the LDAP server"
```
Ожидается: `md5sum` совпадает с эталоном из Шага 3; в логе строка о старте LDAP.

- [ ] **Шаг 6: Закоммитить скрипт**

```bash
git add docs/migrations/adopt-to-csi.sh
git commit -m "docs: add zero-copy CSI adoption script"
git push origin main
```

---

### Задача 3: Тома простых Deployment под ArgoCD

Восемь томов, механика идентична пилоту. Перед каждым — правка класса в манифесте.

**Файлы:**
- Изменить: `home_cluster/dockerhub_bot/dockerhub_bot.yaml:59`
- Изменить: `home_cluster/release-bot/release-bot.yaml:54`
- Изменить: `home_cluster/nod32update/nod32update.yaml:87`
- Изменить: `home_cluster/jenkins/jenkins.yaml:101`
- Изменить: `home_cluster/lldap/deployment.yaml:65`
- Изменить: `home_cluster/helm_app/prometheus/prometheus-stack.yaml:209` (grafana)
- Изменить: `home_cluster/helm_app/statedash/application.yaml`, `statedash-demo/application.yaml`, `openclaw/application.yaml` — если класс задан в values

- [ ] **Шаг 1: Перевести класс в манифестах на nfs-csi**

```bash
cd /home/gera/K8S/argocd/argocd
grep -rl "openmediavault-nfs-client" home_cluster/ \
  | xargs sed -i 's/openmediavault-nfs-client/nfs-csi/g'
grep -rn "nfs-csi" home_cluster/ | wc -l   # ожидается 9
```

- [ ] **Шаг 2: Закоммитить, но НЕ синхронизировать**

```bash
git add -A home_cluster/
git commit -m "home_cluster: point PVC declarations at nfs-csi"
git push origin main
```
ArgoCD не пересоздаёт существующие PVC при смене класса (поле иммутабельно,
sync покажет расхождение) — это нормально до усыновления.

- [ ] **Шаг 3: Усыновить тома по возрастанию риска**

```bash
S=./docs/migrations/adopt-to-csi.sh
$S tools          deploy/dockerhub-bot                  dockerhub-bot-data
$S statedash      deploy/statedash                      statedash
$S statedash-demo deploy/statedash-demo                 statedash-demo
$S release-bot    deploy/release-bot                    release-bot-pv
$S openclaw       deploy/openclaw                       openclaw
$S tools          deploy/nod32update                    nod32update-base-pv
$S jenkins        deploy/jenkins                        jenkins-pv
$S monitoring     deploy/kube-prometheus-stack-grafana  kube-prometheus-stack-grafana
```

- [ ] **Шаг 4: Проверить каждый**

```bash
kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName,STATUS:.status.phase | grep -v openmediavault
kubectl get pod -A --no-headers | grep -vE "Running|Completed" | wc -l   # ожидается 0
kubectl -n jenkins exec deploy/jenkins -- ls /var/jenkins_home/jobs      # задания на месте
kubectl -n monitoring exec deploy/kube-prometheus-stack-grafana -c grafana -- ls -la /var/lib/grafana/grafana.db
```

- [ ] **Шаг 5: Проверить, что ArgoCD доволен**

```bash
for a in home-lab kube-prometheus-stack; do
  kubectl -n argocd get application $a -o jsonpath="$a sync={.status.sync.status} health={.status.health.status}{'\n'}"
done
```
Ожидается: `Synced` и `Healthy` у обоих.

---

### Задача 4: Тома простых Deployment под ручным Helm

Два тома: `minio` и `loki-grafana-loki-compactor`. Класс задаётся в values
helm-релиза, не в Git.

- [ ] **Шаг 1: Снять текущие values**

```bash
helm get values minio -n minio -a > /tmp/csi-adopt/minio-values.yaml
helm get values loki  -n loki  -a > /tmp/csi-adopt/loki-values.yaml
grep -n "storageClass" /tmp/csi-adopt/minio-values.yaml /tmp/csi-adopt/loki-values.yaml
```

- [ ] **Шаг 2: Усыновить тома**

```bash
S=./docs/migrations/adopt-to-csi.sh
$S minio deploy/minio                       minio
$S loki  deploy/loki-grafana-loki-compactor loki-grafana-loki-compactor
```

- [ ] **Шаг 3: Проверить**

```bash
kubectl -n minio  get pvc minio -o jsonpath='{.spec.storageClassName}{"\n"}'
kubectl -n loki   get pvc loki-grafana-loki-compactor -o jsonpath='{.spec.storageClassName}{"\n"}'
kubectl -n minio  logs deploy/minio --tail=10
```
Ожидается: `nfs-csi` у обоих, minio стартовал без ошибок.

- [ ] **Шаг 4: Обновить values релизов, чтобы будущие тома шли на новый класс**

Пути значений установлены по факту (`helm get values <rel> -n <ns> -a`):

```bash
helm upgrade minio minio -n minio --reuse-values \
  --set global.defaultStorageClass=nfs-csi
helm upgrade loki  loki  -n loki  --reuse-values \
  --set global.storageClass=nfs-csi
```

Если `helm upgrade` не находит чарт по имени — переустановить из того же источника,
что и текущий релиз (`minio-16.0.10`, `grafana-loki-6.0.6`); версию не менять.
Изменение затрагивает только будущие тома, существующие не пересоздаются.

---

### Задача 5: StatefulSet под ArgoCD — docker-registry и influxdb

`volumeClaimTemplates` иммутабельны, поэтому StatefulSet пересоздаётся при нулевых
репликах; PVC с тем же именем он усыновляет.

- [ ] **Шаг 1: docker-registry (единственный том RWM)**

```bash
kubectl -n tools scale sts/docker-registry --replicas=0
kubectl -n tools wait --for=delete pod/docker-registry-0 --timeout=180s
./docs/migrations/adopt-to-csi.sh tools none docker-registry-pv-docker-registry-0
kubectl -n tools delete sts docker-registry --cascade=orphan
kubectl apply -f home_cluster/docker-registry/docker-registry.yaml
kubectl -n tools rollout status sts/docker-registry --timeout=300s
```

- [ ] **Шаг 2: Проверить registry**

```bash
kubectl -n tools get sts docker-registry -o jsonpath='{.spec.volumeClaimTemplates[0].spec.storageClassName}{"\n"}'
kubectl -n tools exec docker-registry-0 -- wget -qO- http://localhost:5000/v2/_catalog
```
Ожидается: `nfs-csi`; каталог отдаёт список образов.

- [ ] **Шаг 3: influxdb**

```bash
kubectl -n influxdb scale sts/influxdb --replicas=0
kubectl -n influxdb wait --for=delete pod/influxdb-0 --timeout=300s
./docs/migrations/adopt-to-csi.sh influxdb none data-influxdb-0
kubectl -n influxdb delete sts influxdb --cascade=orphan
kubectl apply -f home_cluster/influxDB/influxDB.yaml
kubectl -n influxdb rollout status sts/influxdb --timeout=600s
```

- [ ] **Шаг 4: Проверить influxdb**

```bash
kubectl -n influxdb exec influxdb-0 -- wget -qO- http://localhost:8086/health
kubectl -n influxdb logs influxdb-0 --tail=30 | grep -c "Opened shard"
```
Ожидается: `"status":"pass"`; число открытых шардов совпадает с прежним (был 91).

---

### Задача 6: Prometheus и StatefulSet под ручным Helm

- [ ] **Шаг 1: Prometheus — гасить через CR, StatefulSet пересоздаёт оператор**

```bash
kubectl -n monitoring patch prometheus kube-prometheus-stack-prometheus --type=merge -p '{"spec":{"replicas":0}}'
until [ "$(kubectl -n monitoring get pod prometheus-kube-prometheus-stack-prometheus-0 --no-headers 2>/dev/null | wc -l)" = "0" ]; do sleep 3; done
./docs/migrations/adopt-to-csi.sh monitoring none prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
kubectl -n monitoring patch prometheus kube-prometheus-stack-prometheus --type=merge \
  -p '{"spec":{"replicas":1,"storage":{"volumeClaimTemplate":{"spec":{"storageClassName":"nfs-csi"}}}}}'
kubectl -n monitoring rollout status sts/prometheus-kube-prometheus-stack-prometheus --timeout=600s
```

- [ ] **Шаг 2: Проверить, что история метрик цела**

```bash
kubectl -n monitoring logs prometheus-kube-prometheus-stack-prometheus-0 -c prometheus --tail=60 | grep "WAL replay completed"
```
Ожидается: строка о завершении WAL replay — значит TSDB прочитан целиком.

- [ ] **Шаг 3: loki ingester и querier**

```bash
for x in ingester querier; do
  kubectl -n loki scale sts/loki-grafana-loki-$x --replicas=0
  kubectl -n loki wait --for=delete pod/loki-grafana-loki-$x-0 --timeout=300s
  ./docs/migrations/adopt-to-csi.sh loki none data-loki-grafana-loki-$x-0
  kubectl -n loki delete sts loki-grafana-loki-$x --cascade=orphan
done
helm upgrade loki loki -n loki --reuse-values --set global.storageClass=nfs-csi
kubectl -n loki rollout status sts/loki-grafana-loki-ingester --timeout=600s
kubectl -n loki rollout status sts/loki-grafana-loki-querier  --timeout=600s
```
`global.storageClass` — единственный путь, задающий класс во всём релизе loki
(проверено по `helm get values loki -n loki -a`).

- [ ] **Шаг 4: seafile — redis, mariadb, затем данные**

```bash
for s in seafile-redis-master:redis-data-seafile-redis-master-0 \
         seafile-mariadb:data-seafile-mariadb-0 \
         seafile:seafile-data-seafile-0; do
  sts=${s%%:*}; pvc=${s#*:}
  kubectl -n seafile scale sts/$sts --replicas=0
  kubectl -n seafile wait --for=delete pod/$sts-0 --timeout=300s
  ./docs/migrations/adopt-to-csi.sh seafile none "$pvc"
  kubectl -n seafile delete sts $sts --cascade=orphan
done
helm upgrade seafile /home/gera/K8S/seafile/helm-seafile -n seafile --reuse-values \
  --set seafile.persistence.storageClassName=nfs-csi \
  --set mariadb.global.defaultStorageClass=nfs-csi \
  --set redis.global.storageClass=nfs-csi
kubectl -n seafile rollout status sts/seafile --timeout=900s
```
Чарт локальный: `/home/gera/K8S/seafile/helm-seafile` (версия `seafile-0.1.5`).
Три пути, а не один: mariadb и redis — подчарты Bitnami со своими `global`
(проверено по `helm get values seafile -n seafile -a`).

- [ ] **Шаг 5: Проверить seafile**

```bash
kubectl -n seafile get pod
kubectl -n seafile exec sts/seafile -- sh -c 'ls /shared | head'
curl -sI https://sea.geracorp.org | head -1
```
Ожидается: поды Running, данные на месте, сайт отвечает.

---

### Задача 7: Удалить старый провизионер

Выполняется **только** после подтверждения работоспособности всех 19 томов.

- [ ] **Шаг 1: Убедиться, что на старом классе не осталось ничего**

```bash
kubectl get pvc -A -o jsonpath='{range .items[*]}{.spec.storageClassName}{"\n"}{end}' | sort | uniq -c
kubectl get pv  -o jsonpath='{range .items[*]}{.spec.storageClassName}{"\n"}{end}' | sort | uniq -c
```
Ожидается: только `nfs-csi`, 19 штук. Если есть `openmediavault-nfs-client` — стоп.

- [ ] **Шаг 2: Сохранить конфигурацию релиза на случай отката**

```bash
helm get values   openmediavault -n csi -a > /tmp/csi-adopt/openmediavault-values.yaml
helm get manifest openmediavault -n csi    > /tmp/csi-adopt/openmediavault-manifest.yaml
```

- [ ] **Шаг 3: Удалить релиз**

```bash
helm uninstall openmediavault -n csi
kubectl get sc
```
Ожидается: остался только `nfs-csi`; провизионер удалён вместе с классом.

- [ ] **Шаг 4: Сделать nfs-csi классом по умолчанию**

```bash
kubectl patch sc nfs-csi -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl get sc
```
Ожидается: `nfs-csi (default)`.

- [ ] **Шаг 5: Финальная проверка кластера**

```bash
kubectl get pod -A --no-headers | grep -vE "Running|Completed" | wc -l    # 0
kubectl get pvc -A --no-headers | grep -vc Bound                          # 0
for a in home-lab kube-prometheus-stack csi-driver-nfs; do
  kubectl -n argocd get application $a -o jsonpath="$a {.status.sync.status}/{.status.health.status}{'\n'}"
done
```

- [ ] **Шаг 6: Зафиксировать в Git**

```bash
git commit -am "csi: legacy nfs-subdir provisioner removed, nfs-csi is default"
git push origin main
```

---

## Откат

До Задачи 7 откат любого тома возможен: удалить статический PV и PVC, пересоздать
PVC на классе `openmediavault-nfs-client` со статическим PV на тот же каталог.
Сохранённые манифесты лежат в `/tmp/csi-adopt/<ns>-<pvc>.{pvc,pv}.yaml`.

Данные не двигаются ни при переезде, ни при откате — это главное свойство подхода.

После Задачи 7 откат требует переустановки helm-релиза `openmediavault` из
сохранённых на Шаге 2 values.

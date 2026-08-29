# Переход с nfs-subdir-external-provisioner на csi-driver-nfs

Дата: 2026-08-29. Статус: дизайн согласован, план выполнения — отдельный документ.

## Зачем

`nfs-subdir-external-provisioner` фактически заброшен: последний релиз на GitHub —
март 2023 года. Официальных сборок образа нет уже годы, поэтому в кластере работает
сторонний форк `ghcr.io/starttoaster/nfs-subdir-external-provisioner:v4.0.5`.
sig-storage рекомендует переходить на `csi-driver-nfs`.

Практические следствия текущего состояния:

- Снапшотов томов нет и быть не может — это не CSI, а внешний провизионер,
  создающий PV с заполненным `.spec.nfs`.
- В кластере не зарегистрировано ни одного CSI-драйвера, VolumeSnapshot API отсутствует.
- Отсутствие снапшотов — прямое препятствие к бэкапам, которых сейчас нет вообще.

## Решающий факт: копировать данные не нужно

`csi-driver-nfs` поддерживает статическое провижининг: PV может указывать на
**существующий каталог** через `volumeHandle` формата `{server}#{share}#{subdir}`.

Значит переезд — это подмена объектов PV и PVC, а не перенос 56 ГБ. Даунтайм
измеряется секундами на сервис.

Второй существенный факт: удаление старого провизионера **не ломает существующие
тома**. Они in-tree (`.spec.nfs`), их монтирует kubelet напрямую; провизионер нужен
только для создания и удаления. Это даёт запас прочности на всех этапах.

## Что ставится

`csi-driver-nfs` 4.13.4 (релиз 2026-07-01, репозиторий пушится ежедневно) отдельным
ArgoCD Application в `home_cluster/helm_app/csi-nfs/`, namespace `csi`.
`kubeletDir` чарта по умолчанию `/var/lib/kubelet` — Talos использует его же.

StorageClass:

```yaml
provisioner: nfs.csi.k8s.io
parameters:
  server: 192.168.1.155
  share: /k8s-storage
  onDelete: archive
reclaimPolicy: Delete
allowVolumeExpansion: true
```

`onDelete: archive` повторяет нынешнюю семантику `archiveOnDelete: "true"`: удаление
PVC переименовывает каталог, а не стирает его.

## Процедура усыновления одного тома

```
1. scale нагрузки → 0, дождаться исчезновения подов
2. kubectl patch pv <old> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
3. записать: путь каталога, размер, accessModes
4. удалить PVC, затем PV
5. создать статический CSI-PV на тот же каталог + PVC с прежним именем
6. scale нагрузки → 1, проверка
```

Шаблон статического PV:

```yaml
spec:
  capacity: {storage: 100Mi}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-csi
  claimRef: {namespace: lldap, name: lldap-data}
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: 192.168.1.155#k8s-storage/lldap-lldap-data-pvc-c27ad134-...#
    volumeAttributes:
      server: 192.168.1.155
      share: /k8s-storage/lldap-lldap-data-pvc-c27ad134-...
```

`claimRef` заранее привязывает PV к конкретному PVC, иначе его может перехватить
чужой claim. `volumeHandle` обязан быть уникальным в пределах кластера.

### Критический порядок

**Шаг 2 обязателен и предшествует шагу 4.** Если удалить PVC, пока у PV стоит
`reclaimPolicy: Delete`, старый провизионер отработает `archiveOnDelete` и
переименует каталог в `archived-*` — статический PV будет указывать в пустоту.

Данные при этом не теряются (архив остаётся), но восстановление потребует ручного
переименования каталога обратно.

## Три системы управления — учитывать при правках

| Система | Что под ней |
|---|---|
| ArgoCD | `home-lab`, `kube-prometheus-stack`, `openclaw`, `statedash`, `statedash-demo`, `traefik`, `x509-certificate-exporter`, `telebot` |
| Flux | `infrastructure/talos/homelab` из `ssh://git@github.com/gera-corp/fluxcd.git` |
| Helm вручную | `loki`, `minio`, `seafile`, а также сам `openmediavault` (провизионер) |

Семь томов из девятнадцати (`loki` ×3, `minio`, `seafile` ×3) принадлежат
helm-релизам, установленным напрямую. Их значения меняются `helm upgrade`,
а не коммитом в репозиторий.

## Инвентарь: 19 томов

| Namespace | PVC | Размер | Режим | Владелец | Тип | Управление |
|---|---|---|---|---|---|---|
| lldap | lldap-data | 100Mi | RWO | deploy/lldap | volume | ArgoCD |
| tools | dockerhub-bot-data | 100Mi | RWO | deploy/dockerhub-bot | volume | ArgoCD |
| statedash | statedash | 64Mi | RWO | deploy/statedash | volume | ArgoCD |
| statedash-demo | statedash-demo | 128Mi | RWO | deploy/statedash-demo | volume | ArgoCD |
| release-bot | release-bot-pv | 50M | RWO | deploy/release-bot | volume | ArgoCD |
| jenkins | jenkins-pv | 5G | RWO | deploy/jenkins | volume | ArgoCD |
| monitoring | kube-prometheus-stack-grafana | 5Gi | RWO | deploy/kube-prometheus-stack-grafana | volume | ArgoCD |
| tools | nod32update-base-pv | 5Gi | RWO | deploy/nod32update | volume | ArgoCD |
| openclaw | openclaw | 5Gi | RWO | deploy/openclaw | volume | ArgoCD |
| loki | loki-grafana-loki-compactor | 8Gi | RWO | deploy/loki-grafana-loki-compactor | volume | Helm вручную |
| minio | minio | 8Gi | RWO | deploy/minio | volume | Helm вручную |
| tools | docker-registry-pv-docker-registry-0 | 5G | **RWM** | sts/docker-registry | ШАБЛОН | ArgoCD |
| influxdb | data-influxdb-0 | 5G | RWO | sts/influxdb | ШАБЛОН | ArgoCD |
| monitoring | prometheus-…-prometheus-0 | 32Gi | RWO | sts/prometheus-… | ШАБЛОН | ArgoCD (оператор) |
| loki | data-loki-grafana-loki-ingester-0 | 8Gi | RWO | sts/loki-…-ingester | ШАБЛОН | Helm вручную |
| loki | data-loki-grafana-loki-querier-0 | 8Gi | RWO | sts/loki-…-querier | ШАБЛОН | Helm вручную |
| seafile | redis-data-seafile-redis-master-0 | 8Gi | RWO | sts/seafile-redis-master | ШАБЛОН | Helm вручную |
| seafile | data-seafile-mariadb-0 | 8Gi | RWO | sts/seafile-mariadb | ШАБЛОН | Helm вручную |
| seafile | seafile-data-seafile-0 | 10Gi | RWO | sts/seafile | ШАБЛОН | Helm вручную |

Точные имена каталогов снимаются перед выполнением: они содержат UUID старого PV
и меняются при любом пересоздании тома.

## Восемь томов через volumeClaimTemplates

`volumeClaimTemplates` иммутабельны. Есть два варианта, и они различаются по риску:

**Вариант «отложенный»** — пересоздать только PVC, шаблон StatefulSet не трогать.
StatefulSet усыновляет существующий PVC по имени и не сверяет его spec с шаблоном.
Работает сразу, но оставляет мину: если StatefulSet когда-нибудь пересоздадут или
добавят реплику, он попробует создать PVC на уже удалённом классе и упрётся.

**Вариант «полный»** — пересоздать StatefulSet с новым классом в шаблоне
(`delete --cascade=orphan` при нулевых репликах, затем apply). Дороже на один шаг,
но без мины.

Выбран полный вариант. Для `prometheus` пересоздание StatefulSet выполняет сам
оператор при смене класса в CR — вручную делать не нужно.

## Порядок

Пилот: `lldap-data` (148 КБ, простой Deployment, проверяется логином в LDAP).
Затем по возрастанию риска: `dockerhub-bot` → `statedash` → `statedash-demo` →
`release-bot` → `openclaw` → `nod32update` → `jenkins` → `grafana` → `minio` →
`loki-compactor`, затем StatefulSet'ы: `docker-registry` → `influxdb` →
`loki-ingester` → `loki-querier` → `prometheus` → `seafile-redis` →
`seafile-mariadb` → `seafile-data`.

`seafile-data` (16 ГБ реальных данных, пользовательские файлы) идёт последним.

## Проверка

По каждому тому до запуска нагрузки: PVC `Bound`, у PV `driver: nfs.csi.k8s.io`,
каталог тот же, содержимое на месте. После запуска — прикладная проверка,
как при миграции 2026-08-29 (логин lldap, каталог registry, health influxdb,
targets prometheus, дашборды grafana).

Отдельная проверка после первого тома: смонтировался ли CSI-том вообще. Если
драйвер не работает на Talos, это выяснится на 148 КБ, а не на 16 ГБ.

## Откат

На любом шаге до удаления старого провизионера: удалить статический PV и PVC,
пересоздать PVC на классе `openmediavault-nfs-client` со статическим PV на тот же
каталог. Данные не двигаются ни при переезде, ни при откате — это главное свойство
выбранного подхода.

Старый провизионер и класс удаляются последними, отдельным шагом, после
подтверждения работоспособности всех девятнадцати томов.

## Финал

Удалить helm-релиз `openmediavault` в ns `csi` и StorageClass
`openmediavault-nfs-client`. Класс `nfs-csi` сделать default.

## Вне объёма

**Снапшоты.** Требуют CRD и snapshot-controller (в кластере отсутствуют, чарт умеет
ставить их через `externalSnapshotter.enabled`). Выносятся в отдельный этап
осознанно, чтобы не смешивать переезд томов с новой подсистемой.

**Последствие статического подхода:** усыновлённые тома перестают быть
динамическими. Удаление PVC не приведёт к очистке каталога — чистить придётся
руками. Для домашнего кластера это скорее страховка, чем неудобство, но знать
об этом нужно.

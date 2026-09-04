# Переход Jenkins с собственных манифестов на официальный Helm-чарт

Дата: 2026-09-04. Статус: дизайн согласован, план выполнения — отдельный документ.

## Зачем

Jenkins — последний крупный сервис в репозитории, собранный из написанного вручную
Deployment'а. Всё, что чарт делает сам — установка плагинов, раскладка JCasC,
RBAC для планирования агентов, сервисы контроллера и агент-листенера — здесь
воспроизведено своими руками и с тех пор не сверялось с апстримом.

Три следствия, которые видны прямо сейчас:

- **Плагины плывут.** initContainer качает их без версий прямо в
  `/var/jenkins_home/plugins`, поэтому каждый рестарт пода подтягивает latest.
  В git записаны 12 имён, а на томе стоят 96 плагинов, из которых 18
  верхнеуровневых: `github-branch-source`, `pipeline-model-definition`, `favorite`
  и другие пришли через UI и не описаны нигде.
- **Сборка с нуля даст другой Jenkins.** Из этого репозитория воспроизводится
  не то, что работает, а только его часть.
- **Расхождение с апстримом накапливается молча.** Ни одного механизма, который
  показал бы, что чарт уже делает что-то иначе, нет.

Версия Jenkins при этом не меняется: чарт 5.9.56 несёт appVersion 2.568.3 — ровно
тот образ, что стоит сейчас.

## Что стоит сейчас

`home_cluster/jenkins/`, синкается app-of-apps `home-lab` (`path: home_cluster`,
`recurse: true`):

| Объект | Файл |
| --- | --- |
| Deployment `jenkins` + PVC `jenkins-pv` | `jenkins.yaml` |
| ConfigMap `jenkins-casc-config` | `configmap.yaml` |
| Service `jenkins-http`, `jenkins-agent`, `jk-agnt-packer`, IngressRoute | `service.yaml` |
| Secret `docker-registry-geracorp-login` | `secrets.yaml` |
| ServiceAccount `jenkins-admin`, Role `jenkins`, RoleBinding | `workers/sa.yaml` |

Данные: PVC `jenkins-pv` привязан по `volumeName` к статическому PV
`csi-jenkins-jenkins-pv` (`reclaimPolicy: Retain`), это NFS-каталог
`192.168.1.155:/k8s-storage/jenkins-jenkins-pv-pvc-2389b713-d6ae-4a44-810e-66055e6a92f2`,
590 МБ в 3296 файлах. Корень тома — `root:472`, режим `0777` с setgid.

## Решающий факт: чарт при дефолтах не трогает JENKINS_HOME

Это то, на чём держится вся миграция, поэтому проверено по шаблонам чарта, а не
по документации.

initContainer чарта запускает `apply_config.sh`. При `overwritePlugins: false` и
`JCasC.overwriteConfiguration: false` (оба — дефолты) скрипт:

- пишет два файла состояния мастера установки;
- ставит плагины в `$JENKINS_REF/plugins` — это **emptyDir**, а не том с данными;
- копирует их оттуда через `yes n | cp -i`, то есть существующее не перезаписывает;
- раскладывает JCasC в `$JENKINS_HOME/casc_configs`.

`rm -rf` есть ровно в двух ветках, и обе выключены: `overwritePlugins` сносит
`$JENKINS_HOME/plugins/*`, `JCasC.overwriteConfiguration` — `config.xml` и
`*configuration*.xml`. Ни ту, ни другую не включаем.

Второй факт того же рода: **ArgoCD не делает `helm install`**, он рендерит
`helm template` и применяет результат. Никаких helm-метаданных релиза, никакого
усыновления по `helm.sh/release-name` — объекты просто перезаписываются на месте.

## Что становится чартом, а что остаётся манифестом

Новый `home_cluster/helm_app/jenkins/application.yaml` — Application на
`jenkins/jenkins` из `https://charts.jenkins.io`, `targetRevision: 5.9.*`,
namespace `jenkins`, sync-wave `3`, `prune` + `selfHeal` + `ServerSideApply`,
как у остальных в этом каталоге. Диапазон версий чарта безопасен: версия Jenkins
задана отдельно в `controller.image.tag` и от бампа чарта не зависит.

Чарт берёт на себя: StatefulSet `jenkins`, Service `jenkins` и `jenkins-agent`,
ConfigMap `jenkins` с JCasC и `plugins.txt`, ServiceAccount `jenkins-admin`,
Role и RoleBinding `jenkins-schedule-agents`.

В `home_cluster/jenkins/` остаётся:

- **`pvc.yaml`** — PVC `jenkins-pv`, вынесенный из `jenkins.yaml`;
- `secrets.yaml` — без изменений;
- `service.yaml` — только `jk-agnt-packer` и IngressRoute.

Удаляются `jenkins.yaml`, `configmap.yaml` и `workers/sa.yaml` целиком.

### Почему PVC не отдаём чарту

У claim'а стоит `volumeName: csi-jenkins-jenkins-pv` — поле, которое чарт не
рендерит вообще и знать о нём не может. Без него claim уедет на динамически
созданный пустой том. Отдать чарту нечего, а просто удалить PVC из git нельзя:
ArgoCD его пропрунит, PV уйдёт в `Released`, и `existingClaim` окажется в
пустоте. Поэтому claim остаётся собственным манифестом, а чарт получает
`persistence.existingClaim: jenkins-pv`.

Это тот же приём, что уже применён к PV в `home_cluster/storage/`, и та же
причина, что описана в README для minio.

### Имя ServiceAccount не меняется

`vaultKubernetesCredential` ходит в Vault по роли `auth/talos/role/default`,
и к какому имени SA она привязана, из кластера не видно (root-токен достать не
удалось). Переименование SA — риск без выигрыша, поэтому чарт создаёт его под
прежним именем: `serviceAccount.create: true`, `name: jenkins-admin`.

Побочное расхождение: старая Role даёт `secrets: get`, чартовая
`jenkins-schedule-agents` — нет. Все credentials приходят из Vault, у kubernetes-облака
`credentialsId` пустой, так что право выглядит мёртвым. **Проверить до ката.**

## Три места, где сознательно отходим от дефолтов чарта

### `fsGroup: 472`, а не 1000

У драйвера `nfs.csi.k8s.io` в кластере `fsGroupPolicy: File` — то есть fsGroup
применяется. Корень тома сейчас `root:472`. Дефолтные `fsGroup: 1000` при
`fsGroupChangePolicy: OnRootMismatch` дадут несовпадение и заставят kubelet
рекурсивно сменить группу на 3296 файлах по NFS: в лучшем случае долгий старт,
в худшем — под встанет намертво, если сервер не разрешит chown.

Оставляем ровно то, что работает сегодня, через `podSecurityContextOverride`.
Несовпадения нет — kubelet не делает ничего.

### `pullPolicy: IfNotPresent`, а не `Always`

Как сейчас. Образ закреплён по тегу, а лишний поход в registry на каждый старт
пода домашнему кластеру не нужен.

### `resources` с текущих значений

Дефолты чарта — 4 ГиБ / 2 CPU в лимитах против нынешних 2 ГиБ / 1 CPU. Меняем
способ доставки, а не аппетиты сервиса.

## Плагины: с плавающих latest на фиксированные версии

В `installPlugins` едут все 18 верхнеуровневых плагинов с версиями, снятыми с
работающего тома, `installLatestPlugins: false`, `overwritePlugins: false`.

На существующий том это не влияет **никак**: плагины уже лежат в
`$JENKINS_HOME/plugins`, а чарт кладёт свои в emptyDir, откуда entrypoint
копирует только отсутствующее. Список нужен ровно для одного — чтобы сборка
с нуля дала тот же Jenkins.

Цена: рестарт пода перестаёт молча обновлять плагины. Обновление становится
коммитом в git, как и версии чартов.

## Дельта JCasC

Посчитана машинно: отрендеренные чартом файлы `casc_configs` слиты в один
документ и сопоставлены с текущим `configmap.yaml` по плоским путям.

**Добавится** — всё это явная запись значений, которые и так действуют по
умолчанию:

```
jenkins.mode = NORMAL
jenkins.projectNamingStrategy = standard
jenkins.markupFormatter = plainText
jenkins.slaveAgentPort = 50000
jenkins.clouds[0].kubernetes.{connectTimeout=5, readTimeout=15,
    maxRequestsPerHostStr=32, retentionTimeout=5, waitForPodSec=600,
    skipTlsVerify, usageRestricted, restrictedPssSecurityContext,
    addMasterProxyEnvVars = false, credentialsId = "",
    defaultsProviderTemplate = "", serverUrl = https://kubernetes.default,
    podLabels[0] = jenkins/jenkins-jenkins-agent: "true"}
security.apiToken.{creationOfLegacyTokenEnabled = false,
    tokenGenerationOnCreationEnabled = false, usageStatisticsEnabled = true}
```

Таймауты облака совпадают с дефолтами kubernetes-плагина. Блок
`security.apiToken` требовал отдельной проверки — файла
`jenkins.security.ApiTokenProperty.xml` на томе нет, значит настройка сейчас на
дефолтах Jenkins, а они с 2.129 ровно такие же. Расхождения нет.

**Пропадёт:**

```
jenkins.crumbIssuer = standard
jenkins.labelAtoms[0..3]
jenkins.clouds[0].kubernetes.containerCap = 10
```

`crumbIssuer` чарт намеренно не рендерит для Jenkins ≥ 2.543, где стандартный
issuer встроен. `labelAtoms` — косметика из старого экспорта UI, Jenkins
перегенерирует их сам. `containerCap` дублировался `containerCapStr: "10"`,
который остаётся.

**Изменится ровно одно значение:**

```
jenkins.clouds[0].kubernetes.jenkinsUrl: http://jenkins-http:8080 -> http://jenkins:8080
```

Прямое следствие переименования сервиса контроллера.

Всё остальное — `securityRealm` с LDAP, `projectMatrix`, восемь vault-credentials,
seedjob, `globalNodeProperties`, `appearance`, `hashicorpVault`,
`ansiColorBuildWrapper`, `gitHostKeyVerificationConfiguration` — совпадает
структурно и по значениям.

## Раскладка JCasC по values

`defaultConfig: true`: чарт генерирует базу и kubernetes-облако из `agent.*`.
`securityRealm` и `authorizationStrategy` передаются ему отдельными значениями —
чарт подставляет их вместо своих дефолтов (локальный админ и
`loggedInUsersCanDoAnything`).

podTemplate агента задан сырым YAML через `agent.podTemplates` при
`disableDefaultAgent: true`. Иначе нельзя: у jnlp-контейнера есть
`hostPort: 30001`, а шаблон `jenkins.casc.podTemplate` порты на jnlp не рендерит.

Тремя `configScripts` уезжают дословно: `globals` (административные мониторы,
переменные окружения нод, тема, проверка ssh-ключей, `hashicorpVault`,
`ansiColorBuildWrapper`), `credentials` и `jobs`.

`sidecars.configAutoReload.enabled: false` — JCasC применяется на старте пода,
как и сейчас. Включить горячую перезагрузку можно потом одной строкой.

`controller.testEnabled: false` — чтобы чарт не рендерил ConfigMap `jenkins-tests`
и тестовый Pod. ArgoCD ресурсы с `helm.sh/hook: test` и так пропускает, но
не рендерить их надёжнее, чем полагаться на это.

`admin.createSecret: false` — вход по LDAP, чартовый админский секрет не нужен.

### Сводка: всё, что отличается от дефолтов чарта

| Значение | Ставим | Почему |
| --- | --- | --- |
| `controller.image.tag` | `2.568.3-lts-jdk25` | как сейчас; версия не меняется |
| `controller.image.pullPolicy` | `IfNotPresent` | как сейчас; дефолт `Always` |
| `controller.jenkinsUrl` | `https://jenkins.local.geracorp.work` | из `unclassified.location` |
| `controller.numExecutors` | `2` | как сейчас; дефолт `0` |
| `controller.customJenkinsLabels` | `[master]` | даёт `labelString: "master"` |
| `controller.legacyRemotingSecurityEnabled` | `true` | как сейчас |
| `controller.cloudName` | `Kubernetes` | как сейчас; дефолт `kubernetes` |
| `controller.resources` | 2 ГиБ / 1 CPU | как сейчас; дефолт вдвое больше |
| `controller.podSecurityContextOverride` | `fsGroup: 472`, `supplementalGroups: [0]`, `runAsUser: 1000` | не провоцировать chown 3296 файлов по NFS |
| `controller.containerEnv` | `LDAP_USER`, `LDAP_USER_PASS` | vault-ссылки для bank-vaults |
| `controller.installPlugins` | 18 штук с версиями | воспроизводимость сборки с нуля |
| `controller.installLatestPlugins` | `false` | версии фиксированы |
| `controller.sidecars.configAutoReload.enabled` | `false` | JCasC применяется на старте, как сейчас |
| `controller.admin.createSecret` | `false` | вход по LDAP |
| `controller.testEnabled` | `false` | не рендерить тестовый Pod |
| `controller.JCasC.securityRealm` | LDAP | вместо чартового локального админа |
| `controller.JCasC.authorizationStrategy` | `projectMatrix` | вместо `loggedInUsersCanDoAnything` |
| `controller.JCasC.configScripts` | `globals`, `credentials`, `jobs` | дословно из текущего конфига |
| `persistence.existingClaim` | `jenkins-pv` | существующий том |
| `serviceAccount.create` / `name` | `true` / `jenkins-admin` | прежнее имя, чарт становится владельцем |
| `agent.disableDefaultAgent` | `true` | podTemplate задаём сырым YAML |
| `agent.podTemplates.jenkins-agent` | текущий шаблон дословно | `hostPort` чарт не рендерит |
| `agent.containerCap` | `10` | как сейчас |
| `agent.jenkinsUrl` / `jenkinsTunnel` | `http://jenkins:8080` / `jenkins-agent:50000` | новое имя сервиса |

Проверено `helm template`: рендерятся ровно семь объектов — ServiceAccount,
ConfigMap, Role, RoleBinding, два Service и StatefulSet. PVC чарт не создаёт,
админский секрет и тестовый Pod — тоже.

## Порядок ката

1. **Бэкап.** На OMV `cp -a` каталога тома рядом. 590 МБ, дело секунд. PV и так
   `Retain`, но копия страхует не от удаления claim'а, а от порчи данных —
   кривого chown или двух Jenkins на одном томе.
2. **Погасить Deployment вручную:** `kubectl -n jenkins scale deploy/jenkins
   --replicas=0`, дождаться исчезновения пода.
3. Смержить ветку в `main` одним коммитом.
4. ArgoCD синкает: пруном уходят Deployment, ConfigMap, старые Role и
   RoleBinding, два Service; поднимается StatefulSet.
5. Проверка (ниже).
6. Убрать копию тома с OMV, когда всё устоится.

### Критический порядок: шаг 2 идёт до шага 3

Deployment `jenkins` и StatefulSet `jenkins` — объекты разных типов. Они не
вытесняют друг друга и спокойно существуют рядом, а том у них один. Два живых
Jenkins, пишущих в один `JENKINS_HOME`, — это и есть тот способ потерять данные,
от которого защищает вся остальная конструкция. `prune` в ArgoCD снимет старый
Deployment, но не раньше, чем создаст новый StatefulSet.

Поэтому реплики гасятся руками и до мержа. Автоматизировать это PreSync-хуком
можно, но одноразовая процедура того не стоит.

## Предварительная обкатка на копии тома

Перед катом развернуть чарт в отдельном namespace `jenkins-test` поверх **копии**
данных, сделанной на шаге 1: второй статический PV на каталог копии, свой PVC,
тот же Application с изменёнными namespace и claim.

Это проверяет главное, чего не покажет ни один `helm template`: что Jenkins
поднимается на существующем `JENKINS_HOME`, что init-контейнер не портит
плагины, что LDAP и Vault отвечают, что `readOnlyRootFilesystem: true` (новое
ограничение, у нынешнего Deployment'а его нет) не конфликтует с инжектом
`vault-env` от bank-vaults.

После проверки namespace удаляется вместе с временным PV и копией.

## Проверка

- под `jenkins-0` в `Running`, init-контейнер отработал без ошибок;
- `/login` отвечает, вход по LDAP работает под учёткой из `jenkins-users`;
- `ls /var/jenkins_home/plugins/*.jpi | wc -l` — по-прежнему 96;
- в UI видны jobs `Proxmox` и `seedjob`, история сборок на месте;
- все восемь credentials резолвятся из Vault (Manage Jenkins → Credentials);
- тестовый билд на агенте с меткой `jenkins-nomad-worker` запускается и
  завершается;
- `jk-agnt-packer` по-прежнему селектит под агента (метку `jenkins/label`
  ставит kubernetes-плагин, миграция на это не влияет);
- `argocd app get jenkins` и `home-lab` — оба `Synced` и `Healthy`.

## Откат

`git revert` мержа плюс удаление Application `jenkins`. ArgoCD восстановит
Deployment из вернувшегося `jenkins.yaml`.

Данные при откате не участвуют: том тот же самый, `Retain`, никто его не
пересоздаёт. Именно поэтому откат дёшев, и именно поэтому шаг 2 обязателен —
единственный сценарий, где откат не спасает, это порча самого `JENKINS_HOME`.

## Вне объёма

- Обновление версии Jenkins. Образ остаётся `2.568.3-lts-jdk25`; менять способ
  доставки и версию одновременно незачем.
- Обновление плагинов. Версии фиксируются на тех, что работают сегодня.
- Горячая перезагрузка JCasC (`configAutoReload`) — отдельным решением после того,
  как переезд устоится.
- Бэкап `JENKINS_HOME` на постоянной основе. Разовая копия здесь — часть
  процедуры, а не решение задачи бэкапов; она заслуживает отдельного захода.

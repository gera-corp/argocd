# Переезд Jenkins на официальный Helm-чарт — план выполнения

> **Для исполнителя:** реализуется задача за задачей. Шаги отмечаются чекбоксами.
> Роль теста здесь играет проверочная команда с ожидаемым выводом: сначала
> убеждаемся, что проверка не проходит, затем выполняем действие, затем что проходит.

**Цель:** заменить самописные манифесты Jenkins официальным чартом `jenkins/jenkins`,
не потеряв 590 МБ данных в `JENKINS_HOME` и не поменяв версию Jenkins.

**Подход:** гибридный JCasC — чарт генерирует базу и kubernetes-облако из своих
values, а LDAP-realm, матрица прав, credentials и seedjob передаются ему дословно.
PVC остаётся собственным манифестом, чарт получает `existingClaim`. Перед катом
конфигурация обкатывается на копии тома в отдельном namespace.

**Стек:** Talos, Kubernetes, ArgoCD, Helm 3, чарт `jenkins/jenkins` 5.9.*,
NFS 192.168.1.155:/k8s-storage

**Спека:** `docs/migrations/2026-09-04-jenkins-helm-chart-design.md`

## Глобальные ограничения

- `KUBECONFIG=~/.kube/talos`
- Работа ведётся в ветке `jenkins-helm-chart` репозитория
  `git@github.com:gera-corp-org/argocd.git`. **Ничего не мержить в `main` до Задачи 5** —
  `home-lab` следит за `HEAD` ветки `main` с `selfHeal`, любой преждевременный мерж
  означает немедленный кат.
- Версия Jenkins не меняется: образ `jenkins/jenkins:2.568.3-lts-jdk25`
- Чарт: `https://charts.jenkins.io`, `chart: jenkins`, `targetRevision: 5.9.*`
- Имя ServiceAccount остаётся `jenkins-admin` — к нему может быть привязана
  роль Vault `auth/talos/role/default`, проверить это из кластера нельзя
- `overwritePlugins` и `JCasC.overwriteConfiguration` обязаны остаться `false` —
  это единственные две ветки в `apply_config.sh`, делающие `rm -rf` по `JENKINS_HOME`
- `fsGroup: 472` и `supplementalGroups: [0]` — как у нынешнего Deployment.
  Дефолтные `fsGroup: 1000` спровоцируют рекурсивный chown 3296 файлов по NFS
- Каталог данных на NFS:
  `/k8s-storage/jenkins-jenkins-pv-pvc-2389b713-d6ae-4a44-810e-66055e6a92f2`
- PV `csi-jenkins-jenkins-pv` описан в `home_cluster/storage/persistent-volumes.yaml`
  и в этой миграции **не меняется**
- Временные объекты (PV, PVC, Pod, ns `jenkins-test`) создаются `kubectl` напрямую
  и в Git не попадают. ArgoCD их не тронет: prune работает только по объектам
  со своей меткой отслеживания

---

### Задача 1: Снять эталон состояния и сделать копию тома для обкатки

Смысл задачи — зафиксировать, как выглядит работающий Jenkins **до** любых изменений,
и получить копию данных, на которой можно безнаказанно проверять чарт.

Копия снимается с живого Jenkins, то есть crash-consistent. Для обкатки этого
достаточно; настоящий бэкап под откат делается в Задаче 5 после остановки сервиса.

**Файлы:** нет, работа только в кластере.

- [ ] **Шаг 1: Записать эталон**

```bash
export KUBECONFIG=~/.kube/talos
mkdir -p /tmp/jenkins-baseline
kubectl -n jenkins exec deploy/jenkins -c jenkins -- sh -c '
  echo "plugins: $(ls /var/jenkins_home/plugins/*.jpi | wc -l)"
  echo "files:   $(find /var/jenkins_home -type f | wc -l)"
  echo "jobs:    $(ls /var/jenkins_home/jobs | tr "\n" " ")"
' | tee /tmp/jenkins-baseline/state.txt
```
Ожидается ровно:
```
plugins: 96
files:   3296
jobs:    Proxmox seedjob
```
Если числа другие — не продолжать, а обновить спеку: на них опираются проверки
Задач 4 и 5.

- [ ] **Шаг 2: Проверить, нужен ли Jenkins'у `secrets: get`**

Старая Role даёт право, чартовая — нет. На 2026-09-04 право мёртвое; этот шаг
перепроверяет, что оно всё ещё мёртвое на момент ката.

```bash
kubectl -n jenkins exec deploy/jenkins -c jenkins -- \
  grep -c "plugins.kubernetes" /var/jenkins_home/credentials.xml || echo 0
```
Ожидается `0` — ни одного credential типа
`org.csanchez.jenkins.plugins.kubernetes`, которые читались бы из Secret'ов.
Вместе с пустым `credentialsId` у облака это значит, что Secret'ы кластера
Jenkins не читает и отсутствие права в чартовой Role безопасно.

Если вывод не `0` — остановиться, добавить в values Задачи 2
`rbac.readSecrets: true` и перепроверить рендер её шагом 3.

- [ ] **Шаг 3: Создать временный PV на корень экспорта NFS**

Нужен, чтобы копировать каталоги внутри `/k8s-storage`, не заходя на OMV по SSH.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: tmp-k8s-storage-root
spec:
  capacity:
    storage: 100G
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-csi
  volumeMode: Filesystem
  claimRef:
    apiVersion: v1
    kind: PersistentVolumeClaim
    namespace: jenkins
    name: tmp-k8s-storage-root
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: 192.168.1.155#k8s-storage#
    volumeAttributes:
      server: 192.168.1.155
      share: /k8s-storage
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tmp-k8s-storage-root
  namespace: jenkins
spec:
  storageClassName: nfs-csi
  volumeName: tmp-k8s-storage-root
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 100G
EOF
kubectl -n jenkins get pvc tmp-k8s-storage-root
```
Ожидается `STATUS: Bound`.

- [ ] **Шаг 4: Скопировать каталог данных**

Под запускается от root, иначе `cp -a` не сохранит владельцев.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: jenkins-copy
  namespace: jenkins
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 0
  containers:
  - name: cp
    image: busybox:1.37
    command: ["sh","-c"]
    args:
    - |
      set -e
      cd /nfs
      rm -rf jenkins-smoketest-copy
      cp -a jenkins-jenkins-pv-pvc-2389b713-d6ae-4a44-810e-66055e6a92f2 jenkins-smoketest-copy
      echo "files: $(find jenkins-smoketest-copy -type f | wc -l)"
      ls -ld jenkins-smoketest-copy
    volumeMounts:
    - name: nfs
      mountPath: /nfs
  volumes:
  - name: nfs
    persistentVolumeClaim:
      claimName: tmp-k8s-storage-root
EOF
kubectl -n jenkins wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s pod/jenkins-copy
kubectl -n jenkins logs jenkins-copy
```
Ожидается число файлов, близкое к 3296 (Jenkins живой, пара файлов логов могла
измениться), и права `drwxrwsrwx ... root 472`.

Если владелец не `root` и группа не `472` — на экспорте включён root squash.
Тогда обкатка Задачи 4 проверит права неверно; остановиться и разобраться
с экспортом, прежде чем продолжать.

- [ ] **Шаг 5: Убрать под копирования**

```bash
kubectl -n jenkins delete pod jenkins-copy
```
PVC `tmp-k8s-storage-root` оставить — он понадобится в Задачах 5 и 6.

---

### Задача 2: Application с чартом

Файл создаётся и проверяется **локально**, в кластер ничего не уезжает: ветка
`jenkins-helm-chart` не отслеживается ArgoCD.

**Файлы:**
- Создать: `home_cluster/helm_app/jenkins/application.yaml`

- [ ] **Шаг 1: Убедиться, что чарт нужной версии доступен**

```bash
helm repo add jenkins https://charts.jenkins.io
helm repo update jenkins
helm search repo jenkins/jenkins --version '5.9.*'
```
Ожидается строка с `CHART VERSION 5.9.x` и `APP VERSION 2.568.3`.

- [ ] **Шаг 2: Создать Application**

Файл `home_cluster/helm_app/jenkins/application.yaml`:

```yaml
# Jenkins переведён с самописных манифестов на официальный чарт 2026-09-04,
# см. docs/migrations/2026-09-04-jenkins-helm-chart-design.md.
#
# Том с данными переехал вместе с релизом, без копирования: PVC jenkins-pv
# остался собственным манифестом в home_cluster/jenkins/pvc.yaml, потому что
# привязан к PV по volumeName, а это поле чарт не рендерит вообще. Чарт
# получает его через persistence.existingClaim.
#
# Две настройки ниже удерживают init-контейнер чарта от разрушения JENKINS_HOME
# и обязаны оставаться выключенными: overwritePlugins сносит plugins/*,
# JCasC.overwriteConfiguration — config.xml и *configuration*.xml. Обе выключены
# по умолчанию и здесь не переопределяются намеренно.
#
# podSecurityContextOverride повторяет контекст старого Deployment. Дефолтный
# fsGroup чарта — 1000, а корень тома root:472; у драйвера nfs.csi.k8s.io
# fsGroupPolicy: File, поэтому дефолт заставил бы kubelet рекурсивно сменить
# группу на 3296 файлах по NFS при каждом несовпадении.
#
# Имя ServiceAccount оставлено прежним (jenkins-admin): к нему может быть
# привязана роль Vault auth/talos/role/default, которой пользуется
# vaultKubernetesCredential ниже.
#
# podTemplate агента задан сырым YAML, а не через agent.*, из-за hostPort 30001
# у jnlp-контейнера — шаблон jenkins.casc.podTemplate порты на jnlp не рендерит.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: jenkins
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  destination:
    name: in-cluster
    namespace: jenkins
  project: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
  source:
    repoURL: https://charts.jenkins.io
    chart: jenkins
    targetRevision: 5.9.*
    helm:
      releaseName: jenkins
      valuesObject:
        clusterZone: cluster.local

        controller:
          image:
            registry: docker.io
            repository: jenkins/jenkins
            tag: 2.568.3-lts-jdk25
            pullPolicy: IfNotPresent
          testEnabled: false
          podSecurityContextOverride:
            runAsUser: 1000
            runAsNonRoot: true
            fsGroup: 472
            supplementalGroups: [0]
            fsGroupChangePolicy: OnRootMismatch
          resources:
            limits:
              cpu: "1"
              memory: 2048Mi
            requests:
              cpu: "0.2"
              memory: 1024Mi
          jenkinsUrl: https://jenkins.local.geracorp.work
          numExecutors: 2
          customJenkinsLabels: [master]
          legacyRemotingSecurityEnabled: true
          cloudName: Kubernetes
          serviceType: ClusterIP
          installLatestPlugins: false
          installPlugins:
            - ansicolor:542.v03d235fee02d
            - apache-httpcomponents-client-5-api:5.6.4-204.vfa_29df89ffcf
            - commons-collections4-api:4.5.0-8.va_d5448ef9011
            - dark-theme:652.vea_da_dfea_e769
            - favorite:2.267.vb_90d08408081
            - github-branch-source:1983.vfa_27ed961853
            - hashicorp-vault-plugin:384.vda_86ec66c537
            - javax-mail-api:1.6.2-11
            - job-dsl:3732.v9a_c49a_61a_313
            - kubernetes:4547.v52f3080db_8cd
            - ldap:825.v2fca_37dd5b_cb_
            - matrix-auth:3.3
            - pipeline-build-step:601.v6d4c6d1a_9dc7
            - pipeline-milestone-step:152.v6e22b_8cfc66c
            - pipeline-model-definition:2.2293.v6e7193cec599
            - pipeline-stage-view:2.41
            - timestamper:1.30
            - uno-choice:2.8.10
          containerEnv:
            - name: LDAP_USER
              value: vault:secret/data/lldap#bind_jenkins_user
            - name: LDAP_USER_PASS
              value: vault:secret/data/lldap#bind_jenkins_password
          sidecars:
            configAutoReload:
              enabled: false
          admin:
            createSecret: false
          JCasC:
            defaultConfig: true
            authorizationStrategy: |-
              projectMatrix:
                entries:
                - group:
                    name: "jenkins-admin"
                    permissions:
                    - "Overall/Administer"
                - group:
                    name: "jenkins-users"
                    permissions:
                    - "Job/Build"
                    - "Job/Read"
                    - "Overall/Read"
            securityRealm: |-
              ldap:
                configurations:
                - displayNameAttributeName: "cn"
                  inhibitInferRootDN: false
                  managerDN: "uid=${LDAP_USER},ou=people,dc=geracorp,dc=local"
                  managerPasswordSecret: "${LDAP_USER_PASS}"
                  rootDN: "dc=geracorp,dc=local"
                  server: "lldap-service.lldap.svc.cluster.local:3890"
                  userSearch: "(&(uid={0})(|(memberOf=cn=jenkins-users,ou=groups,dc=geracorp,dc=local)(memberOf=cn=jenkins-admin,ou=groups,dc=geracorp,dc=local)))"
                disableMailAddressResolver: false
                disableRolePrefixing: true
                groupIdStrategy: "caseInsensitive"
                userIdStrategy: "caseInsensitive"
            configScripts:
              globals: |
                jenkins:
                  disabledAdministrativeMonitors:
                  - "hudson.util.DoubleLaunchChecker"
                  globalNodeProperties:
                  - envVars:
                      env:
                      - key: "PROXMOX_ADDR"
                        value: "https://proxmox.home.local:8006"
                      - key: "VAULT_ADDR"
                        value: "https://vault-cluster.local.geracorp.work"
                appearance:
                  themeManager:
                    disableUserThemes: true
                    theme: "darkSystem"
                security:
                  gitHostKeyVerificationConfiguration:
                    sshHostKeyVerificationStrategy: "noHostKeyVerificationStrategy"
                unclassified:
                  ansiColorBuildWrapper:
                    globalColorMapName: "xterm"
                  hashicorpVault:
                    configuration:
                      disableChildPoliciesOverride: false
                      engineVersion: 2
                      vaultCredentialId: "vault_auth"
                      vaultUrl: "https://vault-cluster.local.geracorp.work"

              credentials: |
                credentials:
                  system:
                    domainCredentials:
                    - credentials:
                      - vaultUsernamePasswordCredentialImpl:
                          engineVersion: 2
                          id: jenkins-github-integration
                          passwordKey: password
                          path: secret/jenkins/credentials/jenkins-github-integration
                          scope: GLOBAL
                          usernameKey: username
                      - vaultSSHUserPrivateKeyImpl:
                          engineVersion: 2
                          id: github_jenkins_deploy_key
                          passphraseKey: passphrase
                          path: secret/jenkins/credentials/github_jenkins
                          privateKeyKey: private_key
                          scope: GLOBAL
                          usernameKey: username
                      - vaultSSHUserPrivateKeyImpl:
                          engineVersion: 2
                          id: github_packer_proxmox_deploy_key
                          passphraseKey: passphrase
                          path: secret/jenkins/credentials/github_packer_proxmox
                          privateKeyKey: private_key
                          scope: GLOBAL
                          usernameKey: username
                      - vaultStringCredentialImpl:
                          engineVersion: 2
                          id: proxmox_api_user
                          path: secret/jenkins/credentials/proxmox_credentials
                          scope: GLOBAL
                          vaultKey: proxmox_api_user
                      - vaultStringCredentialImpl:
                          engineVersion: 2
                          id: proxmox_api_password
                          path: secret/jenkins/credentials/proxmox_credentials
                          scope: GLOBAL
                          vaultKey: proxmox_api_password
                      - vaultStringCredentialImpl:
                          engineVersion: 2
                          id: proxmox_api_token_id_proxmox_api_token_secret
                          path: secret/jenkins/credentials/proxmox_credentials
                          scope: GLOBAL
                          vaultKey: proxmox_api_token_id_proxmox_api_token_secret
                      - vaultStringCredentialImpl:
                          engineVersion: 2
                          id: vault_token
                          path: secret/jenkins/credentials/jenkins-workers
                          scope: GLOBAL
                          vaultKey: token
                      - vaultKubernetesCredential:
                          id: vault_auth
                          mountPath: talos
                          role: default
                          scope: GLOBAL
                          usePolicies: false
              jobs: |
                jobs:
                - script: |
                    job('seedjob') {
                      label('master')
                      logRotator(-1, 10)
                      scm {
                          git {
                            branch('master')
                            remote {
                              github('gera-corp/jenkins', 'ssh', 'github.com')
                              credentials('github_jenkins_deploy_key')
                            }
                          }
                      }
                      triggers {
                          githubPush()
                      }
                      steps {
                        dsl {
                          external('jobDSL/seedJob.groovy')
                        }
                      }
                      properties {
                        authorizationMatrix {
                          inheritanceStrategy {
                              nonInheriting()
                          }
                          entries {
                            group {
                              name('jenkins-admin')
                              permissions([ 'Job/Build', 'Job/Configure', 'Job/Read' ])
                            }
                          }
                        }
                      }
                    }

        persistence:
          enabled: true
          existingClaim: jenkins-pv

        serviceAccount:
          create: true
          name: jenkins-admin

        agent:
          enabled: true
          disableDefaultAgent: true
          containerCap: 10
          jenkinsUrl: "http://jenkins:8080"
          jenkinsTunnel: "jenkins-agent:50000"
          podTemplates:
            jenkins-agent: |
              - containers:
                - image: "docker-registry.local.geracorp.work/tools/jenkins-agent:v1.1.7"
                  livenessProbe:
                    failureThreshold: 0
                    initialDelaySeconds: 0
                    periodSeconds: 0
                    successThreshold: 0
                    timeoutSeconds: 0
                  name: "jnlp"
                  ports:
                  - containerPort: 8336
                    hostPort: 30001
                    name: "jenkins-agt-pk"
                  workingDir: "/home/jenkins/agent"
                imagePullSecrets:
                - name: "docker-registry-geracorp-login"
                label: "jenkins-nomad-worker"
                name: "jenkins-agent"
                namespace: "jenkins"
                yamlMergeStrategy: "override"
```

- [ ] **Шаг 3: Проверить, что рендерятся ровно семь объектов**

```bash
cd /home/gera/K8S/argocd/argocd
python3 -c "
import yaml
d=yaml.safe_load(open('home_cluster/helm_app/jenkins/application.yaml'))
yaml.safe_dump(d['spec']['source']['helm']['valuesObject'], open('/tmp/jenkins-values.yaml','w'),
               default_flow_style=False, allow_unicode=True, sort_keys=False)
"
helm template jenkins jenkins/jenkins --version '5.9.*' -n jenkins -f /tmp/jenkins-values.yaml \
  | python3 -c "
import yaml,sys
docs=[d for d in yaml.safe_load_all(sys.stdin) if d]
for d in docs: print(d['kind'], d['metadata']['name'])
print('ИТОГО:', len(docs))
"
```
Ожидается ровно:
```
ServiceAccount jenkins-admin
ConfigMap jenkins
Role jenkins-schedule-agents
RoleBinding jenkins-schedule-agents
Service jenkins-agent
Service jenkins
StatefulSet jenkins
ИТОГО: 7
```
Ни PVC, ни админского Secret, ни тестового Pod быть не должно.

- [ ] **Шаг 4: Проверить дельту JCasC**

Это главная проверка задачи: она подтверждает, что конфигурация Jenkins
не поехала.

```bash
cd /home/gera/K8S/argocd/argocd
helm template jenkins jenkins/jenkins --version '5.9.*' -n jenkins -f /tmp/jenkins-values.yaml > /tmp/jenkins-rendered.yaml
python3 - <<'PY'
import yaml
def merge(a,b):
    for k,v in b.items():
        if k in a and isinstance(a[k],dict) and isinstance(v,dict): merge(a[k],v)
        elif k in a and isinstance(a[k],list) and isinstance(v,list): a[k]=a[k]+v
        else: a[k]=v
    return a
docs=[d for d in yaml.safe_load_all(open('/tmp/jenkins-rendered.yaml')) if d]
cm=[d for d in docs if d['kind']=='ConfigMap' and d['metadata']['name']=='jenkins'][0]
new={}
for k,v in cm['data'].items():
    if k.endswith('.yaml'): merge(new, yaml.safe_load(v))
import subprocess
base=subprocess.check_output(['git','merge-base','origin/main','HEAD'],text=True).strip()
src=subprocess.check_output(['git','show',f'{base}:home_cluster/jenkins/configmap.yaml'],text=True)
body=src.split("jenkins.yaml: |\n",1)[1]
old=yaml.safe_load("\n".join(l[4:] if l.startswith("    ") else l for l in body.split("\n")))
def flat(d,p=""):
    out={}
    if isinstance(d,dict):
        for k,v in d.items(): out.update(flat(v,f"{p}.{k}" if p else k))
    elif isinstance(d,list):
        for i,v in enumerate(d): out.update(flat(v,f"{p}[{i}]"))
    else: out[p]=d.rstrip() if isinstance(d,str) else d
    return out
fo,fn=flat(old),flat(new)
chg=[k for k in set(fo)&set(fn) if fo[k]!=fn[k]]
print("добавится:", len(set(fn)-set(fo)), "пропадёт:", len(set(fo)-set(fn)), "изменится:", len(chg))
for k in chg: print("  ~", k, ":", repr(fo[k]), "->", repr(fn[k]))
PY
```
Ожидается ровно:
```
добавится: 21 пропадёт: 6 изменится: 1
  ~ jenkins.clouds[0].kubernetes.jenkinsUrl : 'http://jenkins-http:8080' -> 'http://jenkins:8080'
```
Любое другое изменившееся значение — это незамеченное расхождение конфигурации.
Разобраться до продолжения.

Две тонкости в этом скрипте, обе намеренные.

Эталон читается из git по `merge-base` с `origin/main`, а не из рабочего дерева:
Задача 3 удаляет `home_cluster/jenkins/configmap.yaml`, и после неё проверка из
файла работать перестала бы. Через git она остаётся исполнимой на любом шаге,
в том числе после ребейза в Задаче 5.

Строковые значения сравниваются с `rstrip()`. Иначе в дельту попадает Groovy
seedjob'а: чарт рендерит `configScripts` блоком `|-` с обрезкой, из-за чего
скрипт теряет завершающий перевод строки. Для Job DSL это ничто, а проверку
зашумляет — и тем скрывает изменения, которые важны.

- [ ] **Шаг 5: Коммит**

```bash
cd /home/gera/K8S/argocd/argocd
git add home_cluster/helm_app/jenkins/application.yaml
git commit -m "jenkins: Application на официальный чарт

Дельта JCasC против нынешнего configmap.yaml: 21 добавление (все — явная
запись действующих дефолтов Jenkins и плагина kubernetes), 6 удалений,
одно изменение значения — jenkinsUrl облака вслед за переименованием
сервиса контроллера в jenkins.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Задача 3: Разделить плоские манифесты

PVC выносится в отдельный файл, лишние Service удаляются, IngressRoute
переключается на сервис чарта. Всё, что чарт делает сам, из репозитория уходит.

**Файлы:**
- Создать: `home_cluster/jenkins/pvc.yaml`
- Изменить: `home_cluster/jenkins/service.yaml`
- Удалить: `home_cluster/jenkins/jenkins.yaml`, `home_cluster/jenkins/configmap.yaml`,
  `home_cluster/jenkins/workers/sa.yaml`
- Изменить: `README.md`

- [ ] **Шаг 1: Создать `home_cluster/jenkins/pvc.yaml`**

```yaml
# Claim вынесен из jenkins.yaml, когда Jenkins переехал на Helm-чарт
# (2026-09-04). Чарту он не отдан и отдан быть не может: том усыновлён
# статически, PVC привязан к конкретному PV через volumeName, а этого поля
# чарт не рендерит вообще — без него claim уехал бы на пустой динамический
# том. Чарт получает его через persistence.existingClaim.
#
# Сам PV описан в home_cluster/storage/persistent-volumes.yaml,
# reclaimPolicy: Retain — удаление claim'а каталог на NFS не трогает.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jenkins-pv
  namespace: jenkins
spec:
  storageClassName: nfs-csi
  volumeName: csi-jenkins-jenkins-pv
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 5G
```

- [ ] **Шаг 2: Переписать `home_cluster/jenkins/service.yaml`**

Целиком заменить содержимое файла на:

```yaml
# Service контроллера (jenkins) и агент-листенера (jenkins-agent) создаёт
# Helm-чарт, см. home_cluster/helm_app/jenkins/application.yaml. Здесь
# остались только объекты, которых в чарте нет.
---
# NodePort для packer: агент публикует свой HTTP-сервер на containerPort 8336,
# сюда ходят снаружи кластера. Селектор ловит поды агентов по метке
# jenkins/label, которую ставит kubernetes-плагин, — от переезда на чарт
# это не зависит.
apiVersion: v1
kind: Service
metadata:
  name: jk-agnt-packer
  namespace: jenkins
spec:
  type: NodePort
  ports:
    - port: 8336
      protocol: TCP
      targetPort: jenkins-agt-pk
      nodePort: 30336
  selector:
    jenkins/label: jenkins-nomad-worker
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: jenkins-local-tls
  namespace: jenkins
spec:
  entryPoints:
    - websecure
  routes:
  - match: Host(`jenkins.local.geracorp.work`)
    kind: Rule
    services:
    # Раньше был jenkins-http из самописного манифеста; чарт называет
    # сервис контроллера по имени релиза.
    - name: jenkins
      port: 8080
  tls: {}
```

- [ ] **Шаг 3: Удалить манифесты, которые заменил чарт**

```bash
cd /home/gera/K8S/argocd/argocd
git rm home_cluster/jenkins/jenkins.yaml \
       home_cluster/jenkins/configmap.yaml \
       home_cluster/jenkins/workers/sa.yaml
```

- [ ] **Шаг 4: Проверить, что в каталоге остались ровно нужные объекты**

```bash
cd /home/gera/K8S/argocd/argocd
python3 -c "
import yaml,glob
for f in sorted(glob.glob('home_cluster/jenkins/**/*.yaml', recursive=True)):
    for d in yaml.safe_load_all(open(f)):
        if d: print(f, '->', d['kind'], d['metadata']['name'])
"
```
Ожидается ровно:
```
home_cluster/jenkins/pvc.yaml -> PersistentVolumeClaim jenkins-pv
home_cluster/jenkins/secrets.yaml -> Secret docker-registry-geracorp-login
home_cluster/jenkins/service.yaml -> Service jk-agnt-packer
home_cluster/jenkins/service.yaml -> IngressRoute jenkins-local-tls
```

- [ ] **Шаг 5: Обновить README**

В разделе `## Platform` заменить строку про Jenkins на:

```markdown
- [Jenkins](https://www.jenkins.io/) — the upstream Helm chart with plugin
  versions pinned in `valuesObject`, configured through JCasC, agents run as
  dynamic pods in the cluster
```

В разделе `## Storage` абзац про пять привязанных по `volumeName` claim'ов
не трогать — их число не изменилось, claim `jenkins-pv` лишь переехал в
собственный файл.

- [ ] **Шаг 6: Коммит**

```bash
cd /home/gera/K8S/argocd/argocd
git add -A home_cluster/jenkins README.md
git commit -m "jenkins: убрать манифесты, которые заменяет чарт

PVC вынесен в отдельный файл и остаётся вне чарта: он привязан к PV
по volumeName, а чарт этого поля не рендерит. Deployment, ConfigMap
с JCasC, ServiceAccount с Role и два Service уходят — их создаёт чарт.
IngressRoute переключён с jenkins-http на сервис jenkins.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Задача 4: Обкатка на копии тома

Проверяет то, чего не покажет ни один `helm template`: что Jenkins поднимается
на существующем `JENKINS_HOME`, что init-контейнер не портит плагины и что
новый `readOnlyRootFilesystem: true` не конфликтует с инжектом `vault-env`
от bank-vaults.

Инстанс делается **инертным**: `numExecutors: 0` и `agent.enabled: false`,
плюс из JCasC убирается блок `jobs`. Иначе второй Jenkins с той же историей
сборок мог бы полезть наружу — в GitHub и за агентами в namespace `jenkins`.

Webhook bank-vaults покрывает все namespace кроме `kube-system` и `vault-infra`,
так что в `jenkins-test` инжект vault-переменных будет настоящим.

**Файлы:** нет, только временные объекты в кластере.

- [ ] **Шаг 1: Создать namespace, PV и PVC на копию**

```bash
export KUBECONFIG=~/.kube/talos
kubectl create namespace jenkins-test
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: tmp-jenkins-smoketest
spec:
  capacity:
    storage: 5G
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-csi
  volumeMode: Filesystem
  claimRef:
    apiVersion: v1
    kind: PersistentVolumeClaim
    namespace: jenkins-test
    name: jenkins-pv
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: 192.168.1.155#k8s-storage/jenkins-smoketest-copy#
    volumeAttributes:
      server: 192.168.1.155
      share: /k8s-storage/jenkins-smoketest-copy
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jenkins-pv
  namespace: jenkins-test
spec:
  storageClassName: nfs-csi
  volumeName: tmp-jenkins-smoketest
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5G
EOF
kubectl -n jenkins-test get pvc jenkins-pv
```
Ожидается `STATUS: Bound`.

- [ ] **Шаг 2: Развернуть чарт с теми же values, но инертно**

```bash
cd /home/gera/K8S/argocd/argocd
python3 -c "
import yaml
d=yaml.safe_load(open('home_cluster/helm_app/jenkins/application.yaml'))
v=d['spec']['source']['helm']['valuesObject']
v['controller']['numExecutors']=0
v['controller']['JCasC']['configScripts'].pop('jobs',None)
v['agent']['enabled']=False
yaml.safe_dump(v, open('/tmp/jenkins-values-smoke.yaml','w'),
               default_flow_style=False, allow_unicode=True, sort_keys=False)
"
helm template jenkins jenkins/jenkins --version '5.9.*' -n jenkins-test \
  -f /tmp/jenkins-values-smoke.yaml | kubectl -n jenkins-test apply -f -
```

Инертность задаётся правкой самих values, а не флагами `--set`:
`--set controller.JCasC.configScripts.jobs=null` кладёт в ключ nil, а шаблон
чарта ждёт строку и падает с `wrong type for value; expected string`.

- [ ] **Шаг 3: Дождаться готовности пода**

```bash
kubectl -n jenkins-test rollout status statefulset/jenkins --timeout=600s
kubectl -n jenkins-test get pod jenkins-0 -o jsonpath='{.spec.initContainers[*].name}{"\n"}'
```
Ожидается `statefulset rolling update complete` и среди init-контейнеров —
`copy-vault-env` (его добавил webhook) вместе с `init`.

При `kubectl apply` здесь прилетит предупреждение PodSecurity про
`restricted:latest` — под чарта не выставляет `capabilities.drop: [ALL]`
и `seccompProfile`. Это только предупреждение и только в `jenkins-test`:
у namespace нет меток PSA, поэтому действует дефолт кластера. У боевого
`jenkins` стоит `pod-security.kubernetes.io/enforce: privileged`, так что
на кате под будет допущен. Проверено 2026-09-04.

Если под не поднялся — смотреть `kubectl -n jenkins-test logs jenkins-0 -c init`
и `-c jenkins`. Самый вероятный виновник — `readOnlyRootFilesystem: true`;
проверяется снятием этого ограничения:
`--set controller.containerSecurityContext.readOnlyRootFilesystem=false`.
Если помогло — внести это в values Задачи 2 и в спеку, а не оставлять как есть.

- [ ] **Шаг 4: Проверить, что данные целы, а vault-переменные подставились**

```bash
kubectl -n jenkins-test exec jenkins-0 -c jenkins -- sh -c '
  echo "plugins: $(ls /var/jenkins_home/plugins/*.jpi | wc -l)"
  echo "jobs:    $(ls /var/jenkins_home/jobs | tr "\n" " ")"
  echo "casc:    $(ls /var/jenkins_home/casc_configs | tr "\n" " ")"
'
```
Ожидается:
```
plugins: 96
jobs:    Proxmox seedjob
casc:    credentials.yaml globals.yaml jcasc-default-config.yaml
```
`jobs.yaml` в `casc_configs` отсутствует намеренно — он убран для инертности.

Отдельно — сработал ли инжект bank-vaults, то есть не подрался ли новый
`readOnlyRootFilesystem: true` с `vault-env`:

```bash
kubectl -n jenkins-test exec jenkins-0 -c jenkins -- \
  grep -c "vault:secret" /var/jenkins_home/config.xml || echo 0
```
Ожидается `0`: JCasC записал в `config.xml` уже разрешённые значения.
Если больше нуля — в конфиг попала сырая `vault:`-ссылка, инжект не сработал,
разбираться по Шагу 3.

**Не проверять это через `echo $LDAP_USER` в `kubectl exec`** — там всегда будет
сырая `vault:`-ссылка, и проверка ложно провалится. `vault-env` подставляет
переменные только в процессе, который запускает сам; `kubectl exec` порождает
новый процесс с исходным окружением из спеки пода. Смотреть надо на результат
работы Jenkins, а не на окружение произвольного процесса в контейнере.

- [ ] **Шаг 5: Проверить, что Jenkins отвечает и LDAP-realm поднялся**

```bash
kubectl -n jenkins-test exec jenkins-0 -c jenkins -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/login
kubectl -n jenkins-test logs jenkins-0 -c jenkins | grep -i "configuration-as-code.*error\|Failed to load\|SEVERE" || echo "ошибок нет"
```
Ожидается `200` и `ошибок нет`.

Одно исключение, которое ошибкой здесь не считается: жалобы на
`vaultKubernetesCredential` / `vault_auth`. Этот credential аутентифицируется
в Vault по ServiceAccount, а роль `auth/talos/role/default` привязана к
namespace `jenkins` — в `jenkins-test` она вправе не сработать. Обкатка этого
не проверяет и проверить не может; resolve credentials из Vault проверяется
только после ката, в Задаче 5, шаг 7.

- [ ] **Шаг 6: Снести обкатку**

```bash
kubectl delete namespace jenkins-test
kubectl delete pv tmp-jenkins-smoketest
```
Каталог `jenkins-smoketest-copy` на NFS пока оставить — уберём в Задаче 6.

---

### Задача 5: Кат

**Файлы:** нет изменений в файлах, только мерж уже готовых коммитов.

- [ ] **Шаг 1: Убедиться, что ветка готова и `main` не разошёлся**

```bash
cd /home/gera/K8S/argocd/argocd
git fetch origin
git log --oneline origin/main..jenkins-helm-chart
git log --oneline jenkins-helm-chart..origin/main
```
В первом выводе ожидаются четыре коммита ветки — спека, план, Application
(Задача 2) и правка плоских манифестов (Задача 3). Второй вывод должен быть
пуст. Если `main` ушёл вперёд — сначала `git rebase origin/main`, затем
перепроверить дельту JCasC шагом 4 Задачи 2: чужой коммит мог задеть
`home_cluster/jenkins/configmap.yaml`, с которым она сравнивается.

- [ ] **Шаг 2: Погасить нынешний Jenkins**

Это критический шаг, и он идёт **до** мержа. Deployment `jenkins` и StatefulSet
`jenkins` — объекты разных типов, они не вытесняют друг друга; `prune` снимет
Deployment, но не раньше, чем создаст StatefulSet. Два живых Jenkins на одном
`JENKINS_HOME` — единственный сценарий, где данные теряются необратимо.

```bash
export KUBECONFIG=~/.kube/talos
kubectl -n jenkins scale deploy/jenkins --replicas=0
kubectl -n jenkins wait --for=delete pod -l app=jenkins --timeout=300s
kubectl -n jenkins get pod -l app=jenkins
```
Ожидается `No resources found` — ни одного пода Jenkins.

ArgoCD `home-lab` работает с `selfHeal` и вернёт реплику обратно. Проверить,
что этого не произошло, прежде чем идти дальше:
```bash
kubectl -n jenkins get deploy jenkins -o jsonpath='{.spec.replicas}{"\n"}'
```
Ожидается `0`. Если стало `1` — selfHeal успел сработать; поставить приложению
`kubectl -n argocd patch app home-lab --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'`,
повторить scale, и не забыть вернуть автоматику после Шага 4.

- [ ] **Шаг 3: Снять консистентный бэкап**

Теперь, когда сервис остановлен, копия получается целостной — в отличие от
той, что делалась в Задаче 1 для обкатки.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: jenkins-backup
  namespace: jenkins
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 0
  containers:
  - name: cp
    image: busybox:1.37
    command: ["sh","-c"]
    args:
    - |
      set -e
      cd /nfs
      rm -rf jenkins-backup-2026-09-04
      cp -a jenkins-jenkins-pv-pvc-2389b713-d6ae-4a44-810e-66055e6a92f2 jenkins-backup-2026-09-04
      echo "files: $(find jenkins-backup-2026-09-04 -type f | wc -l)"
    volumeMounts:
    - name: nfs
      mountPath: /nfs
  volumes:
  - name: nfs
    persistentVolumeClaim:
      claimName: tmp-k8s-storage-root
EOF
kubectl -n jenkins wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s pod/jenkins-backup
kubectl -n jenkins logs jenkins-backup
kubectl -n jenkins delete pod jenkins-backup
```
Ожидается `files: 3296` — ровно столько же, сколько в эталоне Задачи 1.
Расхождение больше пары файлов означает, что Jenkins успел что-то дописать;
разобраться, прежде чем мержить.

- [ ] **Шаг 4: Смержить ветку**

```bash
cd /home/gera/K8S/argocd/argocd
git checkout main
git merge --no-ff jenkins-helm-chart -m "jenkins: переезд на официальный Helm-чарт

См. docs/migrations/2026-09-04-jenkins-helm-chart-design.md.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
```

- [ ] **Шаг 5: Дождаться синхронизации**

```bash
export KUBECONFIG=~/.kube/talos
kubectl -n argocd get app home-lab jenkins \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
kubectl -n jenkins rollout status statefulset/jenkins --timeout=600s
```
Ожидается оба приложения `Synced` / `Healthy` и поднявшийся `jenkins-0`.

Application `jenkins` появляется не сразу: сначала `home-lab` должен применить
сам объект Application, и только потом ArgoCD начнёт разворачивать чарт.

- [ ] **Шаг 6: Проверить, что старые объекты пропали, а новые на месте**

```bash
kubectl -n jenkins get deploy,statefulset,svc,sa,role,rolebinding,cm
```
Ожидается: **нет** `deployment.apps/jenkins`, **нет** Service `jenkins-http`,
**нет** Role `jenkins` и RoleBinding `jenkins-role-binding`, **нет** ConfigMap
`jenkins-casc-config`. Есть `statefulset.apps/jenkins`, Service `jenkins`,
`jenkins-agent`, `jk-agnt-packer`, SA `jenkins-admin`, Role и RoleBinding
`jenkins-schedule-agents`, ConfigMap `jenkins`.

- [ ] **Шаг 7: Проверить сервис по существу**

```bash
kubectl -n jenkins exec jenkins-0 -c jenkins -- sh -c '
  echo "plugins: $(ls /var/jenkins_home/plugins/*.jpi | wc -l)"
  echo "jobs:    $(ls /var/jenkins_home/jobs | tr "\n" " ")"
'
curl -s -o /dev/null -w '%{http_code}\n' https://jenkins.local.geracorp.work/login
```
Ожидается `plugins: 96`, `jobs: Proxmox seedjob`, HTTP `200`.

Дальше — руками в UI, это автоматикой не проверяется:
- вход под учёткой из группы `jenkins-users` (LDAP-realm);
- Manage Jenkins → Credentials: все восемь credentials на месте и резолвятся
  из Vault;
- история сборок у `Proxmox` и `seedjob` цела;
- запустить сборку на агенте с меткой `jenkins-nomad-worker` и убедиться,
  что под агента создаётся и билд проходит.

Проверка агента здесь единственная в своём роде: в обкатке Задачи 4 агенты были
намеренно выключены.

---

### Задача 6: Уборка

Выполняется не сразу, а через несколько дней работы — когда станет ясно, что
откат не понадобится.

**Файлы:** нет.

- [ ] **Шаг 1: Убедиться, что Jenkins живёт нормально**

```bash
export KUBECONFIG=~/.kube/talos
kubectl -n jenkins get pod jenkins-0 \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp'
```
Ожидается `READY: true` и `RESTARTS` без роста.

- [ ] **Шаг 2: Удалить копии и временные объекты**

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: jenkins-cleanup
  namespace: jenkins
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 0
  containers:
  - name: rm
    image: busybox:1.37
    command: ["sh","-c"]
    args:
    - |
      set -e
      cd /nfs
      rm -rf jenkins-smoketest-copy jenkins-backup-2026-09-04
      echo "осталось:"; ls -d jenkins-* 2>/dev/null || true
    volumeMounts:
    - name: nfs
      mountPath: /nfs
  volumes:
  - name: nfs
    persistentVolumeClaim:
      claimName: tmp-k8s-storage-root
EOF
kubectl -n jenkins wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s pod/jenkins-cleanup
kubectl -n jenkins logs jenkins-cleanup
kubectl -n jenkins delete pod jenkins-cleanup
kubectl -n jenkins delete pvc tmp-k8s-storage-root
kubectl delete pv tmp-k8s-storage-root
```
Ожидается, что в выводе остался только рабочий каталог
`jenkins-jenkins-pv-pvc-2389b713-...`.

- [ ] **Шаг 3: Удалить ветку**

```bash
cd /home/gera/K8S/argocd/argocd
git branch -d jenkins-helm-chart
```

---

## Откат

Пока копия `jenkins-backup-2026-09-04` не удалена (то есть до Задачи 6), откат
стоит один коммит:

```bash
cd /home/gera/K8S/argocd/argocd
git revert -m 1 <хеш мержа>
git push origin main
kubectl -n argocd delete app jenkins
```

ArgoCD восстановит Deployment из вернувшегося `jenkins.yaml`, StatefulSet и
чартовые объекты пропруняются. Данные при этом не участвуют: том тот же самый,
`reclaimPolicy: Retain`, никто его не пересоздаёт.

Если же повреждён сам `JENKINS_HOME`, восстановление идёт из копии
`jenkins-backup-2026-09-04`, снятой в Задаче 5 при остановленном сервисе.

Сначала погасить нагрузку — и снять автоматику, иначе `selfHeal` поднимет
реплику обратно посреди восстановления:

```bash
export KUBECONFIG=~/.kube/talos
kubectl -n argocd patch app jenkins --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n jenkins scale statefulset/jenkins --replicas=0
kubectl -n jenkins wait --for=delete pod/jenkins-0 --timeout=300s
```

Затем заменить содержимое каталога. Копия остаётся нетронутой — восстановление
идёт из неё, а не переименованием, чтобы её можно было использовать повторно:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: jenkins-restore
  namespace: jenkins
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 0
  containers:
  - name: restore
    image: busybox:1.37
    command: ["sh","-c"]
    args:
    - |
      set -e
      cd /nfs
      test -d jenkins-backup-2026-09-04
      rm -rf jenkins-jenkins-pv-pvc-2389b713-d6ae-4a44-810e-66055e6a92f2.broken
      mv jenkins-jenkins-pv-pvc-2389b713-d6ae-4a44-810e-66055e6a92f2 \
         jenkins-jenkins-pv-pvc-2389b713-d6ae-4a44-810e-66055e6a92f2.broken
      cp -a jenkins-backup-2026-09-04 \
            jenkins-jenkins-pv-pvc-2389b713-d6ae-4a44-810e-66055e6a92f2
      echo "files: $(find jenkins-jenkins-pv-pvc-2389b713-d6ae-4a44-810e-66055e6a92f2 -type f | wc -l)"
    volumeMounts:
    - name: nfs
      mountPath: /nfs
  volumes:
  - name: nfs
    persistentVolumeClaim:
      claimName: tmp-k8s-storage-root
EOF
kubectl -n jenkins wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s pod/jenkins-restore
kubectl -n jenkins logs jenkins-restore
kubectl -n jenkins delete pod jenkins-restore
```
Ожидается `files: 3296`.

Испорченный каталог сохранён рядом с суффиксом `.broken` — не удалять, пока
не станет ясно, что именно сломалось.

Поднять обратно и вернуть автоматику:

```bash
kubectl -n jenkins scale statefulset/jenkins --replicas=1
kubectl -n jenkins rollout status statefulset/jenkins --timeout=600s
kubectl -n argocd patch app jenkins --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

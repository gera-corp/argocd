# GitOps K8S repository for Home Lab

[Argo CD](https://argo-cd.readthedocs.io/) watches this repository and keeps the
home lab cluster in sync with it. Everything here is either a plain manifest, a
kustomize overlay, or an Argo CD `Application` wrapping an upstream Helm chart
with its values inlined as `valuesObject`.

The cluster runs [Talos Linux](https://www.talos.dev/); nothing is installed by
hand. Almost every workload and every piece of platform infrastructure is
described here — see [What is not here](#what-is-not-here) for the exceptions.

## Layout

| Path | What lives there |
| --- | --- |
| `home_cluster/` | Plain manifests, applied straight from the repository |
| `home_cluster/helm_app/` | `Application` objects pointing at upstream Helm charts |
| `home_cluster/storage/` | Static `PersistentVolume`s adopted by the NFS CSI driver |
| `telebot/` | kustomize overlay; the image tag is written back into `.argocd-source-telebot.yaml` by Argo CD Image Updater |
| `docs/migrations/` | Write-ups of one-off migrations, kept for the reasoning rather than for reuse |
| `disabled/` | Retired manifests, kept for reference — not synced |

## Sync policy

Applications carry `argocd.argoproj.io/sync-wave` so that things land in
dependency order:

| Wave | What | Why here |
| --- | --- | --- |
| 0 | csi-driver-nfs | every `PersistentVolumeClaim` in the cluster depends on it |
| 1 | cert-manager, metallb, metrics-server, external-dns, the two bank-vaults components | CRDs, LoadBalancer addresses and secret injection have to exist before anything asks for them |
| 2 | minio, fluent-bit, the cert-manager `ClusterIssuer`s | need the CRDs from wave 1 |
| 3 | traefik, kube-prometheus-stack, seafile, grafana-loki, the exporters | ingress, certificates and object storage are all in place by now |

Most applications sync automatically with `prune`, `selfHeal` and
`ServerSideApply`. Three of them deliberately run with **`prune: false`**, and
each says why in its own manifest:

- **cert-manager** and **metallb** — pruning a CRD takes every object of that
  kind with it. For cert-manager that is every `Certificate` in the cluster and
  the end of renewals; for metallb it is the address pool, and with it every
  LoadBalancer address, meaning all inbound traffic.
- **minio** — it holds the Terraform state for the whole infrastructure. If the
  chart ever stops rendering the `PersistentVolumeClaim`, pruning it would take
  MinIO down and the state with it.

`ServerSideApply` is not decoration either. Several charts leave fields for a
controller to fill in at runtime — MetalLB renders its webhook `Secret` empty
and omits the `caBundle` entirely. A client-side apply would overwrite both with
nothing; server-side apply simply does not claim fields the manifest never
declares.

## Storage

Volumes are served by [csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs)
from an OpenMediaVault box at `192.168.1.155`. The `nfs-csi` storage class is the
only one in the cluster.

`home_cluster/storage/persistent-volumes.yaml` holds 19 static
`PersistentVolume`s. They are **not** an optimisation — they point at directories
created by the previous provisioner, and five `PersistentVolumeClaim`s are bound
to them by `volumeName`. A claim with `volumeName` is never provisioned
dynamically, so without these manifests a rebuild would leave them `Pending`
forever. Every one of them uses `reclaimPolicy: Retain`: deleting a claim does
not touch the data on NFS.

Adopting an existing volume this way means Helm charts and the cluster disagree
about `volumeName` — the chart cannot know it, and it is immutable once bound.
Applications that own a claim therefore ignore that field explicitly; see
`home_cluster/helm_app/minio/application.yaml` for the pattern.

## Platform

- [Traefik](https://traefik.io/) — ingress controller, two replicas, wildcard
  certificate as the default `TLSStore`; the service is published as
  `*.local.geracorp.work` through external-dns
- [MetalLB](https://metallb.io/) — hands out LoadBalancer addresses from
  `192.168.1.100-110` and announces them over L2 (ARP). The router does not speak
  BGP, so FRR is switched off
- [cert-manager](https://cert-manager.io/) — two `ClusterIssuer`s in
  `home_cluster/helm_app/cert-manager/issuers.yaml`: `letsencrypt-prod` for HTTP-01, and
  `letsencrypt-cloud-production` using Cloudflare DNS-01 for the three zones
  whose names never answer from the internet
- [external-dns](https://kubernetes-sigs.github.io/external-dns/) — keeps
  `local.geracorp.work` in Cloudflare in step with the cluster
- [bank-vaults](https://bank-vaults.dev/) — the secrets webhook resolves
  `vault:` references at admission time, the reloader restarts workloads when the
  value behind a reference changes in Vault
- [MinIO](https://min.io/) — object storage: Loki chunks, Vault snapshots and the
  Terraform state
- [Loki](https://grafana.com/oss/loki/) with
  [Fluent Bit](https://fluentbit.io/) — container logs, with the istio components
  tagged separately so they can be told apart in queries
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
  with the [blackbox exporter](https://github.com/prometheus/blackbox_exporter)
  and the [x509 certificate exporter](https://github.com/enix/x509-certificate-exporter) —
  own alert rules under `home_cluster/helm_app/prometheus/alerts/` (node exporter, OOM, Vault,
  blackbox, certificate expiry) and `ScrapeConfig`s for targets outside the
  cluster: the Vault cluster, Bareos, OpenMediaVault, a VLESS/v2ray node, the
  BlueVPS VPN box and the home PCs. Alertmanager notifies over Telegram
- [Docker Registry](https://github.com/distribution/distribution) with
  [Docker Registry UI](https://github.com/Joxit/docker-registry-ui)
- [Jenkins](https://www.jenkins.io/) — plugins installed by an init container,
  configured through JCasC, agents run as dynamic pods in the cluster
- [lldap](https://github.com/lldap/lldap) — light LDAP implementation used for
  authentication
- [InfluxDB](https://www.influxdata.com/) 2.x — holds the `proxmox` bucket
- Vault backup — CronJob taking a raft snapshot every 12h and pushing it to MinIO,
  where a 30-day lifecycle rule expires it (see
  `home_cluster/vault_backup/README.md` for the Vault-side setup)

## Applications

- [Seafile](https://github.com/gera-corp-org/helm-seafile) — file sync and share,
  own chart; a weekly `CronJob` runs the garbage collector
- [Statedash](https://github.com/gera-corp-org/statedash) — network dashboard fed
  by OPNsense, plus the public demonstration at `demo.statedash.geracorp.org`
  running the same chart in mock mode
- [Nod32 update mirror](https://github.com/gera-corp/nod32update-mirror)
- [release-bot](https://github.com/janisv/release-bot) — GitHub releases to Telegram
- dockerhub-bot — watches Docker Hub tags and reports to Telegram
- telebot — private image from GHCR, pulled with a `regcred` secret

## Secrets

Nothing sensitive is committed. Secrets hold references of the form
`vault:secret/data/<path>#<key>`, which the
[bank-vaults](https://bank-vaults.dev/) secrets webhook resolves at admission
time from [HashiCorp Vault](https://www.vaultproject.io/), which runs outside the
cluster. Put the value in Vault first, then let Argo CD apply the manifest.
Beware that `vault kv put` replaces the whole secret rather than merging into
it — read the path before writing to it.

Two credentials could not be moved into Vault yet, so their objects live in the
cluster and are described nowhere:

- the MinIO root password — the chart points at the existing `minio` secret
  through `auth.existingSecret`
- the Loki configuration, which carries an S3 access key inside a connection
  URL — the chart points at the existing ConfigMap through
  `loki.existingConfigmap`

Both work today and survive restarts, but a rebuild from this repository alone
would not recreate them. Closing the gap needs write access to `secret/` in
Vault.

## Ingress and TLS

Services are exposed through Traefik `IngressRoute`s (Helm applications use a
plain `Ingress` with the `traefik` class). Certificates come from cert-manager:
`letsencrypt-prod` for the usual case and `letsencrypt-cloud-production`
(Cloudflare DNS-01) for names that only resolve on the LAN and therefore cannot
answer an HTTP-01 challenge. The wildcard certificate for
`*.local.geracorp.work` is issued into the `traefik` namespace and set as the
default in Traefik's `TLSStore`, so most services need no certificate of their
own.

## What is not here

Two Helm releases are still installed by Terraform, on purpose: **Cilium** and
**Argo CD** itself. Both have to exist before Argo CD can manage anything —
Talos boots with `cni: none`, so without Cilium there is no pod network at all.
Note that the Terraform state lives in the MinIO instance described above, which
means the bootstrap layer currently depends on the cluster it bootstraps.

**Istio** is also outside this repository. It was installed for experiments and
is being retired rather than adopted.

# GitOps K8S repository for Home Lab

[Argo CD](https://argo-cd.readthedocs.io/) watches this repository and keeps the
home lab cluster in sync with it. Everything here is either a plain manifest, a
kustomize overlay, or an Argo CD `Application` wrapping an upstream Helm chart
with its values inlined as `valuesObject`.

## Layout

| Path | What lives there |
| --- | --- |
| `home_cluster/` | Plain manifests, applied straight from the repository |
| `home_cluster/helm_app/` | `Application` objects pointing at upstream Helm charts |
| `telebot/` | kustomize overlay; the image tag is written back into `.argocd-source-telebot.yaml` by Argo CD Image Updater |
| `disabled/` | Retired manifests, kept for reference — not synced |

Helm applications sync automatically with `prune`, `selfHeal` and
`ServerSideApply`; the cluster-wide pieces (Traefik, Prometheus) carry
`sync-wave: "3"` so they land after the CRDs they depend on.

## Platform

- [Traefik](https://traefik.io/) — ingress controller, two replicas, wildcard
  certificate as the default `TLSStore`; the service is published as
  `*.local.geracorp.work` through external-dns
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
  with the [blackbox exporter](https://github.com/prometheus/blackbox_exporter) —
  own alert rules under `helm_app/prometheus/alerts/` (node exporter, OOM, Vault,
  blackbox) and `ScrapeConfig`s for targets outside the cluster: the Vault
  cluster, Bareos, OpenMediaVault, a VLESS/v2ray node, the BlueVPS VPN box and
  the home PCs. Alertmanager notifies over Telegram
- [Docker Registry](https://github.com/distribution/distribution) with
  [Docker Registry UI](https://github.com/Joxit/docker-registry-ui)
- [Jenkins](https://www.jenkins.io/) — plugins installed by an init container,
  configured through JCasC, agents run as dynamic pods in the cluster
- [lldap](https://github.com/lldap/lldap) — light LDAP implementation used for
  authentication
- [InfluxDB](https://www.influxdata.com/) 2.x — holds the `proxmox` bucket
- Vault backup — CronJob taking a raft snapshot every 12h and pushing it to S3
  (see `home_cluster/vault_backup/README.md` for the Vault-side setup)

## Applications

- [Statedash](https://github.com/gera-corp-org/statedash) — network dashboard fed
  by OPNsense, plus the public demonstration at `demo.statedash.geracorp.ru`
  running the same chart in mock mode
- [OpenClaw](https://github.com/serhanekicii/openclaw-helm) — pinned to the arm64
  node via `nodeSelector` and a matching toleration
- [Nod32 update mirror](https://github.com/gera-corp/nod32update-mirror)
- [Open-Monitor for OpenVPN servers](https://github.com/furlongm/openvpn-monitor) —
  two instances, one per site
- [release-bot](https://github.com/janisv/release-bot) — GitHub releases to Telegram
- dockerhub-bot — watches Docker Hub tags and reports to Telegram
- telebot — private image from GHCR, pulled with a `regcred` secret

## Secrets

Nothing sensitive is committed. Secrets hold references of the form
`vault:secret/data/<path>#<key>`, which the
[bank-vaults](https://bank-vaults.dev/) secrets webhook resolves at admission
time from [HashiCorp Vault](https://www.vaultproject.io/). Put the value in Vault
first, then let Argo CD apply the manifest.

## Ingress and TLS

Services are exposed through Traefik `IngressRoute`s (Helm applications use a
plain `Ingress` with the `traefik` class). Certificates come from cert-manager:
`letsencrypt-prod` for the usual case and `letsencrypt-cloud-production`
(Cloudflare DNS-01) for names that only resolve on the LAN and therefore cannot
answer an HTTP-01 challenge.

This is not a complete synchronization repository, new data will be uploaded in it.

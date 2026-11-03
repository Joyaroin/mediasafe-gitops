# morioh-cho-gitops

Everything that runs on the home k3s cluster, synced by Argo CD: **[mediasafe.space](https://mediasafe.space)**
first, and the tools beside it. The cluster is two VMs, `hamon` on the Proxmox host `jonathan` and
`hermit` on `joseph`, mini PCs at home, reached from the internet only through a Cloudflare Tunnel.
(Morioh-cho is the town everything here lives in; this repository was `mediasafe-gitops` until it
ran more than MediaSafe.) The app's code, its CI, and the Terraform for Cloudflare
live in **[Joyaroin/MediaSafe](https://github.com/Joyaroin/MediaSafe)**; this repository is the
desired state of the cluster, and **a commit here is the only way the cluster changes**: Argo CD
syncs automatically, prunes what is removed, and reverts hand edits. The decision record
is [ADR 0001 in the app repo](https://github.com/Joyaroin/MediaSafe/blob/main/docs/adr/0001-deploy-to-k3s-on-linode-with-gitops.md).

## What runs on the cluster

| | |
|---|---|
| **Argo CD** | Syncs this repo, app-of-apps from `bootstrap/root.yaml`. Manages its own install too |
| **cloudflared** | The Cloudflare Tunnel: the only way in from the internet. It dials out, so the home network opens no ports |
| **Traefik** + **Gateway API** | Behind the tunnel: a `Gateway` with HTTPS listeners per hostname, and an `HTTPRoute` per app |
| **cert-manager** | Let's Encrypt certificates for every listener, issued through DNS-01 on Cloudflare |
| **Vault** | Every secret, on the node's disk, snapshotted nightly to Cloudflare R2 |
| **External Secrets** | Copies each namespace's secrets out of Vault into Kubernetes Secrets |
| **MediaSafe** ×2 | `mediasafe-staging` and `mediasafe-prod` from one Helm chart: the Next.js app, a Valkey cache, a migration Job that runs before each rollout, and a nightly CronJob. Prod runs only on `hamon`, staging only on `hermit` (`nodeSelector` in `values-<env>.yaml`) |
| **Tailscale operator** | Puts things on the tailnet instead of the internet: an Ingress with class `tailscale` becomes its own tailnet device with HTTPS |
| **Forgejo** | A git server at https://forgejo.tailf69bc5.ts.net, tailnet only: pull mirrors of the GitHub repos, and the scheduled Renovate job. Its CI runs on the VM `harvest` on `joseph`, not in this cluster. The volume is not backed up yet: mirrors refill from GitHub, anything home-only does not |

Deploys are commits too: CI in the app repo writes a new image tag to
`charts/mediasafe/values-staging.yaml` on every merge (the `Deploy MediaSafe … to staging`
commits), and a promote workflow copies it to `values-prod.yaml`.

## Layout

| Path | What |
|---|---|
| `bootstrap/root.yaml` | The one Application applied by hand. It syncs `apps/` |
| `apps/` | One Application per thing that runs, including Argo CD itself |
| `platform/<name>/` | Values for the platform charts, plus anything that runs beside them (`platform/vault/snapshots/`: the nightly snapshot to R2) |
| `charts/mediasafe/` | The app: Deployment, Service, route, migration Job, nightly sweep, Valkey, and its Secrets from Vault. `values-<env>.yaml` per environment |
| `platform/edge/` | The one Gateway, and the Let's Encrypt issuers with their Cloudflare token |
| `platform/tailscale-operator/` | The operator's values, and its OAuth client from Vault |
| `platform/forgejo/` | Forgejo's values, its admin login from Vault, and its tailnet Ingress |
| `bootstrap/install-k3s` | Installs k3s on the node, with the settings the rest assumes. Run once per machine |
| `bootstrap/install` | Installs Argo CD on a fresh cluster. Run once per cluster |
| `bootstrap/vault-init` | Initialises Vault and stores the unseal key and root token in Bitwarden. Once per Vault volume |
| `bootstrap/vault-unseal` | Unseals Vault with the key from Bitwarden. **After every Vault restart** |
| `bootstrap/vault-restore-drill` | Restores the newest R2 snapshot into a throwaway Vault and reads a canary back. The restore procedure, and its test |
| `bootstrap/install-harvest` | Sets up `harvest`, the VM on `joseph` that runs Forgejo's CI jobs in throwaway containers, with a firewall that keeps them off the LAN and the tailnet. Run once per VM |
| `bootstrap/register-runner` | Registers `harvest`'s runner with Forgejo, the token piped in from Forgejo and never shown |
| `bootstrap/forgejo-mirrors` | Mirrors every GitHub repo into Forgejo's `github` organisation. Run again for new repos |
| `bootstrap/install-github-runner` | Sets up `echoes`, the VM on `joseph` that runs GitHub Actions jobs for `Joyaroin/renovate`: a fresh runner per job, off the tailnet. Trusted code only, since jobs have Docker. Run once per VM |
| `bootstrap/register-github-runner` | Connects `echoes` to that repository, the token piped in over SSH and kept root-only. Again when the token expires |

## Bootstrapping a cluster

Needs k3s on the node (`bootstrap/install-k3s`) and the kubeconfig:
`scp hamon:.kube/config ~/.kube/homelab.yaml`, with `server:` changed to
`https://100.96.209.92:6443`, the node's Tailscale address.

```sh
export KUBECONFIG=~/.kube/homelab.yaml
bootstrap/install
```

Argo CD reads this repository over public HTTPS with no credential, so there is no deploy key to
restore.

After reinstalling k3s on the same disk, run `bootstrap/install`, wait for Argo CD to bring Vault
up, then `bootstrap/vault-unseal`: the unseal key is already in Bitwarden, and
Vault's data is still in `/mnt/vault-data`. If the disk itself is lost, Vault starts empty:
restore it from the newest R2 snapshot, by the procedure in `bootstrap/vault-restore-drill`.

## Vault comes back sealed

Every Vault restart — a reboot, a k3s upgrade, a Vault upgrade — leaves it sealed, and apps keep
running on the Secrets External Secrets already copied, but nothing new syncs until:

```sh
bootstrap/vault-unseal
```

## Signing in to Argo CD

https://argocd.mediasafe.space, with Google. Only `adhamseddik546@gmail.com` gets a role
(`platform/argocd/values.yaml`); anyone else who signs in sees nothing. The client's id and
secret live in Vault at `kv/infra/argocd/google-oidc` and reach Argo CD through
`platform/argocd-public/`. There is no local admin account. If Vault is sealed or sign-in breaks,
`argocd --core` talks to Kubernetes directly, with no Argo login.

## Ordering

`apps/` syncs in waves (`argocd.argoproj.io/sync-wave`): the Gateway API CRDs (-3), then Traefik
and cert-manager (-2), then the edge (-1), then everything else. Argo CD's config gives each
Application a health, so a wave waits for the previous one to be **Healthy**, not just created.

## Upgrading Argo CD

Change `targetRevision` in `apps/argocd.yaml` and commit. `bootstrap/install` reads the same
line, so a rebuild installs whatever version is committed.

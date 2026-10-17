# mediasafe-gitops

Everything that runs on the k3s cluster behind **[mediasafe.space](https://mediasafe.space)**,
synced by Argo CD. The app's code, its CI, and the Terraform that creates the VM live in
**[Joyaroin/MediaSafe](https://github.com/Joyaroin/MediaSafe)**; this repository is the desired
state of the cluster, and **a commit here is the only way the cluster changes**: Argo CD syncs
automatically, prunes what is removed, and reverts hand edits. The decision record is
[ADR 0001 in the app repo](https://github.com/Joyaroin/MediaSafe/blob/main/docs/adr/0001-deploy-to-k3s-on-linode-with-gitops.md).

## What runs on the cluster

| | |
|---|---|
| **Argo CD** | Syncs this repo, app-of-apps from `bootstrap/root.yaml`. Manages its own install too |
| **Traefik** + **Gateway API** | The one public entry point: a `Gateway` with HTTPS listeners per hostname, and an `HTTPRoute` per app |
| **cert-manager** | Let's Encrypt certificates for every listener, issued through HTTP-01 |
| **Vault** | Every secret, on a block volume that outlives the VM, snapshotted nightly to Cloudflare R2 |
| **External Secrets** | Copies each namespace's secrets out of Vault into Kubernetes Secrets |
| **MediaSafe** ×2 | `mediasafe-staging` and `mediasafe-prod` from one Helm chart: the Next.js app, a Valkey cache, a migration Job that runs before each rollout, and a nightly CronJob |

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
| `platform/edge/` | The one public Gateway, the HTTP→HTTPS redirect, and the Let's Encrypt issuers |
| `bootstrap/install` | Installs Argo CD on a fresh cluster. Run once per cluster |
| `bootstrap/create-deploy-key` | Creates Argo CD's read-only deploy key. Run once, ever |
| `bootstrap/vault-init` | Initialises Vault and stores the unseal key and root token in Bitwarden. Once per Vault volume |
| `bootstrap/vault-unseal` | Unseals Vault with the key from Bitwarden. **After every Vault restart** |
| `bootstrap/vault-restore-drill` | Restores the newest R2 snapshot into a throwaway Vault and reads a canary back. The restore procedure, and its test |

## Bootstrapping a cluster

Needs the Bitwarden CLI unlocked and the kubeconfig from `infra/terraform/fetch-kubeconfig`.

```sh
export BW_SESSION="$(bw unlock --raw)"
export KUBECONFIG=~/.kube/mediasafe.yaml

bootstrap/create-deploy-key   # first time only
bootstrap/install
```

After a VM rebuild, run `bootstrap/install`, wait for Argo CD to bring Vault up, then
`bootstrap/vault-unseal`: the deploy key and the unseal key are already in Bitwarden, and Vault's
data is on the volume that was reattached.

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

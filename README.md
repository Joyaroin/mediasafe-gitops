# mediasafe-gitops

Everything that runs on MediaSafe's k3s cluster, synced by Argo CD. **A commit here is the
only way the cluster changes**: Argo CD syncs automatically, prunes what is removed, and
reverts hand edits. The decision record is
[ADR 0001 in the app repo](https://github.com/Joyaroin/MediaSafe/blob/main/docs/adr/0001-deploy-to-k3s-on-linode-with-gitops.md);
the VM itself is `infra/terraform/` there.

## Layout

| Path | What |
|---|---|
| `bootstrap/root.yaml` | The one Application applied by hand. It syncs `apps/` |
| `apps/` | One Application per thing that runs, including Argo CD itself |
| `platform/<name>/` | Values for the platform charts: Argo CD, Traefik, cert-manager (Vault and External Secrets later) |
| `platform/edge/` | The one public Gateway, the HTTP→HTTPS redirect, and the Let's Encrypt issuers |
| `bootstrap/install` | Installs Argo CD on a fresh cluster. Run once per cluster |
| `bootstrap/create-deploy-key` | Creates Argo CD's read-only deploy key. Run once, ever |

## Bootstrapping a cluster

Needs the Bitwarden CLI unlocked and the kubeconfig from `infra/terraform/fetch-kubeconfig`.

```sh
export BW_SESSION="$(bw unlock --raw)"
export KUBECONFIG=~/.kube/mediasafe.yaml

bootstrap/create-deploy-key   # first time only
bootstrap/install
```

After a VM rebuild, only `bootstrap/install` is needed: the deploy key is already in Bitwarden
and on GitHub.

## Ordering

`apps/` syncs in waves (`argocd.argoproj.io/sync-wave`): the Gateway API CRDs (-3), then Traefik
and cert-manager (-2), then the edge (-1), then everything else. Argo CD's config gives each
Application a health, so a wave waits for the previous one to be **Healthy**, not just created.

## Upgrading Argo CD

Change `targetRevision` in `apps/argocd.yaml` and commit. `bootstrap/install` reads the same
line, so a rebuild installs whatever version is committed.

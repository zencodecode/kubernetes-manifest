# kubernetes-manifest

GitOps (Argo CD) repository for all applications and cluster add-ons. Single branch (`main`),
environments separated by directories, and a single repository capable of defining multiple clusters
(local k3d now, cloud later) without copy-pasting.

## Structure

```
bootstrap/root-app.yaml        App-of-Apps: Argo CD manages all contents of argocd/
argocd/
  projects/                    AppProject: apps (workload) and platform (add-on)
  appsets/
    apps.yaml                  ApplicationSet: 1 Application per apps/<app>/envs/<env>/
    platform.yaml              ApplicationSet: 1 Application per platform/<addon>/envs/<env>/
environments/<env>/values.yaml Environment-level Helm values (domain, ingress class, TLS)
charts/app/                    Generic chart for all in-house applications
apps/<app>/
  values.yaml                  Values shared across all envs
  envs/<env>/config.yaml       Argo CD parameters: chart, destination cluster, namespace, auto-sync
  envs/<env>/values.yaml       Per-env overrides: image tag, subdomain, replicas, config
platform/<addon>/
  values.yaml                  Add-on values shared across all envs
  envs/<env>/config.yaml       Parameters: upstream Helm chart OR sourcePath (raw manifests)
  envs/<env>/values.yaml       Per-env overrides (e.g. NodePort vs LoadBalancer)
  envs/<env>/manifests/        Raw manifests (for sourcePath-based add-ons)
secrets/<app>/<env>/           SOPS-encrypted secrets, rendered by KSOPS
local-setup/                   Local bootstrap (k3d, Argo CD values, databases). Not synced.
```

## Two layers, one pattern

Both applications and cluster add-ons use the same pattern: **environment-specific directories +
layered values + git-files ApplicationSet**. Adding an app, add-on, or environment =
adding a directory, not authoring a new Application manifest.

- **apps** (`argocd/appsets/apps.yaml`) discovers each `apps/*/envs/*/config.yaml` and
  generates an Application `<app>-<env>` within the `apps` project.
- **platform** (`argocd/appsets/platform.yaml`) discovers each `platform/*/envs/*/config.yaml`
  and generates an Application `<addon>-<env>` within the `platform` project. Add-ons can be either
  an upstream Helm chart (`chart:`) or raw manifests (`sourcePath:`). An add-on only exists in
  an environment if its `envs/<env>/` folder exists (e.g., `coredns-hostalias` only in dev,
  `external-dns` later in cloud).

### Layered values (applications)

Values are merged from bottom to top; each subsequent layer overrides the previous ones:

| Layer | File | Contents |
|-------|------|----------|
| Chart defaults | `charts/app/values.yaml` | Secure defaults: non-root UID 10001, read-only FS, zero-downtime rolling updates, PDB, pod topology spread |
| Environment | `environments/<env>/values.yaml` | `global.domain`, `global.ingressClassName`, `global.tls` shared by all apps in that env |
| Application | `apps/<app>/values.yaml` | App architecture: workloads, jobs, image repo |
| App per-env | `apps/<app>/envs/<env>/values.yaml` | Image tag, `ingress.subdomain`, replicas, config |

Example: a workload only needs to declare `ingress.subdomain: auth`. The host is composed by the chart as
`auth.<global.domain>` and, if `global.tls.enabled` is true, automatically receives a TLS block + the
`cert-manager.io/cluster-issuer` annotation. Thus in dev → `auth.dev...local` without TLS, in cloud →
`auth.example.com` with TLS, from the exact same application declaration.

## Sync order (sync wave)

Within a single Application (chart + secret):

| Wave | Resource |
|------|----------|
| -10 | AppProject (at root-apps level) |
| -3 | Secret (KSOPS), ConfigMap, ServiceAccount |
| -2, -1 | Job hooks (e.g. `migrate` then `seed`) — idempotent |
| 0 | Deployment, Service, Ingress/HTTPRoute, HPA, PDB, NetworkPolicy |

Application namespaces are created automatically with Pod Security Standard `restricted`.

## Adding a new environment (e.g. production)

1. `environments/<env>/values.yaml` — set `global.domain`, `global.ingressClassName`,
   and `global.tls` (enable TLS + ACME `clusterIssuer` for cloud).
2. `apps/<app>/envs/<env>/{config.yaml,values.yaml}` — point `destination.server` to that environment's cluster,
   pin `image.tag` (or `image.digest`), set `sync.automated: false` for manual promotion.
3. `platform/<addon>/envs/<env>/{config.yaml,values.yaml}` — e.g. `ingress-nginx` with
   `service.type: LoadBalancer`; `cert-manager-issuer` with an ACME ClusterIssuer; omit
   `coredns-hostalias` (that is local-only).
4. `make secret-generate APP=<app> ENV=<env> ENV_FILE=<file>`.
5. Register the target cluster in Argo CD (`argocd cluster add <context>`), then commit & push.

The `apps` and `platform` projects already permit any cluster (`server: '*'`) with
restrictions on namespace patterns (`*-dev`/`*-staging`/`*-prod`) and resource kinds, so
adding a new env requires no changes to the projects.

## authorizer-service

Single image, role selected via the `INTERFACE` environment variable:

| Component | Description |
|-----------|-------------|
| `public` | `HTTP_PUBLIC` port 8181, probes `/health` & `/ready`, HPA, Ingress |
| `event` | `EVENT`, RabbitMQ consumer (email), no port |
| `private` | `HTTP_PRIVATE`, disabled until handler implementation in the app |
| Job `migrate` | golang-migrate from `/app/migrations` inside the image |
| Job `seed` | `/app/seed`, creates the initial admin user (idempotent) |

The required secret keys are listed in `secrets/authorizer-service/dev/.env.example`.

## Automatic image updates (argocd-image-updater)

The `argocd-image-updater` add-on (`platform/argocd-image-updater/`) polls Docker Hub for new
image tags and, when a newer tag is found, **commits the updated tag back to this repository**
(git write-back method) and pushes to `main`. Argo CD then detects the new commit and syncs
the workload automatically.

### How it works

1. The `apps` ApplicationSet reads `imageUpdater` keys from `config.yaml` and injects the
   required `argocd-image-updater.argoproj.io/*` annotations onto the generated Application.
2. The image updater watches annotated Applications, checks the registry for new tags, and
   writes the new `image.tag` into the per-env `values.yaml` file via a git commit & push.
3. Argo CD picks up the commit and syncs the workload with the new image.

### Enabling image updates for an app

Add the `imageUpdater` block to `apps/<app>/envs/<env>/config.yaml`:

```yaml
imageUpdater:
  image: docker.io/mafzaidi93/authorizer-service   # full image reference
  strategy: latest                                   # latest | semver | digest
  # constraint: "~0.0"                              # optional, for semver strategy
```

### Git credentials (required for write-back)

The image updater needs write access to this repository. Create a Kubernetes Secret named `git-creds`
in the `argocd` namespace.

#### Option A: GitHub App (Recommended for organizations)
If the organization policy disables Deploy Keys, a GitHub App is the recommended standard:

```bash
kubectl -n argocd create secret generic git-creds \
  --from-literal=githubAppID="<App-ID>" \
  --from-literal=githubAppInstallationID="<Installation-ID>" \
  --from-file=githubAppPrivateKey=/path/to/private-key.pem
```

#### Option B: Personal Access Token (PAT)
```bash
kubectl -n argocd create secret generic git-creds \
  --from-literal=username=<git-username> \
  --from-literal=password=<personal-access-token>
```

#### Option C: SSH Deploy Key
```bash
kubectl -n argocd create secret generic git-creds \
  --from-file=sshPrivateKey=$HOME/.ssh/id_ed25519
```

Label the secret so argocd-image-updater discovers it:

```bash
kubectl -n argocd label secret git-creds \
  app.kubernetes.io/managed-by=argocd-image-updater
```

## Production notes

- Pin `chart.targetRevision` to a git tag so chart changes are promoted per env.
- `sync.automated: false` for prod (manual sync following review).
- `image.digest` to pin image digests; `config.ENVIRONMENT: production` + valid `config.CORS`.
- `.sops.yaml`: add a second age recipient (backup/team) or migrate to External Secrets + cloud secret manager.

## Bootstrap

See `local-setup/` for k3d, Argo CD (`argocd-values.yaml`, includes KSOPS and
`application.resourceTrackingMethod: annotation`), and databases. Once Argo CD is installed:

```bash
kubectl apply -f bootstrap/root-app.yaml
```

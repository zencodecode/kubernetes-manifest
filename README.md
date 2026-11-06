# kubernetes-manifest

Repo GitOps (Argo CD) untuk semua aplikasi dan add-on cluster. Satu branch (`main`),
environment dibedakan lewat folder, dan satu repo bisa menggambarkan banyak cluster
(lokal k3d sekarang, cloud nanti) tanpa menyalin-tempel.

## Struktur

```
bootstrap/root-app.yaml        App-of-Apps: Argo CD mengelola seluruh isi argocd/
argocd/
  projects/                    AppProject: apps (workload) dan platform (add-on)
  appsets/
    apps.yaml                  ApplicationSet: 1 Application per apps/<app>/envs/<env>/
    platform.yaml              ApplicationSet: 1 Application per platform/<addon>/envs/<env>/
environments/<env>/values.yaml Nilai Helm tingkat environment (domain, ingress class, TLS)
charts/app/                    Chart generik untuk semua aplikasi in-house
apps/<app>/
  values.yaml                  Nilai yang sama di semua env
  envs/<env>/config.yaml       Parameter Argo CD: chart, cluster tujuan, namespace, auto-sync
  envs/<env>/values.yaml       Override per env: tag image, subdomain, replika, config
platform/<addon>/
  values.yaml                  Nilai add-on yang sama di semua env
  envs/<env>/config.yaml       Parameter: Helm chart upstream ATAU sourcePath (manifest)
  envs/<env>/values.yaml       Override per env (mis. NodePort vs LoadBalancer)
  envs/<env>/manifests/        Manifest mentah (untuk add-on berbasis sourcePath)
secrets/<app>/<env>/           Secret terenkripsi SOPS, dirender KSOPS
local-setup/                   Bootstrap lokal (k3d, values Argo CD, database). Tidak di-sync.
```

## Dua lapisan, satu pola

Baik aplikasi maupun add-on cluster memakai pola yang sama: **folder per environment +
values berlapis + ApplicationSet git-files**. Menambah app, add-on, atau environment =
menambah folder, bukan menulis Application baru.

- **apps** (`argocd/appsets/apps.yaml`) menemukan tiap `apps/*/envs/*/config.yaml` dan
  membuat Application `<app>-<env>` di project `apps`.
- **platform** (`argocd/appsets/platform.yaml`) menemukan tiap `platform/*/envs/*/config.yaml`
  dan membuat Application `<addon>-<env>` di project `platform`. Add-on bisa berupa Helm chart
  upstream (`chart:`) atau manifest mentah milik kita (`sourcePath:`). Add-on hanya hadir di
  sebuah env jika folder `envs/<env>/`-nya ada (mis. `coredns-hostalias` hanya di dev,
  `external-dns` nanti hanya di cloud).

### Values berlapis (aplikasi)

Nilai digabung dari bawah ke atas; lapis berikutnya menimpa:

| Lapis | File | Isi |
|-------|------|-----|
| Chart default | `charts/app/values.yaml` | Default aman: non-root UID 10001, read-only FS, rolling update tanpa downtime, PDB, sebaran pod |
| Environment | `environments/<env>/values.yaml` | `global.domain`, `global.ingressClassName`, `global.tls` dipakai semua app di env itu |
| Aplikasi | `apps/<app>/values.yaml` | Arsitektur app: workloads, jobs, image repo |
| App per-env | `apps/<app>/envs/<env>/values.yaml` | Tag image, `ingress.subdomain`, replika, config |

Contoh: workload cukup menulis `ingress.subdomain: auth`. Host-nya disusun chart menjadi
`auth.<global.domain>` dan, kalau `global.tls.enabled`, otomatis dapat blok TLS + anotasi
`cert-manager.io/cluster-issuer`. Jadi di dev → `auth.dev...local` tanpa TLS, di cloud →
`auth.example.com` dengan TLS, dari deklarasi app yang sama.

## Urutan sync (sync wave)

Dalam satu Application (chart + secret):

| Wave | Resource |
|------|----------|
| -10 | AppProject (di level root-apps) |
| -3 | Secret (KSOPS), ConfigMap, ServiceAccount |
| -2, -1 | Job hook (mis. `migrate` lalu `seed`) — idempotent |
| 0 | Deployment, Service, Ingress/HTTPRoute, HPA, PDB, NetworkPolicy |

Namespace aplikasi dibuat otomatis dengan Pod Security Standard `restricted`.

## Menambah environment baru (mis. production)

1. `environments/<env>/values.yaml` — set `global.domain`, `global.ingressClassName`,
   dan `global.tls` (aktifkan TLS + `clusterIssuer` ACME untuk cloud).
2. `apps/<app>/envs/<env>/{config.yaml,values.yaml}` — `destination.server` ke cluster env itu,
   `image.tag` (atau `image.digest`) yang dipin, `sync.automated: false` untuk promosi manual.
3. `platform/<addon>/envs/<env>/{config.yaml,values.yaml}` — mis. `ingress-nginx` dengan
   `service.type: LoadBalancer`; `cert-manager-issuer` dengan ClusterIssuer ACME; tanpa
   `coredns-hostalias` (itu khusus lokal).
4. `make secret-generate APP=<app> ENV=<env> ENV_FILE=<file>`.
5. Daftarkan cluster tujuan ke Argo CD (`argocd cluster add <context>`), lalu commit & push.

Project `apps` dan `platform` sudah mengizinkan cluster mana pun (`server: '*'`) dengan
pembatasan pada pola namespace (`*-dev`/`*-staging`/`*-prod`) dan jenis resource, jadi
menambah env tidak perlu mengubah project.

## authorizer-service

Satu image, peran dipilih lewat env `INTERFACE`:

| Komponen | Isi |
|----------|-----|
| `public` | `HTTP_PUBLIC` port 8181, probe `/health` & `/ready`, HPA, Ingress |
| `event` | `EVENT`, consumer RabbitMQ (email), tanpa port |
| `private` | `HTTP_PRIVATE`, nonaktif sampai handler-nya diimplementasikan di aplikasi |
| Job `migrate` | golang-migrate dari `/app/migrations` di dalam image |
| Job `seed` | `/app/seed`, membuat admin pertama (idempotent) |

Daftar key secret ada di `secrets/authorizer-service/dev/.env.example`.

## Catatan production

- Pin `chart.targetRevision` ke git tag agar perubahan chart dipromosikan per env.
- `sync.automated: false` untuk prod (sync manual setelah review).
- `image.digest` untuk mengunci image; `config.ENVIRONMENT: production` + `config.CORS` valid.
- `.sops.yaml`: tambahkan recipient age kedua (backup/tim) atau pindah ke External Secrets + secret manager cloud.

## Bootstrap

Lihat `local-setup/` untuk k3d, Argo CD (`argocd-values.yaml`, sudah memuat KSOPS dan
`application.resourceTrackingMethod: annotation`) dan database. Setelah Argo CD terpasang:

```bash
kubectl apply -f bootstrap/root-app.yaml
```

# kubernetes-manifest

Repo GitOps (Argo CD) untuk semua aplikasi. Satu branch (`main`), environment dibedakan lewat folder.

## Struktur

```
bootstrap/root-app.yaml      App-of-Apps: Argo CD mengelola semua isi argocd/
argocd/
  projects/                  AppProject: apps (workload aplikasi), platform (add-on cluster)
  appsets/apps.yaml          ApplicationSet: 1 Application per apps/<app>/envs/<env>/
  core/                      Add-on cluster (ingress-nginx, cert-manager, coredns)
charts/app/                  Chart generik untuk semua aplikasi in-house
apps/<app>/
  values.yaml                Values yang sama di semua env
  envs/<env>/config.yaml     Parameter Argo CD: chart, cluster/namespace tujuan, auto-sync
  envs/<env>/values.yaml     Override per env (tag image, host, replika, config)
secrets/<app>/<env>/         Secret terenkripsi SOPS, dirender KSOPS
core/                        Manifest mentah untuk add-on (ClusterIssuer, ConfigMap CoreDNS)
local-setup/                 Bootstrap lokal (k3d, values Argo CD, database). Tidak di-sync.
```

## Cara kerja

`root-apps` men-sync `argocd/`. ApplicationSet `apps` mencari setiap `apps/*/envs/*/config.yaml`
dan membuat Application `<app>-<env>` dengan tiga sumber: chart, value files, dan `secrets/<app>/<env>`.
Semua bagian satu app-env ada di satu Application, sehingga urutannya dijaga sync wave:

| Wave | Resource |
|------|----------|
| -3 | Secret (KSOPS), ConfigMap, ServiceAccount |
| -2, -1 | Job hook, mis. `migrate` lalu `seed` (berjalan di setiap sync, harus idempotent) |
| 0 | Deployment, Service, Ingress/HTTPRoute, HPA, PDB, NetworkPolicy |

Namespace aplikasi dibuat otomatis dengan Pod Security Standard `restricted`.

## Chart generik `charts/app`

Satu release bisa berisi kombinasi bebas dari:

- `workloads`: Deployment (server HTTP/gRPC, consumer antrean, dll). Kalau ada `ports`, otomatis dapat Service,
  dan bisa ditambah Ingress atau HTTPRoute (Gateway API).
- `jobs`: Job sebagai hook Argo CD (migrasi, seed).
- `cronJobs`: Job terjadwal.

Default bawaan: non-root UID 10001, root filesystem read-only, rolling update tanpa downtime
(`maxUnavailable: 0`), sebaran pod antar zona dan node, PDB otomatis kalau pod > 1,
NetworkPolicy ingress per workload (opsional). Semua opsi didokumentasikan di `charts/app/values.yaml`.

Aplikasi yang butuh resource di luar chart ini cukup menunjuk chart lain lewat `chart.path` di `config.yaml`,
lalu tambahkan kind-nya ke `argocd/projects/apps.yaml`.

## Menambah environment atau aplikasi

1. Buat `apps/<app>/envs/<env>/config.yaml` dan `values.yaml` (contoh: `apps/authorizer-service/envs/dev/`).
   Namespace tujuan mengikuti pola `<app>-<env>`.
2. Buat secret: `make secret-generate APP=<app> ENV=<env> ENV_FILE=<file .env>`.
   Aplikasi tanpa secret: set `secrets.enabled: false` di `config.yaml`.
3. Env baru selain `dev`: tambahkan pola namespace-nya (mis. `'*-prod'`) di `argocd/projects/apps.yaml`.
4. Commit dan push. ApplicationSet membuat Application-nya.

## authorizer-service

Satu image, peran dipilih lewat env `INTERFACE`:

| Komponen | Isi |
|----------|-----|
| `public` | `HTTP_PUBLIC` di port 8181, probe `/health` dan `/ready`, HPA, Ingress |
| `event` | `EVENT`, consumer RabbitMQ (email), tanpa port |
| `private` | `HTTP_PRIVATE`, nonaktif sampai handler-nya diimplementasikan di aplikasi |
| Job `migrate` | golang-migrate dari `/app/migrations` di dalam image |
| Job `seed` | `/app/seed`, membuat admin pertama |

Daftar key secret yang dibutuhkan ada di `secrets/authorizer-service/dev/.env.example`.

## Menuju production

- `config.yaml`: `sync.automated: false` (sync manual setelah review), dan `chart.targetRevision`
  ke git tag chart supaya perubahan chart dipromosikan per env.
- `values.yaml` env: `config.ENVIRONMENT: production` dan `config.CORS` diisi origin yang valid,
  replika/HPA sesuai beban, resource dari hasil pengukuran, `image.digest` untuk pin image.
- Ingress dengan TLS (`tls` + anotasi `cert-manager.io/cluster-issuer` ke issuer ACME), atau `route` (Gateway API).
- Database dan broker managed; ganti `host.k3d.internal` di secret.
- Daftarkan cluster tujuan di Argo CD dan isi `destination.server`.
- `.sops.yaml`: tambah recipient age kedua (backup/tim), atau pindah ke External Secrets + secret manager cloud.

## Bootstrap

Lihat `local-setup/` untuk k3d, Argo CD (`argocd-values.yaml`, sudah memuat KSOPS dan
`application.resourceTrackingMethod: annotation`) dan database. Setelah Argo CD terpasang:

```bash
kubectl apply -f bootstrap/root-app.yaml
```

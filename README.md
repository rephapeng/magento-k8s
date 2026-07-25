# Magento Open Source on Kubernetes

Magento Open Source 2.4.7-p3 running on Kubernetes, packaged as a Helm chart, with
the storefront and admin reachable over a public HTTPS URL through a Cloudflare
Tunnel. The whole environment is reproducible from a clean clone — no manual,
machine-local setup steps.

| | |
|---|---|
| **Magento** | Open Source `2.4.7-p3` |
| **PHP** | `8.3` (FPM) |
| **Database** | MariaDB `10.6` (dedicated non-root user) |
| **Search** | OpenSearch `2.12` |
| **Cache / sessions** | Redis `7.2` |
| **Web** | nginx `1.27` + PHP-FPM, in separate containers |
| **Ingress** | ingress-nginx |
| **Public exposure + TLS** | Cloudflare Tunnel (TLS at the edge, no public IP or open port) |
| **Packaging** | Helm chart (`charts/magento`) |

Further reading:
[architecture](architecture/architecture.md) ·
[troubleshooting runbook](docs/troubleshooting.md) ·
[production design & trade-offs](docs/production-design.md)

---

## Two ways to expose it

The chart supports both, and picks one automatically from your `.env`:

| Mode | When | What happens |
|---|---|---|
| **Public HTTPS** | `CLOUDFLARE_TUNNEL_TOKEN` set | `cloudflared` runs in-cluster and dials out to Cloudflare. TLS terminates at the edge; `publicScheme=https`. |
| **Local only** | token empty | `cloudflared` is disabled and `publicScheme=http`; you reach the ingress directly on a `*.local` hostname. |

The distinction matters more than it looks. Magento bakes the scheme into its
`base_url` and its `use_secure` flags, so pointing a plain-HTTP client at an
instance installed as HTTPS gets you a redirect loop into a port nothing is
listening on. `publicScheme` drives both consistently.

---

## 1. Prerequisites

| Tool | Version tested |
|---|---|
| kubectl | 1.34 |
| Helm | 3.x / 4.x |
| Docker | 24+ (BuildKit required) |
| Minikube, or OrbStack Kubernetes | latest |
| cloudflared | only to create the tunnel, not to run it |

For the public-HTTPS mode you also need a free Cloudflare account and a domain
you control.

**No Adobe account is required.** The image build defaults to the public
[Mage-OS mirror](https://mirror.mage-os.org), which serves the identical
`magento/*` Open Source packages — same names, same `2.4.7-p3` version, same
archives — without authentication, so the build works from a clean clone. If you
do have Adobe Commerce Marketplace Composer keys, set `MAGENTO_MARKETPLACE_*` in
`.env` and the build switches to `repo.magento.com` automatically.

## 2. Start a cluster and install the ingress

**Minikube**
```bash
minikube start --cpus=6 --memory=12288 --disk-size=40g
minikube addons enable ingress
# set CLUSTER_PROFILE=minikube in .env
```

**OrbStack Kubernetes** (what this build was verified on)
```bash
kubectl config use-context orbstack
# set CLUSTER_PROFILE=orbstack in .env
```

Then, on either:
```bash
./scripts/install-prereqs.sh      # ingress-nginx + metrics-server
```

The chart is cluster-agnostic: `values-minikube.yaml` and `values-orbstack.yaml`
differ only in `storageClass`.

### Running on a small node (2 vCPU / 4 GB)

The default resource requests total **~1600m CPU / ~4544Mi memory**, which does
**not** fit a 2-core/4 GB node — the memory requests alone exceed the node's RAM,
so pods sit `Pending` on *Insufficient memory*. For that case add the small
overlay, which trims every tier to **~775m / ~2272Mi**:

```bash
minikube start --cpus=2 --memory=4096 --disk-size=20g
minikube addons enable ingress

helm upgrade --install magento charts/magento -n magento --create-namespace \
  -f charts/magento/values.yaml \
  -f charts/magento/values-minikube.yaml \
  -f charts/magento/values-minikube-small.yaml \
  --set-string domain="$MAGENTO_DOMAIN" ...
```

What you give up, stated plainly: 4 PHP-FPM workers (so ~4 concurrent PHP
requests — fine for a demo, not for load), a 256 MB OpenSearch heap (below
Elastic's comfort zone; fine for a small catalogue, will GC-thrash on a real
one), no HPA or PDB, and a noticeably slower first install. The numbers come from
summing the rendered resource requests; the overlay has not been run on an actual
2-core VM.

## 3. Configure

```bash
cp .env.example .env
```

| Variable | Notes |
|---|---|
| `MAGENTO_DOMAIN` | Cloudflare-managed hostname, or a `*.local` name for local mode |
| `MAGENTO_ADMIN_PATH` | a **non-default** admin path |
| `DB_PASSWORD`, `DB_ROOT_PASSWORD`, `MAGENTO_ADMIN_PASSWORD` | your own values |
| `MAGENTO_CRYPT_KEY` | `openssl rand -hex 16` |
| `MAGENTO_MARKETPLACE_*` | optional; leave empty to build without an Adobe account |
| `CLOUDFLARE_TUNNEL_TOKEN` | leave empty for a local-only deploy |

`.env` is git-ignored. Nothing sensitive is committed — secrets reach the cluster
only as `helm --set` values at deploy time, and Marketplace keys reach the build
only as a BuildKit secret mount, never a build arg or an image layer.

## 4. Build the images

```bash
./scripts/build-images.sh
```

Produces `magento-app` (PHP-FPM plus Magento compiled in production mode) and
`magento-nginx`. The first build pulls and compiles Magento and takes roughly
10–15 minutes.

| `.env` | Composer repository | Auth |
|---|---|---|
| `MAGENTO_MARKETPLACE_*` empty *(default)* | `https://mirror.mage-os.org/` | none |
| `MAGENTO_MARKETPLACE_*` set | `https://repo.magento.com/` | keys via BuildKit secret |

## 5. Create the Cloudflare Tunnel *(skip for a local-only deploy)*

1. Cloudflare dashboard → Zero Trust → Networks → Tunnels → **Create tunnel**
   (type *Cloudflared*). Copy the token into `CLOUDFLARE_TUNNEL_TOKEN`.
2. Add a **Public Hostname** on the tunnel:
   - Subdomain/Domain = your `MAGENTO_DOMAIN`
   - Service = `http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80`
3. In the zone: SSL/TLS → **Full**, and Edge Certificates → **Always Use HTTPS**
   (this is what enforces the HTTP→HTTPS redirect).

`cloudflared` runs inside the cluster and dials *out* to Cloudflare, so there is
no inbound port, no public IP and no router forwarding.

## 6. Deploy

```bash
./scripts/deploy.sh
```

`helm upgrade --install` renders the ConfigMap and Secrets from `.env`, brings up
the data tier, then a post-install Job runs `setup:install`, seeds one demo
product and reindexes.

```bash
kubectl -n magento logs -f job -l component=install
kubectl -n magento get pods -w
```

- Storefront: `<scheme>://<MAGENTO_DOMAIN>/`
- Admin: `<scheme>://<MAGENTO_DOMAIN>/<MAGENTO_ADMIN_PATH>`

### Reaching a local-mode deploy from your browser

The ingress controller is a ClusterIP service, so it is not reachable from the
host directly. Either forward it to port 80 and add a hosts entry:

```bash
sudo kubectl -n ingress-nginx port-forward --address 127.0.0.1 \
  svc/ingress-nginx-controller 80:80
echo "127.0.0.1  magento.local" | sudo tee -a /etc/hosts
```

Port 80 specifically, because Magento's `base_url` carries no port and every
generated link would otherwise drop the one you forwarded to. To test without
touching `/etc/hosts`, forward any port and set the Host header yourself:

```bash
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80 &
curl -s -H "Host: magento.local" -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/
```

## 7. Verify

```bash
./scripts/verify.sh
```

Checks every pod is Ready, MariaDB answers as the dedicated non-root user,
OpenSearch is green/yellow, the catalogue has at least one product, and then
drives the storefront, product page and admin path end to end through the ingress
from a throwaway curl pod — so the result does not depend on how your host
resolves DNS. The public-HTTPS check is skipped, not failed, on a local-only
deploy.

### Verified results

Run on OrbStack Kubernetes v1.34.8, local mode, `magento.local`:

```
== Health checks ==
  PASS all pods Running/Completed
  PASS MariaDB reachable as dedicated app user
  PASS OpenSearch healthy ("status":"yellow")
  PASS catalog has 1 product(s)

== In-cluster HTTP (via ingress) ==
  /health=200
  /=200
  /demo-product.html=200
  /admin_2fb3c6=302
  PASS storefront returns 200
  PASS product page returns 200
  PASS admin reachable on non-default path
```

The admin answering `302` is the correct behaviour — it redirects to the login
form with a per-session secret key.

Resource usage at idle:

| Pod | CPU | Memory |
|---|---|---|
| magento-web | 1m | 191Mi |
| magento-cron | 1m | 48Mi |
| mariadb-0 | 3m | 208Mi |
| opensearch-0 | 10m | 976Mi |
| redis | 3m | 14Mi |

## 8. Persistence and recovery

```bash
kubectl -n magento delete pod mariadb-0
kubectl -n magento get pvc                  # data-mariadb-0 still Bound
kubectl -n magento wait --for=condition=ready pod/mariadb-0 --timeout=180s
./scripts/verify.sh                          # catalogue still intact
```

## 9. Scaling the web tier

```bash
kubectl -n magento scale deployment magento-web --replicas=2
```

Safe because the web tier holds no state: sessions and cache live in Redis, media
on a shared PVC, static content is baked into the image, cron runs as its own
single replica, and `lock.provider=db` keeps concurrent maintenance commands from
colliding. Reasoning in [production-design.md](docs/production-design.md).

## 10. Backup, restore, cleanup

```bash
./scripts/backup.sh                       # -> backups/<timestamp>/{db.sql.gz,media.tar.gz}
./scripts/restore.sh backups/<timestamp>  # restore, flush cache, reindex
./scripts/cleanup.sh                      # uninstall, keep PVCs
./scripts/cleanup.sh --purge              # also delete PVCs and the namespace
```

---

## Design notes

**nginx and PHP-FPM are separate containers in one pod.** They scale together and
share the code over an `emptyDir`, but they fail, restart and are resource-capped
independently, and nginx runs unprivileged on 8080.

**Code is baked into the image, configuration is not.** `setup:di:compile` and
`setup:static-content:deploy` run at build time, so pods start in production mode
with nothing to compile. `app/etc/env.php` is rendered at pod start from the
ConfigMap and Secret, which keeps pods stateless and interchangeable.

**The data tier is never public.** MariaDB, OpenSearch and Redis are ClusterIP
(headless) services. Magento connects as a dedicated non-root MySQL user; root
credentials are only used by the install Job.

**Everything runs as uid 1000**, with a read-only code mount in the nginx
container.

### Things that needed solving

A few problems here have non-obvious causes and are worth recording:

- **Static content at build time with no database.** `setup:static-content:deploy`
  needs to know which store views to render for. With no DB it reads them from the
  `scopes` section of `app/etc/config.php`, which normally comes from
  `app:config:dump` on a live instance — a fresh `composer create-project` has
  none, and the build dies with *"The default website isn't defined."*
  `docker/magento-app/bin/build-scopes.php` injects the stock install's scopes
  before the deploy and strips them afterwards, so the shipped image does not have
  its store configuration locked read-only by `config.php`.

- **`X-Forwarded-Proto` cannot be passed through verbatim.** PHP treats
  `$_SERVER['HTTPS']` as *on* for any non-empty value other than the literal
  `"off"` — including the string `"http"`. Forwarding the header as-is therefore
  convinces Magento that a plain HTTP request was secure and bounces it to the
  HTTPS base URL. The vhost maps it explicitly so only a real `https` sets the
  flag.

- **Two separate 502s from undersized proxy buffers.** Magento's redirect and
  admin responses carry enough `Set-Cookie` data to overflow the default 4k/8k
  header buffer, in the pod's nginx (`fastcgi_buffer_size`) and again in the
  ingress controller (`proxy-buffer-size`). Both are set explicitly.

- **`cp -a` fails in the init container.** Copying the code into the shared
  `emptyDir` with `cp -a src/. /dest/` also stamps the source directory's mode and
  timestamps onto the volume root, which is owned by root — so a non-root uid gets
  `EPERM` and the pod never starts. The init container copies the *entries*
  instead, via `find -mindepth 1 -exec cp -t`, which also keeps dotfiles that a
  `*` glob would silently drop.

---

## Repository layout

```
.
├── Makefile                      # thin wrapper over scripts/
├── .env.example                  # configuration template (real .env is git-ignored)
├── architecture/architecture.md
├── charts/magento/
│   ├── values.yaml               # safe defaults, no secrets
│   ├── values-orbstack.yaml
│   ├── values-minikube.yaml
│   ├── values-minikube-small.yaml   # 2 vCPU / 4 GB profile
│   └── templates/                # config, secret, mariadb, opensearch, redis,
│                                 # magento, cron, install-job, ingress,
│                                 # cloudflared, pvc, hpa, pdb, networkpolicy
├── docker/
│   ├── magento-app/              # PHP-FPM + Magento, multi-stage, non-root
│   └── magento-nginx/            # unprivileged nginx + Magento vhost
├── scripts/                      # install-prereqs, build-images, deploy,
│                                 # verify, backup, restore, cleanup
└── docs/
    ├── troubleshooting.md        # 502/503/OOM/DB/search runbooks
    ├── production-design.md
    └── evidence/
```

## Known limitations

- The media PVC is **RWO**, which is fine on one node. A multi-node cluster needs
  RWX (EFS, Filestore, NFS) — covered in the production design doc.
- **NetworkPolicy ships disabled locally** because OrbStack's default flannel CNI
  does not enforce it. The policies are in the chart and are the intended
  production control under Calico or Cilium.
- The **OpenSearch security plugin is off**. Acceptable only because the service
  is ClusterIP and never public; production should enable TLS and auth.
- The **2 vCPU / 4 GB overlay is calculated, not yet measured** on a real small VM.
- The first `setup:install` takes several minutes. The install Job is idempotent
  and safe to re-run.

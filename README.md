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
| **Public exposure + TLS** | Cloudflare Tunnel, **or** Caddy + Let's Encrypt on a public-IP host |
| **Packaging** | Helm chart (`charts/magento`) |

Live at **<https://magento.devtocash.com>** on a 2 vCPU / 4 GB VPS.

Further reading:
**[test results](docs/test-results.md)** ·
[architecture](architecture/architecture.md) ·
[troubleshooting runbook](docs/troubleshooting.md) ·
[production design & trade-offs](docs/production-design.md)

[`docs/test-results.md`](docs/test-results.md) walks every acceptance criterion
with the command used and the output it returned, on a live 2 vCPU / 4 GB
deployment — including the eight defects that only showed up once it was actually
served over a tunnel.

---

## Three ways to expose it

| Mode | Set in `.env` | What happens |
|---|---|---|
| **Cloudflare Tunnel** | `CLOUDFLARE_TUNNEL_TOKEN` set | `cloudflared` dials *out* to Cloudflare. TLS at the edge, no inbound port, no public IP needed. Requires the domain's DNS to be on Cloudflare. |
| **Reverse proxy + Let's Encrypt** | token empty, `PUBLIC_SCHEME=https` | Caddy on a public-IP host terminates TLS and proxies to the ingress. Works with DNS anywhere — just an A record. Opens 80/443. |
| **Local only** | token empty, `PUBLIC_SCHEME` unset | `publicScheme=http`; reach the ingress directly on a `*.local` hostname. |

The live deployment uses the middle one, because `devtocash.com` is served by its
registrar's DNS. A Cloudflare Tunnel public hostname resolves to
`<tunnel-id>.cfargotunnel.com`, which only exists inside Cloudflare's DNS — so
the tunnel route would have meant migrating the whole zone's nameservers, apex
record and all, for no functional gain. Both are explicitly permitted by the
brief. Setup for the proxy route is in §7.

Whichever you pick, `publicScheme` is what keeps Magento consistent. It bakes the
scheme into `base_url` and its `use_secure` flags, so pointing a plain-HTTP
client at an instance installed as HTTPS gets you a redirect loop into a port
nothing is listening on.

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
./scripts/install-prereqs.sh      # ingress-nginx + metrics-server + proxy config
```

Besides installing the controller, that script patches one setting that the
deployment does not work without:

```yaml
# ConfigMap ingress-nginx-controller
data:
  use-forwarded-headers: "true"
```

By default ingress-nginx **overwrites** `X-Forwarded-Proto` with the scheme of
the connection it received. Behind a tunnel that is always plain `http`, so
Magento concludes an HTTPS request was insecure, redirects to its HTTPS base URL,
gets the same `http` again, and loops until the browser gives up. Trusting the
header is safe here only because the controller is not directly exposed — the
tunnel is the one way in and is itself the trusted proxy. On an internet-facing
controller, pair it with `proxy-real-ip-cidr` or any client can forge its own
scheme and source address.

The chart is cluster-agnostic: `values-minikube.yaml` and `values-orbstack.yaml`
differ only in `storageClass`.

### Running on a small node (2 vCPU / 4 GB)

The default resource requests total **~1600m CPU / ~4544Mi memory**, which does
**not** fit a 2-core/4 GB node — the memory requests alone exceed the node's RAM,
so pods sit `Pending` on *Insufficient memory*. Add the small overlay for that
case:

```bash
minikube start --driver=docker --cpus=2 --memory=3000mb --disk-size=25g
./scripts/install-prereqs.sh

helm upgrade --install magento charts/magento -n magento --create-namespace \
  -f charts/magento/values.yaml \
  -f charts/magento/values-minikube.yaml \
  -f charts/magento/values-minikube-small.yaml \
  --set-string domain="$MAGENTO_DOMAIN" ...
```

It brings the footprint to **~700m / ~1600Mi** at rest, peaking around
**950m / 2240Mi** while the one-shot install Job runs alongside everything else.
The figures are derived from `kubectl top` on a working deployment rather than
guessed — the per-component numbers are in the overlay's header comment.

Verified: this profile installs and serves on a 2 vCPU / 3.8 GiB Ubuntu 24.04
VPS, with all six pods Ready 2m24s after `deploy.sh`.

What you give up, stated plainly: 4 PHP-FPM workers (so ~4 concurrent PHP
requests — fine for a demo, not for load), a 256 MB OpenSearch heap (below
Elastic's comfort zone; fine for a small catalogue, will GC-thrash on a real
one), no HPA or PDB, and limits close enough to requests that a real traffic
spike gets the pod OOM-killed rather than the node swapping to death — on a box
this size that is the better failure mode, but it is a deliberate choice.

One caveat specific to the docker driver: `--memory=3000mb` caps the minikube
container's cgroup, but the kubelet inside still reads the *host's* `/proc/meminfo`
and advertises ~3.9 GiB allocatable. The scheduler will therefore happily place
more than the cgroup allows. Keeping the workload's requests well under the cap,
as this overlay does, is what stops that mismatch from turning into an OOM kill.

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

## 7. Deploying to a remote single-node server

Building the app image needs far more CPU and RAM than a small VPS has, so the
image is built by CI and the server only pulls it. `.github/workflows/build-images.yml`
builds both images for `linux/amd64` on every push that touches `docker/` and
pushes them to `ghcr.io/<owner>/{magento-app,magento-nginx}`. Make both packages
public, or give the cluster an image pull secret.

This also matters if you develop on Apple Silicon: images built locally are
`arm64` and will not run on an `amd64` server. CI settles that.

On the server:

```bash
git clone https://github.com/<owner>/magento-k8s.git /opt/magento-k8s
cd /opt/magento-k8s

minikube start --driver=docker --cpus=2 --memory=3000mb --disk-size=25g --force
./scripts/install-prereqs.sh

# Pre-pull so the first deploy is not also a 1.3 GB download
minikube image pull ghcr.io/<owner>/magento-app:2.4.7-p3
minikube image pull ghcr.io/<owner>/magento-nginx:2.4.7-p3
```

Point `.env` at the registry and the small-node profile:

```bash
IMAGE_REGISTRY=ghcr.io/<owner>
EXTRA_VALUES=charts/magento/values-minikube-small.yaml
CLUSTER_PROFILE=minikube
PUBLIC_SCHEME=https          # TLS terminates at Cloudflare, not in the cluster
CLOUDFLARE_TUNNEL_TOKEN=     # empty: the tunnel runs on the host, not in-cluster
```

Then `./scripts/deploy.sh`.

### The tunnel, on the host

Running `cloudflared` on the host rather than in-cluster keeps one pod off a
small node and survives a cluster restart. It reaches the ingress at the
minikube node IP:

```bash
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
  | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt-get update && sudo apt-get install cloudflared

sudo cloudflared service install <TUNNEL_TOKEN>
```

Then add a Public Hostname on the tunnel pointing at `HTTP` → `<minikube ip>:80`
(`minikube ip` is typically `192.168.49.2`), and set `MAGENTO_DOMAIN` to that
hostname.

### Or: reverse proxy + Let's Encrypt (what the live deployment runs)

If the domain's DNS lives somewhere other than Cloudflare, this is the shorter
path — one A record, no nameserver migration:

```
A    magento    ->    <your VPS public IP>
```

Then on the host:

```bash
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update && sudo apt-get install -y caddy
```

`/etc/caddy/Caddyfile` — Caddy obtains and renews the certificate itself, and
redirects HTTP to HTTPS without being told to:

```caddyfile
magento.example.com {
    reverse_proxy 192.168.49.2:80     # minikube ip; ingress-nginx listens there
    encode gzip
}
```

```bash
sudo systemctl enable --now caddy
sudo systemctl restart caddy          # `enable --now` will not reload a running instance
```

Set `MAGENTO_DOMAIN` to that hostname and `PUBLIC_SCHEME=https`, leave
`CLOUDFLARE_TUNNEL_TOKEN` empty, and deploy.

Two things worth knowing. Caddy's systemd unit sandboxes its writable paths, so
a `log { output file ... }` directive fails with *permission denied* unless the
directory is added to `ReadWritePaths` — journald is simpler. And listing several
hostnames in one site block gets a certificate covering all of them, which is a
cheap way to keep a fallback name working.

### Surviving a reboot

Three units have to come back on their own, and minikube ships no service file:

```bash
sudo systemctl enable docker caddy
sudo tee /etc/systemd/system/minikube.service >/dev/null <<'EOF'
[Unit]
Description=minikube cluster
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
Environment=MINIKUBE_HOME=/root/.minikube
ExecStart=/usr/local/bin/minikube start
ExecStop=/usr/local/bin/minikube stop
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable minikube
```

`minikube start` with no flags reuses the existing profile, so the cpu and memory
limits chosen at creation survive the restart.

**Without a domain of your own**, a Quick Tunnel gives you a free
`*.trycloudflare.com` hostname and real HTTPS with no account at all:

```bash
cloudflared tunnel --url http://192.168.49.2:80
# INF |  https://<random-words>.trycloudflare.com   |
```

Set `MAGENTO_DOMAIN` to that hostname before deploying. Be aware of what you are
trading away: Cloudflare hands out a **new random hostname every time the process
restarts**, and Magento stores its base URL in the database — so a restart leaves
the store answering on a URL it does not believe in. It is fine for a demo, not
for anything that has to stay up. After such a restart:

```bash
kubectl -n magento exec deploy/magento-web -c php-fpm -- \
  php bin/magento config:set web/unsecure/base_url "https://<new-host>/"
kubectl -n magento exec deploy/magento-web -c php-fpm -- \
  php bin/magento config:set web/secure/base_url "https://<new-host>/"
kubectl -n magento exec deploy/magento-web -c php-fpm -- php bin/magento cache:flush
helm upgrade ... --set-string domain=<new-host>   # so the Ingress host matches too
```

## 8. Verify

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

## 9. Monitoring with Grafana Cloud *(optional)*

Nice to have, not required — the deployment is complete without it. It ships
cluster and host metrics, Kubernetes events, and **centralised pod logs** to
Grafana Cloud through Grafana Alloy, which is what turns `kubectl logs` into
something you can query across restarts.

```bash
./scripts/install-monitoring.sh
```

### Getting the credentials

You need five values, all from a free Grafana Cloud account:

1. Sign up at <https://grafana.com> and open your stack.
2. **Connections → Add new connection → Kubernetes**, then start the guided
   install. It generates a Helm command containing everything below.
3. From that generated command, copy into `.env`:

| `.env` variable | Where it is in the generated snippet |
|---|---|
| `GRAFANA_PROM_URL` | `destinations.grafana-cloud-metrics.url` |
| `GRAFANA_PROM_USER` | the numeric `username` under that destination |
| `GRAFANA_LOKI_URL` | `destinations.grafana-cloud-logs.url` |
| `GRAFANA_LOKI_USER` | the numeric `username` under that destination |
| `GRAFANA_CLOUD_TOKEN` | the `glc_...` password — the same token is used for both |

The two usernames are **different numbers** — they are per-service instance IDs,
not your account ID. Copy each from its own block.

To mint the token by hand instead: **Administration → Users and access → Access
Policies → Create access policy**, scopes `metrics:write` and `logs:write`, then
add a token to it. `.env` is git-ignored, so the token is never committed.

### What is deliberately turned off

Grafana's wizard generates a config that enables everything — five Alloy
collectors, OTLP receivers, Beyla eBPF auto-instrumentation, eBPF profiling to
Pyroscope, OpenCost, Kepler, a Windows exporter. On a 2 vCPU / 4 GB node that is
roughly 1.5 GB of collectors competing with the workload they exist to observe,
and the first thing the kernel reaps is OpenSearch — the largest pod on the box.

[`monitoring/k8s-monitoring-values.yaml`](monitoring/k8s-monitoring-values.yaml)
keeps metrics, events and logs, and drops the rest. Measured cost:

| Pod | CPU | Memory |
|---|---|---|
| alloy-metrics | 60m | 172Mi |
| alloy-operator | 77m | 47Mi |
| kube-state-metrics | 6m | 15Mi |
| node-exporter | 1m | 3Mi |
| alloy-logs, alloy-singleton | — | ~60Mi combined |

About **300 MiB total**, against ~1 GB of headroom. Verified after install: all
Magento pods stayed Running and Alloy reported no send errors.

If you have a bigger node, the wizard's full config is the better starting point
— tracing and profiling are genuinely useful, just not affordable here.

## 10. Persistence and recovery

```bash
kubectl -n magento delete pod mariadb-0
kubectl -n magento get pvc                  # data-mariadb-0 still Bound
kubectl -n magento wait --for=condition=ready pod/mariadb-0 --timeout=180s
./scripts/verify.sh                          # catalogue still intact
```

## 11. Scaling the web tier

```bash
kubectl -n magento scale deployment magento-web --replicas=2
```

Safe because the web tier holds no state: sessions and cache live in Redis, media
on a shared PVC, static content is baked into the image, cron runs as its own
single replica, and `lock.provider=db` keeps concurrent maintenance commands from
colliding. Reasoning in [production-design.md](docs/production-design.md).

## 12. Backup, restore, cleanup

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

- **The install pod's `config.php` poisons every other pod.** `setup:install`
  rewrites `app/etc/config.php` inside whichever pod runs it and records that
  file's hash in the database. That pod is a Job — it exits, and every long-lived
  pod still has the image's original `config.php`, whose hash no longer matches.
  Magento answers every request with *"The configuration file has changed"* and a
  500. The install script restores the shipped file from
  `/usr/local/share/config.php.dist` and re-syncs the recorded hash to it —
  with two details that are easy to get wrong. It flushes the cache first,
  because Magento caches the deployment config and right after `setup:install`
  that cache still describes the mutated file, so the importer sees no change and
  leaves the stale hash alone. And it uses `setup:upgrade` rather than
  `app:config:import`, because import only rewrites the hash when it has content
  to import, which a pristine `config.php` does not.

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
- **NetworkPolicy ships disabled** because neither OrbStack nor minikube's default CNI
  does not enforce it. The policies are in the chart and are the intended
  production control under Calico or Cilium.
- The **OpenSearch security plugin is off**. Acceptable only because the service
  is ClusterIP and never public; production should enable TLS and auth.
- A **Quick Tunnel hostname is not stable** — it changes on every `cloudflared`
  restart, and Magento stores its base URL in the database. Use a real domain for
  anything that has to survive a restart.
- The first `setup:install` takes several minutes. The install Job is idempotent
  and safe to re-run.
- **Not implemented:** container image vulnerability scanning, and centralised
  metrics/logging beyond `kubectl top` via metrics-server.

## Machines used

| Role | Spec |
|---|---|
| Development | macOS (Apple Silicon), 12 vCPU / 24 GB, OrbStack Kubernetes |
| Image build | GitHub Actions `ubuntu-latest` — needed for `linux/amd64` output |
| Deployment target | Linode VPS, Ubuntu 24.04, **2 vCPU / 3.8 GiB RAM**, 79 GB disk |

## Estimated effort

Roughly **two and a half days**:

| Phase | Time |
|---|---|
| Chart, images, install flow | ~1 day |
| Scripts, docs, local verification | ~0.5 day |
| Tunnel, TLS, security hardening | ~0.5 day |
| Deploying to the 2-core VPS and debugging what only broke there | ~0.5 day |

That last half day is the honest one. Eight defects only appeared once the store
was served over a real tunnel on a small node rather than over plain HTTP on a
laptop — two undersized header buffers, an `X-Forwarded-Proto` the ingress
rewrote, and a config hash recorded by a pod that no longer exists. They are
listed with root causes in [docs/test-results.md](docs/test-results.md).

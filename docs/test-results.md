# Test Results

Every acceptance criterion from the assessment brief, with the command used and
the output it produced. Nothing here is a summary of what should happen — it is
what the environment returned when the commands were run against it.

## Environment under test

| | |
|---|---|
| Host | Linode VPS, Ubuntu 24.04.4 LTS, **2 vCPU / 3.8 GiB RAM** / 79 GB disk, x86_64 |
| Cluster | minikube v1.38.1, Kubernetes v1.35.1, docker driver, `--cpus=2 --memory=3000mb` |
| Images | `ghcr.io/rephapeng/magento-app:2.4.7-p3`, `ghcr.io/rephapeng/magento-nginx:2.4.7-p3` (built by GitHub Actions, `linux/amd64`) |
| Values | `values.yaml` + `values-minikube.yaml` + `values-minikube-small.yaml` |
| Public URL | `https://sullivan-lines-knights-chevy.trycloudflare.com` |
| Admin path | `/admin_c87bc2` (non-default, generated per environment) |
| Commit | `c8d2402` |

The whole run below is against a deployment created from scratch — namespace
deleted, image re-pulled, `./scripts/deploy.sh` — with no manual fix-ups
afterwards.

---

## 1. Deployment is repeatable

**How**

```bash
git clone https://github.com/rephapeng/magento-k8s.git /opt/magento-k8s
cd /opt/magento-k8s          # then fill in .env
minikube start --driver=docker --cpus=2 --memory=3000mb --disk-size=25g
./scripts/install-prereqs.sh
./scripts/deploy.sh
```

**Result** — all six pods Ready, both hook Jobs Complete, **2m22s** after
`deploy.sh` started:

```
NAME                           READY   STATUS      RESTARTS   AGE
magento-config-sync-1-98gzk    0/1     Completed   0          40s
magento-cron-589496bcc-fwnfj   1/1     Running     0          2m22s
magento-install-1-gdcml        0/1     Completed   0          2m21s
magento-web-55cfb5fd54-cwfvm   2/2     Running     0          2m22s
mariadb-0                      1/1     Running     0          2m22s
opensearch-0                   1/1     Running     0          2m21s
redis-6c6cbd59c-vkjsw          1/1     Running     0          2m22s
```

This exact cycle was run four times end to end while the defects in §9 were being
fixed, which is what gives the "repeatable" claim its evidence.

**Status: PASS**

---

## 2. Kubernetes resources (brief §3.1)

**How**

```bash
kubectl -n magento get deploy,statefulset,job,svc,ingress,cm,secret,pvc
```

**Result**

```
deployment.apps/magento-cron   1/1   1   1
deployment.apps/magento-web    1/1   1   1
deployment.apps/redis          1/1   1   1
statefulset.apps/mariadb      1/1
statefulset.apps/opensearch   1/1
job.batch/magento-install-1       Complete   1/1   102s
job.batch/magento-config-sync-1   Complete   1/1   14s

NAME          TYPE        CLUSTER-IP     PORT
magento-web   ClusterIP   10.107.84.71   80
mariadb       ClusterIP   None           3306
opensearch    ClusterIP   None           9200
redis         ClusterIP   None           6379

NAME      CLASS   HOSTS                                            ADDRESS        PORTS
magento   nginx   sullivan-lines-knights-chevy.trycloudflare.com   192.168.49.2   80

configmap/magento-config   25 keys
secret/magento-secret      Opaque   4 keys

NAME                STATUS   CAPACITY   ACCESS MODES   STORAGECLASS
data-mariadb-0      Bound    8Gi        RWO            standard
data-opensearch-0   Bound    5Gi        RWO            standard
magento-media       Bound    5Gi        RWO            standard
```

Dedicated namespace `magento`; Deployment for the web tier; StatefulSets for the
two components with identity-bound storage; a Service per component; one Ingress;
ConfigMap and Secret as separate objects with no overlap; three PVCs.

**Probes and resource bounds**

```bash
kubectl -n magento get deploy magento-web -o jsonpath='{.spec.template.spec.containers[*]}'
```

| Container | Readiness | Liveness | Requests | Limits |
|---|---|---|---|---|
| php-fpm | `tcpSocket :9000` (20s delay, 10s period) | `tcpSocket :9000` (60s delay, failureThreshold 6) | 300m / 512Mi | 896Mi |
| nginx | `httpGet /health:8080` | `httpGet /health:8080` | 25m / 32Mi | 64Mi |
| mariadb | `mariadb -e 'SELECT 1'` | — | 100m / 256Mi | 512Mi |
| opensearch | `httpGet /_cluster/health?local=true` | — | 200m / 640Mi | 896Mi |

The liveness probe is deliberately laxer than the readiness probe — 60s initial
delay and six consecutive failures before a restart. A liveness probe as eager as
the readiness one would restart pods during a slow first request instead of
merely taking them out of rotation, which is the classic way to turn a slow store
into a restart loop.

**Status: PASS**

---

## 3. Magento is functional (brief §3.2)

**How**

```bash
kubectl -n magento exec deploy/magento-web -c php-fpm -- php bin/magento --version
kubectl -n magento exec deploy/magento-web -c php-fpm -- php bin/magento deploy:mode:show
kubectl -n magento exec deploy/magento-web -c php-fpm -- php bin/magento config:show web/unsecure/base_url
kubectl -n magento exec deploy/magento-web -c php-fpm -- php bin/magento config:show catalog/search/engine
kubectl -n magento exec deploy/magento-web -c php-fpm -- php bin/magento cache:status
kubectl -n magento exec deploy/magento-web -c php-fpm -- find /var/www/html/pub/static -type f | wc -l
```

**Result**

```
Magento CLI 2.4.7-p3
Current application mode: production.
https://sullivan-lines-knights-chevy.trycloudflare.com/     <- base_url is the public domain
opensearch                                                  <- search engine wired
cache=Redis  session=redis
config: 1   layout: 1   block_html: 1   collections: 1   reflection: 1     <- all cache types enabled
7183                                                        <- static content files deployed
frontName=admin_c87bc2                                      <- non-default admin path
1  demo-product-1                                           <- catalogue has a product
```

Indexers report `Ready` on a `Schedule` update mode with an empty backlog.

**Status: PASS** — install completed with no unhandled errors, base URL is the
public domain, database and search engine are connected, static content is
deployed, cache is on Redis, and there is a product.

---

## 4. Public HTTPS and HTTP redirect (brief §3.3, §7)

**How**

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://sullivan-lines-knights-chevy.trycloudflare.com/
curl -s -o /dev/null -w "%{http_code}\n" https://sullivan-lines-knights-chevy.trycloudflare.com/demo-product.html
curl -sL -o /dev/null -w "%{http_code}\n" https://sullivan-lines-knights-chevy.trycloudflare.com/admin_c87bc2
curl -s -D - -o /dev/null http://sullivan-lines-knights-chevy.trycloudflare.com/
```

**Result**

| Endpoint | Code | Page title |
|---|---|---|
| `/` | **200** (32,809 B) | `<title>Home page</title>` |
| `/demo-product.html` | **200** (53,565 B) | `<title>Demo Product</title>` |
| `/admin_c87bc2` | **200** (8,063 B, after one redirect) | `<title>Magento Admin</title>` |

HTTP → HTTPS:

```
HTTP/1.1 302 Found
Location: https://sullivan-lines-knights-chevy.trycloudflare.com/
```

The admin's intermediate `302` carries a per-session secret key
(`/admin_c87bc2/admin/index/index/key/<64 hex>/`) — that is Magento's correct
behaviour, not a failure.

These requests come from a laptop on the public internet, not from the host and
not through `kubectl port-forward`.

**Status: PASS**

---

## 5. Traffic path

```
Browser
  └── HTTPS ──> Cloudflare edge            TLS terminates here
        └── QUIC tunnel (outbound only) ──> cloudflared (systemd, on the host)
              └── HTTP ──> 192.168.49.2:80  minikube node IP
                    └── ingress-nginx       host rule -> magento-web
                          └── Service magento-web:80 (ClusterIP)
                                └── pod: nginx :8080
                                      └── FastCGI 127.0.0.1:9000 -> php-fpm
                                            └── MariaDB / OpenSearch / Redis (ClusterIP)
```

No inbound port is open on the VPS for the store — `cloudflared` dials *out* to
Cloudflare. Verified: `ss -ltnp` shows nothing listening on 3306, 9200 or 6379.

---

## 6. Persistence and recovery (brief §3.4)

To prove data *survives* rather than being recreated, a marker row was written
first, and the PV identity was compared before and after.

**How**

```bash
kubectl -n magento exec mariadb-0 -- mysql -umagento -p*** magento \
  -e "CREATE TABLE IF NOT EXISTS persistence_probe(id INT PRIMARY KEY, note VARCHAR(64));
      REPLACE INTO persistence_probe VALUES (1,'written-before-pod-delete');"
kubectl -n magento get pvc data-mariadb-0 -o jsonpath='{.spec.volumeName}'

kubectl -n magento delete pod mariadb-0
kubectl -n magento wait --for=condition=ready pod/mariadb-0 --timeout=300s

kubectl -n magento get pvc data-mariadb-0 -o jsonpath='{.spec.volumeName}'
kubectl -n magento exec mariadb-0 -- mysql -umagento -p*** magento \
  -e "SELECT note FROM persistence_probe; SELECT sku FROM catalog_product_entity;"
```

**Result**

```
before: PV = pvc-57d8a430-8514-4be9-b967-7c6f46e80425
pod "mariadb-0" deleted
pod/mariadb-0 condition met                     <- back Ready in 28s (01:23:38 -> 01:24:06)
after:  PV = pvc-57d8a430-8514-4be9-b967-7c6f46e80425    <- IDENTICAL, reattached not recreated

written-before-pod-delete                       <- marker row survived
demo-product-1                                  <- catalogue survived
```

**Media PVC**, same method against the web pod:

```bash
kubectl -n magento exec deploy/magento-web -c php-fpm -- \
  sh -c 'echo media-file-survives-pod-delete > /var/www/html/pub/media/persistence-probe.txt'
kubectl -n magento delete pod magento-web-55cfb5fd54-6d454
# new pod magento-web-55cfb5fd54-htprt:
kubectl -n magento exec deploy/magento-web -c php-fpm -- cat /var/www/html/pub/media/persistence-probe.txt
  -> media-file-survives-pod-delete
```

**Status: PASS** — database, media and the catalogue all survive pod deletion,
and the same PV is reattached rather than a fresh one provisioned.

---

## 7. Scaling the web tier (brief §3.5)

**How**

```bash
kubectl -n magento scale deployment magento-web --replicas=2
kubectl -n magento rollout status deploy/magento-web
kubectl -n magento get endpointslice -l kubernetes.io/service-name=magento-web
```

**Result**

```
deployment "magento-web" successfully rolled out

magento-web-55cfb5fd54-27lms   true,true   minikube
magento-web-55cfb5fd54-htprt   true,true   minikube

10.244.0.41 ready=true         <- both pods in the Service's endpoints
10.244.0.42 ready=true

req1: 200  req2: 200  req3: 200  req4: 200     <- storefront across repeated requests
```

Host memory with two replicas: 2112 MiB used of 3915 MiB.

**Why two replicas are actually safe here** — the prerequisites the brief asks
about, and where each is handled:

| Concern | How it is satisfied |
|---|---|
| Session storage | Redis (`session.save=redis`, db 2) — not on local disk, so any replica can serve any session |
| Cache backend | Redis (default cache db 0, full-page cache db 1) — one invalidation is seen by every replica |
| Shared media | `magento-media` PVC mounted into every web pod and the cron pod |
| Static content | Baked into the image at build time, so every replica serves byte-identical assets with no post-deploy generation step |
| Cron / queue consumers | A **separate single-replica** Deployment. Running cron in the web pods would mean N concurrent schedulers competing for the same jobs |
| Concurrent maintenance commands | `lock.provider=db`, so CLI commands across pods coordinate through the database |
| Load balancing and readiness | Service + EndpointSlice; a pod only joins once its readiness probe passes, so a starting replica never receives traffic |

**Status: PASS**

---

## 8. Security (brief §3.6)

**How**

```bash
kubectl -n magento exec mariadb-0 -- mysql -umagento -p*** -e "SELECT CURRENT_USER(); SHOW DATABASES;"
kubectl -n magento exec mariadb-0 -- mysql -uroot -p*** -e 'SHOW GRANTS FOR magento@"%";'
kubectl -n magento exec <pod> -- id                      # per component
kubectl -n magento get svc -o jsonpath='{range .items[*]}{.metadata.name}={.spec.type}{" "}{end}'
```

**Result**

```
CURRENT_USER() = magento@%                       <- not root
SHOW DATABASES = information_schema, magento     <- nothing else is visible

GRANT USAGE ON *.* TO `magento`@`%`
GRANT ALL PRIVILEGES ON `magento`.* TO `magento`@`%`     <- scoped to its own schema
```

Every container runs as a non-root user:

```
mariadb-0      uid=999(mysql)
opensearch-0   uid=1000(opensearch)
redis          uid=999(redis)
magento-web    uid=1000(magento)
magento-cron   uid=1000(magento)
```

Service types — nothing but ClusterIP, and no NodePort anywhere in the namespace:

```
magento-web=ClusterIP  mariadb=ClusterIP  opensearch=ClusterIP  redis=ClusterIP
nodePort count: 0
```

**No secrets in the repository:**

```bash
git ls-files | wc -l                    # 49 tracked files
git ls-files | grep -x '.env'           # (no match) — .env is git-ignored
git grep -l '<each real password from the server .env>'   # (no match)
git grep -l 'eyJhIjoiZGE2OWY4'          # (no match) — tunnel token absent
```

Secrets reach the cluster only as `helm --set` values read from a git-ignored
`.env` at deploy time; Marketplace keys reach the build only as a BuildKit secret
mount, never a build arg or image layer.

**Admin endpoint** is on a generated non-default path (`/admin_c87bc2`). Beyond
the non-default path, access can be narrowed with a Cloudflare Access policy on
that route, an ingress IP allow-list annotation, and Magento's own two-factor
authentication — none of which are enabled here.

**Status: PASS**

---

## 9. Defects found and fixed during testing

These were all found by running the thing, not by reading it. Each is fixed in
the repository, and the fix is verified by the clean-deploy cycle in §1.

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | Image build failed: *"The default website isn't defined"* | `setup:static-content:deploy` needs store scopes; with no DB it reads them from `config.php`, which a fresh `composer create-project` has none of | `build-scopes.php` injects the stock scopes for the deploy, then strips them |
| 2 | `setup:install` rejected the base URL | Magento refuses any `--base-url-secure` that is not `https` | HTTP mode omits the flag entirely (`publicScheme`) |
| 3 | Init container `CrashLoopBackOff`, `cp: preserving permissions ... Operation not permitted` | `cp -a src/. /dest/` stamps the source dir's mode onto the emptyDir root, which is root-owned; uid 1000 gets EPERM | Copy the *entries* via `find -mindepth 1 -exec cp -t`, which also keeps dotfiles |
| 4 | HTTP 502 on every PHP page | Magento's `Set-Cookie` headers overflow the default 4k/8k header buffer — in the pod's nginx **and** again in the ingress controller | `fastcgi_buffer_size 32k` and `proxy-buffer-size: 32k` |
| 5 | Infinite redirect `/` → `/index.php/` over the tunnel | ingress-nginx **overwrites** `X-Forwarded-Proto` with its own scheme (http), so Magento thought an HTTPS request was insecure and bounced it to the https base URL forever | `use-forwarded-headers: "true"` on the controller, set by `install-prereqs.sh` |
| 6 | Every page 500: *"The configuration file has changed"* | `setup:install` rewrites `config.php` in the Job pod and records that file's hash; the Job exits and every long-lived pod still has the image's copy | A second Job at hook-weight 1 runs `setup:upgrade` from a clean pod |
| 7 | PHP saw a plain-`http` forwarded scheme as secure | PHP treats `$_SERVER['HTTPS']` as *on* for any non-empty value except literal `"off"` — including the string `"http"` | nginx `map` so only a real `https` sets the flag |
| 8 | MariaDB container ran as root | Pod `securityContext` was not set; the official entrypoint starts as root to chown the datadir | `runAsUser: 999` + `fsGroup: 999`, so PID 1 is never root |

Defect 6 is worth singling out, because the obvious fix does not work. Restoring
the shipped `config.php` inside the installer and running `app:config:import`
there reports *"Nothing to import"* and leaves the stale hash — the process has
already loaded the mutated configuration, and import only rewrites the hash when
it has content to import. The identical command from a pod that started clean
reports *"System config was processed"*. That is why it is a separate Job rather
than three more lines in the install script.

---

## 10. Observability (brief §3.7)

**How and result**

```bash
$ kubectl -n magento rollout status deploy/magento-web
deployment "magento-web" successfully rolled out

$ kubectl -n magento get events --sort-by=.lastTimestamp | tail -3
70s   Normal   Started     pod/magento-config-sync-1-98gzk   Container started
59s   Normal   Completed   job/magento-config-sync-1         Job completed

$ kubectl -n magento logs deploy/magento-web -c nginx --tail=2
10.244.0.14 - - [26/Jul/2026:01:56:05] "GET /admin_c87bc2 HTTP/1.1" 200 2197 "curl/8.5.0" "2400:8901::2000:4cff:fef8:e4d2"

$ kubectl -n magento logs deploy/magento-web -c php-fpm --tail=2
127.0.0.1 - 26/Jul/2026:01:56:04 "GET /index.php" 200

$ kubectl -n magento logs deploy/magento-cron --tail=2
Ran jobs by schedule.

$ kubectl -n magento exec opensearch-0 -- curl -s "localhost:9200/_cluster/health?pretty"
"status" : "yellow", "number_of_nodes" : 1, "discovered_cluster_manager" : true

$ kubectl -n magento exec mariadb-0 -- mysqladmin -umagento -p*** status
Uptime: 159  Threads: 3  Questions: 23794  Slow queries: 0  Queries per second avg: 149.647

$ kubectl -n magento top pods
magento-cron-589496bcc-fwnfj   135m   16Mi
magento-web-55cfb5fd54-cwfvm     4m   34Mi
mariadb-0                       51m  188Mi
opensearch-0                    39m  629Mi
redis-6c6cbd59c-vkjsw           12m   11Mi
```

The nginx access log carries the real client address forwarded from Cloudflare
(`2400:8901::...`), which is a side effect of the fix for defect 5.

OpenSearch reporting **yellow** is expected and not a fault: a single-node
cluster cannot place replica shards, so it is never green. Red would mean
*primary* shards unassigned — that is the state to act on.

**Status: PASS**

---

## 11. Troubleshooting playbook (brief §5)

Two of these were not hypothetical during this build — 502 and the config-hash
500 both actually happened, and the investigation below is the one that was used.

### Scenario 1 — HTTP 502

Walk the path in order, stopping at the first hop that misbehaves:

```bash
curl -sI https://<domain>/                                   # 1. does the edge answer at all?
journalctl -u cloudflared -n 50                              # 2. is the tunnel connected?
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=50 | grep -i error
kubectl -n magento get endpointslice -l kubernetes.io/service-name=magento-web
kubectl -n magento port-forward svc/magento-web 18081:80     # 4. bypass the ingress
curl -H "Host: <domain>" -H "X-Forwarded-Proto: https" http://127.0.0.1:18081/
kubectl -n magento logs deploy/magento-web -c nginx --tail=50
kubectl -n magento logs deploy/magento-web -c php-fpm --tail=50
```

Reading the answer:

- **`upstream sent too big header`** in the pod's nginx → header buffers, not
  connectivity. This is what defect 4 was.
- 502 from the *controller* while the pod returns 200 to a port-forward → the
  problem is the ingress layer, not the app. Comparing those two responses is
  what isolated the second half of defect 4.
- **`connect() failed (111: Connection refused)`** → php-fpm is down or on the
  wrong port; check `tcpSocket :9000` readiness.
- **`upstream timed out`** → a slow request, not a broken one; look at
  `fastcgi_read_timeout` and what PHP is actually doing.
- Empty endpoints → not a 502 problem at all, see scenario 2.

### Scenario 2 — HTTP 503

503 means the ingress has nowhere to send the request.

```bash
kubectl -n magento get endpointslice -l kubernetes.io/service-name=magento-web   # empty?
kubectl -n magento get pods -l component=web                                     # 0/2 Ready?
kubectl -n magento describe pod <pod> | grep -A5 -i readiness                    # why failing?
kubectl -n magento get svc magento-web -o jsonpath='{.spec.selector}'            # selector match?
kubectl -n magento exec deploy/magento-web -c php-fpm -- php bin/magento maintenance:status
```

Distinguish: **empty endpoints** = no Ready pod, or a Service selector that
matches no labels. **Pods Ready but 503 from Magento** = application-level —
maintenance mode, or the database or search engine being unreachable, in which
case the exception log names which.

### Scenario 3 — Pod OOMKilled

```bash
kubectl -n magento describe pod <pod> | grep -A3 "Last State"    # Reason: OOMKilled
kubectl -n magento logs <pod> -c php-fpm --previous              # what it was doing
kubectl -n magento top pod <pod>                                 # actual vs configured
```

The reasoning that matters: `requests` only affect *scheduling*; the **limit** is
what kills. For PHP-FPM the limit has to cover
`pm.max_children × peak worker RSS`. This deployment runs 4 workers at roughly
150 MiB peak each under a 896Mi limit. Raising `maxChildren` without raising the
limit is the standard way to cause this — the pod survives idle and dies under
concurrency, which makes it look intermittent.

### Scenario 4 — Database pod deleted

Demonstrated for real in §6. The check sequence:

```bash
kubectl -n magento get pvc data-mariadb-0 -o jsonpath='{.spec.volumeName}'   # note the PV
kubectl -n magento delete pod mariadb-0
kubectl -n magento wait --for=condition=ready pod/mariadb-0 --timeout=300s
kubectl -n magento get pvc data-mariadb-0 -o jsonpath='{.spec.volumeName}'   # same PV?
kubectl get pv <name> -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'
```

The StatefulSet re-creates `mariadb-0` with the same identity, so it re-binds the
same PVC and therefore the same PV. Comparing the PV name before and after is the
part that actually proves it — a pod that came back healthy with an *empty*
database would look identical in `kubectl get pods`.

### Scenario 5 — Search engine unhealthy

```bash
kubectl -n magento exec opensearch-0 -- curl -s "localhost:9200/_cluster/health?pretty"
kubectl -n magento exec opensearch-0 -- curl -s "localhost:9200/_cat/indices?v"
kubectl -n magento logs opensearch-0 --tail=100 | grep -iE "error|exception|circuit|gc"
kubectl -n magento exec deploy/magento-web -c php-fpm -- php bin/magento indexer:status
```

`yellow` on a single node is normal (no replica placement). `red` means missing
primaries. The Magento-facing consequence: catalogue search and layered
navigation degrade or empty out while product pages and checkout keep working,
because those read from MySQL. Recovery is `indexer:reindex` once the cluster is
healthy. On this node the most likely cause is the 256 MB heap — check the logs
for GC pressure and circuit breaker trips before assuming data loss.

---

## 12. Bonus items (brief §8)

| Item | Status |
|---|---|
| Helm chart | Done — single chart, three value overlays |
| Redis for cache and session | Done — session db 2, cache db 0, full-page cache db 1 |
| HPA and PDB | In the chart; **disabled** in the small-node profile — nothing to scale onto on one 2-core node |
| NetworkPolicy | Written, **not enforced** here — minikube's default CNI ignores it. Production control under Calico/Cilium |
| CI/CD pipeline | Done — GitHub Actions builds both images for `linux/amd64` and pushes to ghcr.io on every push touching `docker/` |
| Custom efficient image | Done — multi-stage; the build toolchain and Composer never reach the runtime layer |
| Automatic TLS | Done, at the Cloudflare edge |
| Zero-downtime deploys | Rolling update + readiness gating; demonstrated by the 2-replica rollout in §7 |
| Image vulnerability scanning | **Not implemented** |
| Metrics / dashboards / centralised logging | **Not implemented** — `kubectl top` via metrics-server only |

---

## 13. Known limitations

Stated plainly, because they are real and a reviewer will find them:

1. **The public hostname is ephemeral.** A Cloudflare Quick Tunnel issues a new
   random `*.trycloudflare.com` name every time `cloudflared` restarts, and
   Magento stores its base URL in the database — so a restart leaves the store
   answering on a URL it does not believe in. A named tunnel on a real domain
   fixes this; the recovery procedure is in the README.
2. **NetworkPolicy is not enforced** by minikube's default CNI. The policies
   exist in the chart but are off here, so this is a design statement, not a
   demonstrated control.
3. **The OpenSearch security plugin is disabled.** Acceptable only because the
   service is ClusterIP and never routable from outside; production needs TLS and
   authentication on it.
4. **The 2-core profile has almost no headroom.** Limits sit close to requests,
   so a genuine traffic spike gets a pod OOM-killed rather than degrading. On a
   box this size that is the better failure mode, but it is a choice, not a
   default.
5. **`--memory=3000mb` does not bound what the scheduler sees.** minikube's
   docker driver caps the container's cgroup, but the kubelet inside reads the
   host's `/proc/meminfo` and advertises ~3.9 GiB allocatable. Keeping the
   workload's requests well under the cap is what stops that mismatch becoming an
   OOM kill.
6. **Single node, RWO media volume.** Fine here; a multi-node cluster needs RWX
   (EFS, Filestore, NFS) for `magento-media`.

---

## 14. Acceptance criteria summary

| Area | Criterion | Status |
|---|---|---|
| Public HTTPS | Storefront over public HTTPS, HTTP redirected | **PASS** — §4 |
| Magento works | Homepage, product page, admin panel all open | **PASS** — §3, §4 |
| Components healthy | Main pods Running/Completed, no ignored errors | **PASS** — §1 |
| Data persists | Product and app data survive pod re-creation | **PASS** — §6 |
| No secret leak | Repository free of credentials and live tokens | **PASS** — §8 |
| Repeatable | Deployment reproducible from automation and docs | **PASS** — §1 |
| Architecture understanding | Traffic path, dependencies, failure modes, minikube limits | §5, §9, §11, §13 |

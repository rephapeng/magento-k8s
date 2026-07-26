# Troubleshooting runbook

General first moves for any incident:

```bash
kubectl -n magento get pods -o wide          # who is unhealthy
kubectl -n magento describe pod <pod>         # events, probe failures, restarts
kubectl -n magento logs <pod> -c <container>  # app logs
kubectl -n magento logs <pod> -c <container> --previous   # after a crash/OOM
kubectl -n magento get events --sort-by=.lastTimestamp | tail -30
```

---

## Scenario 1 — HTTP 502 (Bad Gateway)

502 means a proxy in the chain could not get a valid response from its upstream.
Walk the path **outside-in**:

1. **Cloudflare / tunnel**: is `cloudflared` up and connected?
   ```bash
   kubectl -n magento logs deploy/cloudflared | grep -i "registered\|error"
   ```
   A 502 straight from Cloudflare with no request reaching the cluster points at the
   tunnel config (wrong service URL) or all `cloudflared` pods down.
2. **Ingress → Service**: does the Service have endpoints?
   ```bash
   kubectl -n magento get endpoints magento-web      # empty => no ready pods
   kubectl -n ingress-nginx logs deploy/ingress-nginx-controller | grep 502
   ```
3. **nginx → php-fpm**: nginx returns 502 when it cannot reach `127.0.0.1:9000`.
   ```bash
   kubectl -n magento logs <web-pod> -c nginx     # "connect() failed" / "upstream"
   kubectl -n magento logs <web-pod> -c php-fpm   # fatal errors, worker exits
   ```
   Distinguish causes:
   - **php-fpm not healthy / crashed** → php-fpm logs show fatals; pod restarts.
   - **wrong port** → nginx `fastcgi_pass` must be `127.0.0.1:9000` (same pod).
   - **timeout** → long request exceeds `fastcgi_read_timeout`; check slow queries
     or increase the timeout; look for `504` vs `502`.

---

## Scenario 2 — HTTP 503 (Service Unavailable)

Usually "no ready backend" or Magento maintenance mode.

1. **Empty endpoints / pods not Ready**:
   ```bash
   kubectl -n magento get pods            # READY 1/2? which container not ready
   kubectl -n magento describe pod <pod>  # readiness probe failing?
   kubectl -n magento get endpoints magento-web
   ```
2. **Service selector mismatch** — if endpoints are empty but pods are Running, the
   Service `selector` labels don't match the pod labels.
3. **Magento maintenance mode**:
   ```bash
   kubectl -n magento exec <web-pod> -c php-fpm -- ls -la /var/www/html/var/.maintenance.flag
   kubectl -n magento exec <web-pod> -c php-fpm -- php bin/magento maintenance:status
   ```
4. **Dependency down** — Magento returns 503 when the DB or search engine is
   unreachable. Check scenarios 4 and 5.

---

## Scenario 3 — Pod OOMKilled

1. **Confirm it was OOM**:
   ```bash
   kubectl -n magento describe pod <pod> | grep -A3 "Last State"
   # Reason: OOMKilled, Exit Code: 137
   kubectl -n magento logs <pod> -c php-fpm --previous
   ```
2. **request vs limit** — the container was killed for exceeding its **memory limit**
   (or the node was under pressure). Compare against actual usage:
   ```bash
   kubectl -n magento top pods
   ```
3. **PHP-FPM worker math** — total memory ≈ `pm.max_children × per-worker (~80–100MB)`.
   With `pm.max_children=16` that is ~1.3–1.6GB; the container limit is `2Gi`. If you
   raise `max_children`, raise the memory limit accordingly or you will OOM under
   load. Reduce `max_children` on smaller nodes.

---

## Scenario 4 — Database pod deleted

Data survives because it lives on a PVC, not in the pod.

```bash
kubectl -n magento delete pod mariadb-0          # StatefulSet recreates it
kubectl -n magento get pvc                        # data-mariadb-0 still Bound
kubectl -n magento get pv                         # underlying volume intact
kubectl -n magento wait --for=condition=ready pod/mariadb-0 --timeout=180s
kubectl -n magento exec mariadb-0 -- \
  sh -c 'mariadb -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT COUNT(*) FROM catalog_product_entity" magento'
```

The recreated pod re-attaches the same `data-mariadb-0` PVC, so all rows are still
there. Storefront returns to normal once the pod is Ready (Magento reconnects
automatically).

---

## Scenario 5 — Search engine unhealthy

Magento degrades: catalog search and layered navigation break; indexing fails.

```bash
# Cluster health (green/yellow ok on single node, red = problem)
kubectl -n magento exec statefulset/opensearch -- curl -s localhost:9200/_cluster/health?pretty
# Or from another pod against the service:
kubectl -n magento exec deploy/magento-cron -c cron -- \
  curl -s http://opensearch:9200/_cluster/health?pretty

kubectl -n magento logs statefulset/opensearch | tail -50   # bootstrap / heap errors
```

Common causes:
- `vm.max_map_count` too low → handled by the sysctl init container here.
- Heap too small → tune `OPENSEARCH_JAVA_OPTS`.
- Disk watermark / PVC full → `red` status, read-only indices.

Impact & fix: with OpenSearch down, product search returns nothing and reindex
fails. After restoring health, reindex:
```bash
kubectl -n magento exec deploy/magento-cron -c cron -- php bin/magento indexer:reindex catalogsearch_fulltext
```

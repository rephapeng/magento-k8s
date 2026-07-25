# From Minikube/OrbStack to production

This local setup is deliberately simple. Below is what changes on managed
Kubernetes (EKS/GKE/AKS), and the reasoning.

## Trade-offs: local vs production

| Concern | Here (local) | Production |
|---|---|---|
| Cluster | Single node (OrbStack k3s / Minikube) | Multi-node, multi-AZ, autoscaled node groups |
| Storage | `local-path` / hostpath, RWO | EBS/PD (DB), **EFS/Filestore RWX** (media), snapshots |
| Media volume | RWO PVC (works because 1 node) | **RWX** required — many pods on many nodes share it |
| Database | In-cluster MariaDB StatefulSet | **Managed** RDS/Cloud SQL/Aurora (HA, backups, PITR) |
| Search | Single-node OpenSearch, security off | Managed OpenSearch / 3-node cluster, TLS + auth on |
| Redis | Single pod | ElastiCache/Memorystore, or Redis with replicas |
| TLS | Terminated at Cloudflare edge | Same, or cert-manager + real LB; mTLS internally |
| Secrets | k8s Secret from `.env` | External Secrets Operator + Vault/ASM/GSM, KMS-encrypted |
| Ingress exposure | Cloudflare Tunnel (no public IP) | Cloud LB + WAF, or keep Tunnel for zero-trust |
| Network isolation | NetworkPolicy documented, not enforced | **Enforced** NetworkPolicy (Calico/Cilium) |
| Images | Built locally | Registry (ECR/GCR) + scanning + signing, pinned digests |
| Observability | `kubectl logs/top` | Prometheus+Grafana, Loki, alerting, tracing |

## Scaling the web tier to N replicas (requirement 3.5)

`kubectl -n magento scale deployment magento-web --replicas=2` is safe here
**because the web tier is stateless**. The prerequisites, and how each is met:

| Concern | Requirement | How it's satisfied |
|---|---|---|
| **Session storage** | Shared across pods | Redis (db 2) — not local files |
| **Cache backend** | Shared + invalidation consistent | Redis default cache (db 0) |
| **Full page cache** | Shared | Redis FPC (db 1); Varnish in production |
| **Shared media** | All pods read/write same files | Shared media PVC (RWX in prod) |
| **Static content** | Identical on every pod | Baked into the image at build (versioned) |
| **Cron / queue consumers** | Run **once**, not per web pod | Separate single-replica `magento-cron` Deployment |
| **Locking** | Correct across pods | `lock.provider = db` (not file locks) |
| **Load balancing / readiness** | Only Ready pods get traffic | Service + readiness probes; PDB during disruptions |

Also enable the **HPA** (`hpa.enabled=true`, needs metrics-server) and the **PDB**
(on by default) so scaling reacts to load and rollouts keep a pod serving.

## Backup & restore

- **Database**: `scripts/backup.sh` runs `mariadb-dump --single-transaction` (consistent,
  non-locking) and gzips it. Production: automated RDS snapshots + binlog PITR, tested
  restores, off-site copies.
- **Media**: tarred from the PVC. Production: EFS/Filestore backup or object storage
  (S3) as the media backend + lifecycle policies.
- **Restore**: `scripts/restore.sh backups/<ts>` reloads the dump, untars media, then
  flushes cache and reindexes.

## Security hardening (requirement 3.6 + bonus)

- Dedicated non-root DB user for Magento (`magento`), root only for admin tasks.
- Data-tier Services are `ClusterIP` (headless) — never internet-reachable.
- Secrets never in Git: injected from `.env` at deploy; marketplace keys (when
  used at all — the default build source is the keyless Mage-OS mirror) via a
  BuildKit secret; tunnel token as a Secret.
- Containers run as non-root (uid 1000 app, 101 nginx, 65532 cloudflared).
- Admin panel on a **non-default path** (`backend/frontName`). Further restrict in
  production with: IP allow-list at Cloudflare Access, 2FA, and a separate admin
  hostname.
- **NetworkPolicy** (in `templates/networkpolicy.yaml`, `networkPolicy.enabled`):
  default-deny ingress, only ingress-nginx → web:8080, only web/cron/install →
  data tier. Off locally because k3s/OrbStack's flannel doesn't enforce policies;
  **on** in production with Calico/Cilium.

## Observability roadmap

Local demo uses `kubectl get/describe/logs/top` + cloudflared/php-fpm/nginx logs.
Production:
- **Metrics**: Prometheus + `kube-state-metrics` + node-exporter; php-fpm exporter,
  MySQL exporter, OpenSearch exporter. Dashboards in Grafana.
- **Logs**: Loki (or CloudWatch/ELK) with promtail; structured Magento logs.
- **Tracing/APM**: New Relic / Datadog for Magento request traces + DB slow queries.
- **Alerting**: on pod restarts, OOMKills, 5xx rate, DB connections, OpenSearch red,
  queue backlog, cron lag.

## Deployment strategy

Web tier uses `RollingUpdate` with `maxUnavailable: 0` for zero-downtime. `setup:upgrade`
runs as an idempotent Job hook. For schema-breaking releases, use maintenance windows
or blue/green. Production CI/CD: build → scan → push (digest) → `helm upgrade` with
automated smoke tests and rollback on failure.

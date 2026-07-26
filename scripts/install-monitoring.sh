#!/usr/bin/env bash
# Ships cluster metrics, events and pod logs to Grafana Cloud via Grafana Alloy.
#
# Optional: the deployment is fully functional without it. See the README for
# where to get the five GRAFANA_* values, all of which live in .env and none of
# which are committed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
[ -f .env ] || { echo "ERROR: .env missing (cp .env.example .env)"; exit 1; }
set -a; . ./.env; set +a

for v in GRAFANA_CLOUD_TOKEN GRAFANA_PROM_URL GRAFANA_PROM_USER \
         GRAFANA_LOKI_URL GRAFANA_LOKI_USER; do
  [ -n "${!v:-}" ] || { echo "ERROR: $v is empty in .env — see README 'Monitoring'"; exit 1; }
done
: "${GRAFANA_CLUSTER_NAME:=magento-minikube}"
export GRAFANA_CLUSTER_NAME

echo "==> Cluster name: ${GRAFANA_CLUSTER_NAME}"
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# envsubst rather than --set: the token contains characters helm's --set parser
# treats as separators, and this keeps it out of the process list.
envsubst < monitoring/k8s-monitoring-values.yaml > /tmp/k8s-monitoring-rendered.yaml
trap 'rm -f /tmp/k8s-monitoring-rendered.yaml' EXIT

# --atomic: on a small node this is the install most likely to exhaust memory,
# and a half-applied collector stack is worse than none.
helm upgrade --install --atomic --timeout 600s \
  grafana-k8s-monitoring grafana/k8s-monitoring \
  --version "^4" --namespace monitoring --create-namespace \
  --values /tmp/k8s-monitoring-rendered.yaml

echo
echo "==> Deployed. Check that data is flowing:"
echo "   kubectl -n monitoring get pods"
echo "   kubectl -n monitoring logs deploy/grafana-k8s-monitoring-alloy-metrics -c alloy | grep -i error"
echo "   kubectl top pods -A          # confirm the collectors are not crowding the workload"

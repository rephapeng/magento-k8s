#!/usr/bin/env bash
# Tears down the deployment. By default keeps PVCs (data). Pass --purge to also
# delete PVCs and the namespace.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
[ -f .env ] && { set -a; . ./.env; set +a; }
: "${NAMESPACE:=magento}"; : "${RELEASE:=magento}"

echo "==> helm uninstall $RELEASE"
helm uninstall "$RELEASE" -n "$NAMESPACE" || true

if [ "${1:-}" = "--purge" ]; then
  echo "==> Deleting PVCs (DATA LOSS) + namespace"
  kubectl -n "$NAMESPACE" delete pvc --all --ignore-not-found
  kubectl delete ns "$NAMESPACE" --ignore-not-found
else
  echo "==> PVCs kept. Re-deploy reuses existing data. Use --purge to delete everything."
  kubectl -n "$NAMESPACE" get pvc || true
fi

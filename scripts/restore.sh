#!/usr/bin/env bash
# Restores DB + media from a backup directory: ./scripts/restore.sh backups/<ts>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
[ -f .env ] && { set -a; . ./.env; set +a; }
: "${NAMESPACE:=magento}"
SRC="${1:-}"
[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "Usage: $0 backups/<timestamp>"; exit 1; }

echo "==> Restoring database from ${SRC}/magento-db.sql.gz"
gunzip -c "${SRC}/magento-db.sql.gz" | \
  kubectl -n "$NAMESPACE" exec -i statefulset/mariadb -- \
  sh -c 'mariadb -u root -p"$MYSQL_ROOT_PASSWORD" magento'

echo "==> Restoring media from ${SRC}/magento-media.tar.gz"
POD="$(kubectl -n "$NAMESPACE" get pod -l component=web -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NAMESPACE" exec -i "$POD" -c php-fpm -- \
  tar xzf - -C /var/www/html/pub < "${SRC}/magento-media.tar.gz"

echo "==> Flushing cache + reindexing"
kubectl -n "$NAMESPACE" exec deploy/magento-cron -c cron -- php /var/www/html/bin/magento cache:flush || true
kubectl -n "$NAMESPACE" exec deploy/magento-cron -c cron -- php /var/www/html/bin/magento indexer:reindex || true
echo "==> Restore complete."

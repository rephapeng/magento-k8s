#!/usr/bin/env bash
# Backs up the Magento database (mysqldump) and media files to ./backups/<ts>/.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
[ -f .env ] && { set -a; . ./.env; set +a; }
: "${NAMESPACE:=magento}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="backups/${TS}"; mkdir -p "$OUT"

echo "==> Dumping database -> ${OUT}/magento-db.sql.gz"
kubectl -n "$NAMESPACE" exec statefulset/mariadb -- \
  sh -c 'mariadb-dump --single-transaction --quick --routines \
         -u root -p"$MYSQL_ROOT_PASSWORD" magento' \
  | gzip > "${OUT}/magento-db.sql.gz"

echo "==> Archiving media -> ${OUT}/magento-media.tar.gz"
POD="$(kubectl -n "$NAMESPACE" get pod -l component=web -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NAMESPACE" exec "$POD" -c php-fpm -- \
  tar czf - -C /var/www/html/pub media 2>/dev/null > "${OUT}/magento-media.tar.gz"

echo "==> Backup complete:"
ls -lh "$OUT"

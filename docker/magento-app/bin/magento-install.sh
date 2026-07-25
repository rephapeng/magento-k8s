#!/bin/bash
# Idempotent Magento installer/upgrader run by the post-install/upgrade Job.
set -euo pipefail

: "${MAGENTO_INSTALL_DATE:=Wed, 01 Jan 2025 00:00:00 +0000}"
export MAGENTO_INSTALL_DATE
cd /var/www/html

echo "[install] waiting for MariaDB at ${DB_HOST}:3306 ..."
until mariadb-admin ping -h "$DB_HOST" -u root -p"$DB_ROOT_PASSWORD" --silent 2>/dev/null; do
  sleep 3
done

echo "[install] waiting for OpenSearch at ${OPENSEARCH_HOST}:${OPENSEARCH_PORT} ..."
until curl -sf "http://${OPENSEARCH_HOST}:${OPENSEARCH_PORT}/_cluster/health" >/dev/null 2>&1; do
  sleep 3
done

INSTALLED=$(mariadb -h "$DB_HOST" -u root -p"$DB_ROOT_PASSWORD" -N -B \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='setup_module';" 2>/dev/null || echo 0)

if [ "${INSTALLED:-0}" -ge 1 ] && [ "${FORCE_REINSTALL:-false}" != "true" ]; then
  echo "[install] Magento already installed -> running setup:upgrade"
  envsubst < /usr/local/share/env.php.template > /var/www/html/app/etc/env.php
  php bin/magento setup:upgrade --keep-generated --no-interaction
else
  echo "[install] fresh install of Magento"
  # setup:install refuses a --base-url-secure that is not https, so on a
  # plain-HTTP local run the secure URL is simply left unset.
  URL_ARGS=(--base-url="${MAGENTO_BASE_URL}")
  if [ "${MAGENTO_USE_SECURE}" = "1" ]; then
    URL_ARGS+=(--base-url-secure="${MAGENTO_BASE_URL}" --use-secure=1 --use-secure-admin=1)
  else
    URL_ARGS+=(--use-secure=0 --use-secure-admin=0)
  fi

  php bin/magento setup:install \
    "${URL_ARGS[@]}" \
    --db-host="${DB_HOST}" --db-name="${DB_NAME}" \
    --db-user="${DB_USER}" --db-password="${DB_PASSWORD}" \
    --search-engine=opensearch \
    --opensearch-host="${OPENSEARCH_HOST}" --opensearch-port="${OPENSEARCH_PORT}" \
    --opensearch-index-prefix=magento2 --opensearch-enable-auth=0 \
    --admin-firstname="${MAGENTO_ADMIN_FIRSTNAME}" --admin-lastname="${MAGENTO_ADMIN_LASTNAME}" \
    --admin-email="${MAGENTO_ADMIN_EMAIL}" \
    --admin-user="${MAGENTO_ADMIN_USER}" --admin-password="${MAGENTO_ADMIN_PASSWORD}" \
    --language="${MAGENTO_LANGUAGE}" --currency="${MAGENTO_CURRENCY}" --timezone="${MAGENTO_TIMEZONE}" \
    --backend-frontname="${MAGENTO_ADMIN_PATH}" \
    --key="${MAGENTO_CRYPT_KEY}" \
    --session-save=redis --session-save-redis-host="${REDIS_HOST}" \
    --session-save-redis-port="${REDIS_PORT}" --session-save-redis-db=2 \
    --cache-backend=redis --cache-backend-redis-server="${REDIS_HOST}" \
    --cache-backend-redis-port="${REDIS_PORT}" --cache-backend-redis-db=0 \
    --page-cache=redis --page-cache-redis-server="${REDIS_HOST}" \
    --page-cache-redis-port="${REDIS_PORT}" --page-cache-redis-db=1 \
    --lock-provider=db \
    --use-rewrites=1 \
    --no-interaction

  php bin/magento config:set web/unsecure/base_url "${MAGENTO_BASE_URL}"
  if [ "${MAGENTO_USE_SECURE}" = "1" ]; then
    # Behind Cloudflare Tunnel + ingress, trust the forwarded HTTPS scheme.
    php bin/magento config:set web/secure/base_url "${MAGENTO_BASE_URL}"
    php bin/magento config:set web/secure/offloader_header X-Forwarded-Proto
    php bin/magento config:set web/secure/use_in_frontend 1
    php bin/magento config:set web/secure/use_in_adminhtml 1
  else
    # Plain-HTTP local run: nothing terminates TLS, so forcing https would
    # redirect every request into a dead end.
    php bin/magento config:set web/secure/use_in_frontend 0
    php bin/magento config:set web/secure/use_in_adminhtml 0
  fi

  echo "[install] seeding one demo product"
  php /usr/local/share/seed-product.php || echo "[install] seed skipped"
fi

echo "[install] reindex + cache flush"
php bin/magento indexer:reindex || true
php bin/magento cache:flush || true

# --- Re-sync the recorded config hash --------------------------------------
# setup:install rewrites app/etc/config.php inside THIS pod — it appends a
# `system` section — and records that file's hash in the database. This pod is a
# Job: it exits, and every long-lived pod still has the image's original
# config.php, whose hash no longer matches. They would all answer 500 with "The
# configuration file has changed".
#
# So: put the shipped file back, and re-sync the recorded hash to it.
#
# The cache flush in between is not optional. Magento caches the deployment
# config, and immediately after setup:install that cache still describes the
# mutated file — the importer compares against it, concludes nothing changed,
# prints "Nothing to import" and leaves the stale hash exactly where it was.
# Flushing first makes it re-read config.php from disk and actually rewrite the
# hash ("System config was processed").
#
# setup:upgrade rather than app:config:import for the same reason: import only
# touches the hash when it has content to import, and a pristine config.php has
# none.
if [ -f /usr/local/share/config.php.dist ]; then
  echo "[install] re-syncing config hash to the shipped config.php"
  cp /usr/local/share/config.php.dist /var/www/html/app/etc/config.php
  php bin/magento cache:flush >/dev/null 2>&1 || true
  php bin/magento setup:upgrade --keep-generated --no-interaction
  php bin/magento cache:flush || true
fi

echo "[install] done."

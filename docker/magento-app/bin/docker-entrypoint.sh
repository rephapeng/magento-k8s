#!/bin/bash
# Renders app/etc/env.php from the environment (ConfigMap + Secret), then hands
# off to the requested process. Keeping config out of the image makes the web
# pods stateless and horizontally scalable.
set -euo pipefail

: "${MAGENTO_INSTALL_DATE:=Wed, 01 Jan 2025 00:00:00 +0000}"
export MAGENTO_INSTALL_DATE

render_env() {
  local target=/var/www/html/app/etc/env.php
  if [ -w /var/www/html/app/etc ]; then
    envsubst < /usr/local/share/env.php.template > "$target"
    echo "[entrypoint] rendered $target for domain ${MAGENTO_DOMAIN:-?}"
  else
    echo "[entrypoint] app/etc not writable, skipping env.php render"
  fi
}

case "${1:-}" in
  php-fpm)
    render_env
    exec "$@"
    ;;
  cron)
    render_env
    echo "[entrypoint] starting Magento cron loop"
    # Single dedicated cron runner. `cron:run` is idempotent per schedule tick.
    while true; do
      php /var/www/html/bin/magento cron:run 2>&1 | grep -v '^$' || true
      sleep 60
    done
    ;;
  *)
    exec "$@"
    ;;
esac

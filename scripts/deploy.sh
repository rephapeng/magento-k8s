#!/usr/bin/env bash
# One-command deploy: renders secrets from .env and installs/upgrades the chart.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
[ -f .env ] || { echo "ERROR: .env missing (cp .env.example .env)"; exit 1; }
set -a; . ./.env; set +a
: "${NAMESPACE:=magento}"; : "${RELEASE:=magento}"; : "${CLUSTER_PROFILE:=orbstack}"

# Fail fast if any required secret/value is missing.
for v in MAGENTO_DOMAIN MAGENTO_ADMIN_PATH DB_PASSWORD DB_ROOT_PASSWORD \
         MAGENTO_ADMIN_PASSWORD MAGENTO_CRYPT_KEY; do
  [ -n "${!v:-}" ] || { echo "ERROR: $v is empty in .env"; exit 1; }
done

# Public entrypoint. With a tunnel token the store is published over HTTPS
# through Cloudflare; without one we fall back to a local-only run that hits the
# ingress directly over plain HTTP (useful for a laptop / *.local hostname).
# Override either default by setting PUBLIC_SCHEME in .env.
if [ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
  CLOUDFLARED_ENABLED=true
  : "${PUBLIC_SCHEME:=https}"
else
  CLOUDFLARED_ENABLED=false
  : "${PUBLIC_SCHEME:=http}"
  echo "==> No CLOUDFLARE_TUNNEL_TOKEN in .env -> local-only mode"
  echo "    cloudflared disabled, base URL ${PUBLIC_SCHEME}://${MAGENTO_DOMAIN}/"
fi

OVERLAY="charts/magento/values-${CLUSTER_PROFILE}.yaml"
[ -f "$OVERLAY" ] || { echo "ERROR: unknown CLUSTER_PROFILE '$CLUSTER_PROFILE'"; exit 1; }

# Warn if the custom images are not present locally.
if ! docker image inspect "magento-app:2.4.7-p3" >/dev/null 2>&1; then
  echo "WARNING: magento-app:2.4.7-p3 not found locally. Run scripts/build-images.sh first."
fi

echo "==> Namespace: $NAMESPACE | Release: $RELEASE | Profile: $CLUSTER_PROFILE"
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"

echo "==> helm upgrade --install"
helm upgrade --install "$RELEASE" charts/magento \
  --namespace "$NAMESPACE" \
  -f charts/magento/values.yaml -f "$OVERLAY" \
  --set-string domain="$MAGENTO_DOMAIN" \
  --set-string publicScheme="$PUBLIC_SCHEME" \
  --set cloudflared.enabled="$CLOUDFLARED_ENABLED" \
  --set-string adminPath="$MAGENTO_ADMIN_PATH" \
  --set-string magento.adminUser="${MAGENTO_ADMIN_USER:-admin}" \
  --set-string magento.adminEmail="${MAGENTO_ADMIN_EMAIL:-admin@example.com}" \
  --set-string secrets.dbPassword="$DB_PASSWORD" \
  --set-string secrets.dbRootPassword="$DB_ROOT_PASSWORD" \
  --set-string secrets.adminPassword="$MAGENTO_ADMIN_PASSWORD" \
  --set-string secrets.cryptKey="$MAGENTO_CRYPT_KEY" \
  --set-string secrets.cloudflareTunnelToken="$CLOUDFLARE_TUNNEL_TOKEN" \
  --set-string secrets.marketplacePublicKey="${MAGENTO_MARKETPLACE_PUBLIC_KEY:-}" \
  --set-string secrets.marketplacePrivateKey="${MAGENTO_MARKETPLACE_PRIVATE_KEY:-}" \
  --timeout 25m

cat <<EOF

==> Deployed. The post-install Job is installing Magento (first run ~5-10 min).
    Watch it:
      kubectl -n $NAMESPACE logs -f job -l component=install
      kubectl -n $NAMESPACE get pods -w
    Then verify:
      ./scripts/verify.sh

    Storefront : $PUBLIC_SCHEME://$MAGENTO_DOMAIN
    Admin      : $PUBLIC_SCHEME://$MAGENTO_DOMAIN/$MAGENTO_ADMIN_PATH
EOF

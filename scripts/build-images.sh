#!/usr/bin/env bash
# Builds the custom Magento app + nginx images.
#
# By default Magento is pulled from the Mage-OS public mirror, which serves the
# identical magento/* Open Source packages with NO authentication, so this repo
# builds end-to-end without an Adobe Marketplace account. If you do have keys,
# set MAGENTO_MARKETPLACE_* in .env and the build switches to the official
# repo.magento.com, passing the keys through a BuildKit secret so they never
# land in an image layer. Override the source explicitly with COMPOSER_REPO_URL.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
[ -f .env ] || { echo "ERROR: .env missing (cp .env.example .env)"; exit 1; }
set -a; . ./.env; set +a
: "${CLUSTER_PROFILE:=orbstack}"
APP_TAG="${APP_TAG:-magento-app:2.4.7-p3}"
NGINX_TAG="${NGINX_TAG:-magento-nginx:2.4.7-p3}"

BUILD_ARGS=()
SECRET_ARGS=()

if [ -n "${MAGENTO_MARKETPLACE_PUBLIC_KEY:-}" ] && [ -n "${MAGENTO_MARKETPLACE_PRIVATE_KEY:-}" ]; then
  REPO_URL="${COMPOSER_REPO_URL:-https://repo.magento.com/}"
  echo "==> Marketplace keys found -> using ${REPO_URL}"
  # Composer auth as a temporary file, removed on exit (never committed).
  AUTH_FILE="$(mktemp)"
  trap 'rm -f "$AUTH_FILE"' EXIT
  cat > "$AUTH_FILE" <<JSON
{"http-basic":{"repo.magento.com":{"username":"${MAGENTO_MARKETPLACE_PUBLIC_KEY}","password":"${MAGENTO_MARKETPLACE_PRIVATE_KEY}"}}}
JSON
  SECRET_ARGS=(--secret "id=composer_auth,src=$AUTH_FILE")
else
  REPO_URL="${COMPOSER_REPO_URL:-https://mirror.mage-os.org/}"
  echo "==> No Marketplace keys set -> using keyless mirror ${REPO_URL}"
  echo "    (identical magento/* Open Source packages; no Adobe account needed)"
fi
BUILD_ARGS=(--build-arg "COMPOSER_REPO_URL=$REPO_URL")

echo "==> Building ${APP_TAG} (this pulls + compiles Magento, ~10-15 min)"
DOCKER_BUILDKIT=1 docker build \
  "${BUILD_ARGS[@]}" ${SECRET_ARGS[@]+"${SECRET_ARGS[@]}"} \
  -t "$APP_TAG" docker/magento-app

echo "==> Building ${NGINX_TAG}"
docker build -t "$NGINX_TAG" docker/magento-nginx

if [ "$CLUSTER_PROFILE" = "minikube" ] && command -v minikube >/dev/null; then
  echo "==> Loading images into Minikube"
  minikube image load "$APP_TAG"
  minikube image load "$NGINX_TAG"
else
  echo "==> OrbStack shares the Docker image store with Kubernetes; no load needed."
fi
echo "==> Images ready: $APP_TAG , $NGINX_TAG"

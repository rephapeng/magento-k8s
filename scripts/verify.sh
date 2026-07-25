#!/usr/bin/env bash
# Verifies the core functions of the deployment (requirement 3.2 / demo step 3-9).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
[ -f .env ] && { set -a; . ./.env; set +a; }
: "${NAMESPACE:=magento}"
DOMAIN="${MAGENTO_DOMAIN:-magento.example.com}"
pass(){ printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail(){ printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

echo "== Workloads =="
kubectl -n "$NAMESPACE" get pods -o wide
echo; echo "== Services / Ingress / PVC =="
kubectl -n "$NAMESPACE" get svc,ingress,pvc

echo; echo "== Health checks =="

# Pods Ready
NOTREADY=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | grep -Ev 'Running|Completed' | wc -l | tr -d ' ')
[ "$NOTREADY" = "0" ] && pass "all pods Running/Completed" || fail "$NOTREADY pod(s) not ready"

# MariaDB reachable + dedicated user
if kubectl -n "$NAMESPACE" exec statefulset/mariadb -- \
   sh -c 'mariadb -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1" magento' >/dev/null 2>&1; then
  pass "MariaDB reachable as dedicated app user"
else fail "MariaDB app-user connectivity"; fi

# OpenSearch cluster health
OS=$(kubectl -n "$NAMESPACE" exec statefulset/opensearch -- \
     curl -s http://localhost:9200/_cluster/health 2>/dev/null | grep -o '"status":"[a-z]*"')
echo "$OS" | grep -qE 'green|yellow' && pass "OpenSearch healthy ($OS)" || fail "OpenSearch health ($OS)"

# Magento product count in DB (proves DB + seed)
PCOUNT=$(kubectl -n "$NAMESPACE" exec statefulset/mariadb -- \
  sh -c 'mariadb -u root -p"$MYSQL_ROOT_PASSWORD" -N -B -e "SELECT COUNT(*) FROM catalog_product_entity" magento' 2>/dev/null)
[ "${PCOUNT:-0}" -ge 1 ] 2>/dev/null && pass "catalog has ${PCOUNT} product(s)" || fail "no products found"

# End-to-end through the ingress, from inside the cluster. Done with a throwaway
# curl pod so it works no matter how (or whether) the host resolves $DOMAIN.
echo; echo "== In-cluster HTTP (via ingress) =="
ING="http://ingress-nginx-controller.ingress-nginx.svc.cluster.local"
ADMIN="${MAGENTO_ADMIN_PATH:-admin}"
CODES=$(kubectl -n "$NAMESPACE" run curl-check --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.10.1 --command -- sh -c \
  "for p in /health / /demo-product.html /${ADMIN}; do \
     printf '%s=' \"\$p\"; \
     curl -s -o /dev/null -w '%{http_code}\n' --max-time 60 -H 'Host: ${DOMAIN}' \"${ING}\$p\"; \
   done" 2>/dev/null)
echo "$CODES" | sed 's/^/  /'
# The storefront is the one that must be 200; the admin answers 302 (redirect to
# the login form with its secret key), which is the correct, secure behaviour.
echo "$CODES" | grep -q '^/=200'                 && pass "storefront returns 200" || fail "storefront not 200"
echo "$CODES" | grep -q '^/demo-product.html=200' && pass "product page returns 200" || fail "product page not 200"
echo "$CODES" | grep -qE "^/${ADMIN}=(200|302)"   && pass "admin reachable on non-default path" || fail "admin path not reachable"

# Public endpoint. Only meaningful once the Cloudflare tunnel and DNS are live;
# a local-only deploy (no tunnel token) has no public name to test, so we say so
# rather than reporting a misleading failure.
echo; echo "== Public endpoint =="
if [ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN}/" --max-time 15 2>/dev/null || echo "000")
  [ "$CODE" = "200" ] && pass "storefront https://${DOMAIN} -> 200" || fail "public storefront -> HTTP $CODE (check tunnel/DNS)"
else
  echo "  SKIP - local-only deploy (no CLOUDFLARE_TUNNEL_TOKEN); storefront is"
  echo "         http://${DOMAIN}/ via the ingress, verified in-cluster above."
fi

echo; echo "== Resource usage =="
kubectl -n "$NAMESPACE" top pods 2>/dev/null || echo "  (metrics-server not installed)"

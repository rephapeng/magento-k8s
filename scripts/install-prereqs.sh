#!/usr/bin/env bash
# Installs cluster prerequisites: an ingress-nginx controller and (optionally)
# metrics-server. Idempotent. Works on both OrbStack (k3s) and Minikube.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
[ -f .env ] && { set -a; . ./.env; set +a; }
: "${CLUSTER_PROFILE:=orbstack}"

echo "==> Cluster profile: ${CLUSTER_PROFILE}"
echo "==> Current context: $(kubectl config current-context)"

# ---- Ingress controller ----
if kubectl get ns ingress-nginx >/dev/null 2>&1 && \
   kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1; then
  echo "==> ingress-nginx already present, skipping"
elif [ "$CLUSTER_PROFILE" = "minikube" ] && command -v minikube >/dev/null; then
  echo "==> Enabling Minikube ingress addon"
  minikube addons enable ingress
else
  echo "==> Installing ingress-nginx via Helm"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --set controller.service.type=ClusterIP \
    --wait --timeout 5m
fi

# ---- Trust the proxy's forwarded scheme ----
# The tunnel terminates TLS at Cloudflare's edge and forwards plain HTTP to this
# controller with X-Forwarded-Proto: https. By default ingress-nginx does NOT
# trust that header — it overwrites it with the scheme of the connection it
# received, i.e. "http". Magento then believes an HTTPS request was insecure,
# redirects to its https base URL, receives the same "http" again, and loops
# until the browser gives up.
#
# This is safe here because the controller is only reachable from inside the
# cluster: the sole path in is the tunnel, which is itself the trusted proxy.
# Do NOT enable it on a controller that is directly exposed to the internet
# without also restricting proxy-real-ip-cidr — any client could then forge its
# own scheme and address.
echo "==> Trusting forwarded headers on ingress-nginx"
if kubectl -n ingress-nginx get configmap ingress-nginx-controller >/dev/null 2>&1; then
  kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type merge \
    -p '{"data":{"use-forwarded-headers":"true"}}'
  kubectl -n ingress-nginx rollout restart deploy/ingress-nginx-controller
  kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
else
  echo "    (no ingress-nginx-controller ConfigMap found; skipping)"
fi

# ---- metrics-server (needed for `kubectl top` and HPA) ----
if kubectl get deploy metrics-server -n kube-system >/dev/null 2>&1; then
  echo "==> metrics-server already present"
elif [ "$CLUSTER_PROFILE" = "minikube" ] && command -v minikube >/dev/null; then
  minikube addons enable metrics-server || true
else
  echo "==> Installing metrics-server"
  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
  helm repo update >/dev/null
  # --kubelet-insecure-tls is required on local single-node clusters.
  helm upgrade --install metrics-server metrics-server/metrics-server \
    --namespace kube-system \
    --set args="{--kubelet-insecure-tls}" \
    --wait --timeout 3m || echo "metrics-server optional; continuing"
fi

echo "==> Prerequisites ready."

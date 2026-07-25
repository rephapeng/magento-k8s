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

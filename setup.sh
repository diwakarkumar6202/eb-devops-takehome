#!/usr/bin/env bash
# One-command setup: kind cluster + ingress-nginx + image + Helm release.
# Safe to run repeatedly (idempotent).
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER_NAME="demo"
NAMESPACE="demo"
RELEASE="demo"
IMAGE_REPO="demo-service"
IMAGE_TAG="${IMAGE_TAG:-0.1.0}"
INGRESS_NGINX_REF="controller-v1.11.3"   # pinned, not "main"
INGRESS_HOST="demo.local"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

log "Checking prerequisites"
for bin in docker kind kubectl helm curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is not installed"; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "ERROR: Docker daemon is not reachable"; exit 1; }

log "Kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "Cluster already exists - reusing it"
  # Make sure our kubeconfig has the context (e.g. after a kubeconfig reset)
  kind export kubeconfig --name "${CLUSTER_NAME}" >/dev/null
else
  KIND_CFG="$(mktemp)"
  trap 'rm -f "$KIND_CFG"' EXIT
  cat > "$KIND_CFG" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
EOF
  kind create cluster --name "${CLUSTER_NAME}" --config "$KIND_CFG" --wait 120s
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

log "Installing ingress-nginx (${INGRESS_NGINX_REF})"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_REF}/deploy/static/provider/kind/deploy.yaml"
kubectl -n ingress-nginx wait --for=condition=complete job --all --timeout=600s
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=600s

log "Building image ${IMAGE_REPO}:${IMAGE_TAG}"
docker build -t "${IMAGE_REPO}:${IMAGE_TAG}" service/

log "Loading image into kind"
kind load docker-image "${IMAGE_REPO}:${IMAGE_TAG}" --name "${CLUSTER_NAME}"

log "Installing Helm release '${RELEASE}' into namespace '${NAMESPACE}'"
# Retry: the ingress-nginx admission webhook can need a few seconds after rollout
for attempt in 1 2 3 4 5; do
  if helm upgrade --install "${RELEASE}" ./chart \
        --namespace "${NAMESPACE}" --create-namespace \
        --set image.repository="${IMAGE_REPO}" \
        --set-string image.tag="${IMAGE_TAG}" \
        --wait --timeout 3m; then
    break
  fi
  [ "$attempt" -eq 5 ] && { echo "ERROR: helm install failed"; exit 1; }
  echo "helm failed (attempt ${attempt}), retrying in 10s..."; sleep 10
done

log "Smoke test through the Ingress"
for i in $(seq 1 30); do
  if out="$(curl -fsS -H "Host: ${INGRESS_HOST}" http://localhost/ 2>/dev/null)"; then
    echo "OK: ${out}"; break
  fi
  [ "$i" -eq 30 ] && echo "WARN: ingress not answering yet - check: kubectl -n ${NAMESPACE} get pods,ingress"
  sleep 2
done

cat <<EOF

Done. Verify with:
  kubectl -n ${NAMESPACE} get pods,svc,ingress,configmap
  curl -H "Host: ${INGRESS_HOST}" http://localhost/
  curl -H "Host: ${INGRESS_HOST}" http://localhost/healthz
EOF

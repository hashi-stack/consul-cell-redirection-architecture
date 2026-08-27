#!/usr/bin/env bash
# up.sh — two-cluster ext-proc failover demo
#
# Creates:
#   kind-dc1  — primary cluster: api-gateway + all services + ext-proc pipeline
#   kind-dc2  — failover cluster: all backend services (no api-gateway)
#
# Consul servers run as Docker containers on the shared "kind" network:
#   DC1: 172.18.5.2:8500 (gRPC :8502)
#   DC2: 172.18.5.3:8501 (gRPC :8503)
#
# Cluster peering is established from DC1 → DC2 so that every backend
# service (service-a…service-d2, route-decider, ext-proc-grpc) has a
# failover target in DC2.  api-gateway is NOT part of the failover policy.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSUL_NS="consul"
BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:-e95b599e-166e-7d80-08ad-aee76e7ddf19}"

# Consul HTTP API addresses for the two servers.
CONSUL_DC1_ADDR="${CONSUL_DC1_ADDR:-http://127.0.0.1:8500}"
CONSUL_DC2_ADDR="${CONSUL_DC2_ADDR:-http://127.0.0.1:8501}"

# Hostname the kind nodes use to reach the Docker host.
# On macOS + Docker Desktop: host.docker.internal
CONSUL_EXTERNAL_HOST="${CONSUL_EXTERNAL_HOST:-host.docker.internal}"

# Fixed IPs for the two Consul server containers on the kind Docker network.
CONSUL_DC1_IP="172.18.5.2"
CONSUL_DC2_IP="172.18.5.3"

RENDER_DIR="${ROOT_DIR}/rendered-manifests"
mkdir -p "${RENDER_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

for cmd in kind kubectl helm docker consul; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' is not installed"
    exit 1
  fi
done

print_consul_debug() {
  local context="$1"
  echo ""
  echo "========================================"
  echo "Debug info for ${context}"
  echo "========================================"
  kubectl get all -n consul --context "${context}" || true
  kubectl get events -n consul --sort-by=.metadata.creationTimestamp --context "${context}" | tail -30 || true
  kubectl describe pods -n consul -l component=mesh-gateway --context "${context}" || true
}

wait_for_consul_components() {
  local context="$1"

  # If Consul was already installed and components are running, skip the wait.
  if helm status consul --kube-context "${context}" --namespace consul >/dev/null 2>&1; then
    local injector_ready
    injector_ready="$(kubectl --context "${context}" -n consul \
      get deployment consul-connect-injector \
      -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
    if [[ "${injector_ready:-0}" -ge 1 ]]; then
      echo "  Consul components already running in ${context}; skipping wait."
      return 0
    fi
  fi

  echo "  Waiting for connect-injector in ${context}..."
  kubectl wait --for=condition=available deployment/consul-connect-injector \
    -n consul --timeout=300s --context "${context}"

  echo "  Waiting for mesh-gateway in ${context}..."
  kubectl wait --for=condition=available deployment/consul-mesh-gateway \
    -n consul --timeout=300s --context "${context}"

  echo "  Waiting for mesh-gateway endpoints in ${context}..."
  local _mgw_i
  for _mgw_i in $(seq 1 60); do
    kubectl get endpoints consul-mesh-gateway -n consul --context "${context}" \
      -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q . && break
    echo "    Waiting for consul-mesh-gateway endpoints... (${_mgw_i}/60)"
    sleep 5
  done
  kubectl get endpoints consul-mesh-gateway -n consul --context "${context}" \
    -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q . || {
    echo "ERROR: consul-mesh-gateway never got an endpoint IP in ${context}"
    exit 1
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# [1] Create the shared "kind" Docker network
# ─────────────────────────────────────────────────────────────────────────────
echo "[1/12] Creating shared 'kind' Docker network..."
if docker network inspect kind >/dev/null 2>&1; then
  echo "  Network 'kind' already exists; reusing."
else
  docker network create kind \
    --driver=bridge \
    --subnet=172.18.0.0/16 \
    --gateway=172.18.0.1 \
    --ipv6 --subnet=fc00:f853:ccd:e793::/64 \
    --opt com.docker.network.bridge.enable_ip_masquerade=true \
    --opt com.docker.network.driver.mtu=65535
fi

# ─────────────────────────────────────────────────────────────────────────────
# [2] Start Consul server containers (DC1 + DC2)
# ─────────────────────────────────────────────────────────────────────────────
echo "[2/12] Starting Consul server containers (docker-compose)..."
docker compose -f "${ROOT_DIR}/docker-compose.yml" up -d

echo "  Waiting for DC1 Consul server to be ready..."
until curl -s "${CONSUL_DC1_ADDR}/v1/status/leader" 2>/dev/null | grep -q '"172.18.5.2:8300"'; do
  echo "    DC1 not yet ready..."
  sleep 5
done
echo "  DC1 ready."

echo "  Waiting for DC2 Consul server to be ready..."
until curl -s "${CONSUL_DC2_ADDR}/v1/status/leader" 2>/dev/null | grep -q '"172.18.5.3:8300"'; do
  echo "    DC2 not yet ready..."
  sleep 5
done
echo "  DC2 ready."

# ─────────────────────────────────────────────────────────────────────────────
# [3] Create kind clusters
# ─────────────────────────────────────────────────────────────────────────────
echo "[3/12] Creating kind clusters..."
export KIND_EXPERIMENTAL_DOCKER_NETWORK=kind

if kind get clusters | grep -qx "dc1"; then
  echo "  Cluster 'dc1' already exists; reusing."
else
  kind create cluster --name dc1 --config "${ROOT_DIR}/cluster-dc1.yaml"
fi

if kind get clusters | grep -qx "dc2"; then
  echo "  Cluster 'dc2' already exists; reusing."
else
  kind create cluster --name dc2 --config "${ROOT_DIR}/cluster-dc2.yaml"
fi

# Rewrite API server addresses to known localhost ports (avoids 0.0.0.0 kubeconfig issues).
kubectl config set-cluster kind-dc1 --server=https://127.0.0.1:6443 >/dev/null
kubectl config set-cluster kind-dc2 --server=https://127.0.0.1:6444 >/dev/null

echo "  Waiting for dc1 nodes..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s --context kind-dc1
echo "  Waiting for dc2 nodes..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s --context kind-dc2

# ─────────────────────────────────────────────────────────────────────────────
# [4] Bootstrap secrets in both clusters
# ─────────────────────────────────────────────────────────────────────────────
bootstrap_secrets() {
  local context="$1"
  echo "  Creating consul namespace + ACL bootstrap secret in ${context}..."
  kubectl --context "${context}" create namespace "${CONSUL_NS}" \
    --dry-run=client -o yaml | kubectl --context "${context}" apply -f -
  kubectl --context "${context}" -n "${CONSUL_NS}" create secret generic bootstrap-token \
    --from-literal=token="${BOOTSTRAP_TOKEN}" \
    --dry-run=client -o yaml | kubectl --context "${context}" apply -f -

  local LICENSE_FILE="${ROOT_DIR}/config/consul-enterprise-license.hclic"
  if [[ -f "${LICENSE_FILE}" ]]; then
    kubectl --context "${context}" -n "${CONSUL_NS}" create secret generic consul-enterprise-license \
      --from-file=license="${LICENSE_FILE}" \
      --dry-run=client -o yaml | kubectl --context "${context}" apply -f -
  fi
}

echo "[4/12] Bootstrapping secrets..."
bootstrap_secrets "kind-dc1"
bootstrap_secrets "kind-dc2"

# ─────────────────────────────────────────────────────────────────────────────
# [5] Install Consul via Helm into both clusters
# ─────────────────────────────────────────────────────────────────────────────
install_consul() {
  local cluster_name="$1"
  local datacenter="$2"
  local context="kind-${cluster_name}"
  local values_file="${ROOT_DIR}/values-ext-${datacenter}.yaml"
  local external_ip

  # Skip if Consul is already installed in this cluster.
  if helm status consul --kube-context "${context}" --namespace consul >/dev/null 2>&1; then
    echo "  Consul already installed in ${context}; skipping."
    return 0
  fi

  if [[ "${datacenter}" == "dc1" ]]; then
    external_ip="${CONSUL_DC1_IP}"
  else
    external_ip="${CONSUL_DC2_IP}"
  fi

  local KIND_API_IP
  KIND_API_IP="$(docker inspect "${cluster_name}-control-plane" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)"
  if [[ -z "${KIND_API_IP}" ]]; then
    echo "ERROR: could not find IP for ${cluster_name}-control-plane"
    exit 1
  fi

  echo "  Installing Consul ${datacenter} into ${context} (Consul server: ${external_ip})..."

  local helm_args=(
    --kube-context "${context}"
    --values "${values_file}"
    --set global.name=consul
    --set global.datacenter="${datacenter}"
    --set "externalServers.k8sAuthMethodHost=https://${KIND_API_IP}:6443"
    --create-namespace
    --namespace consul
    --version "2.0.3"
    "--set-string=externalServers.hosts[0]=${external_ip}"
  )

  helm repo add hashicorp https://helm.releases.hashicorp.com --force-update >/dev/null
  helm repo update >/dev/null

  # Render for reference
  helm template consul hashicorp/consul "${helm_args[@]}" \
    > "${RENDER_DIR}/consul-${datacenter}.yaml" 2>/dev/null || true

  if ! helm upgrade --install consul hashicorp/consul "${helm_args[@]}"; then
    echo "ERROR: Helm install failed for ${context}."
    print_consul_debug "${context}"
    exit 1
  fi
}

echo "[5/12] Installing Consul into dc1 and dc2..."
install_consul "dc1" "dc1"
install_consul "dc2" "dc2"

echo "[5b/12] Waiting for Consul components in dc1..."
wait_for_consul_components "kind-dc1"
echo "[5b/12] Waiting for Consul components in dc2..."
wait_for_consul_components "kind-dc2"

# ─────────────────────────────────────────────────────────────────────────────
# [6] Build + load local images into both clusters
# ─────────────────────────────────────────────────────────────────────────────
echo "[6/12] Building local images for route-decider + ext-proc-grpc..."
docker build -t local/route-decider:0.1 "${ROOT_DIR}/apps/route-decider"
docker build -t local/ext-proc-grpc:0.1 "${ROOT_DIR}/apps/ext-proc-grpc"

echo "  Loading images into dc1..."
kind load docker-image --name dc1 local/route-decider:0.1
kind load docker-image --name dc1 local/ext-proc-grpc:0.1

echo "  Loading images into dc2..."
kind load docker-image --name dc2 local/route-decider:0.1
kind load docker-image --name dc2 local/ext-proc-grpc:0.1

# ─────────────────────────────────────────────────────────────────────────────
# [7] Deploy manifests into DC1 (primary)
# ─────────────────────────────────────────────────────────────────────────────
echo "[7/12] Applying DC1 base manifests..."
kubectl --context kind-dc1 apply -f "${ROOT_DIR}/manifests/00-gateway.yaml"
kubectl --context kind-dc1 apply -f "${ROOT_DIR}/manifests/10-services.yaml"
kubectl --context kind-dc1 apply -f "${ROOT_DIR}/manifests/20-ext-components.yaml"
kubectl --context kind-dc1 apply -f "${ROOT_DIR}/manifests/40-routes.yaml"

# Restart local-image deployments to pick up freshly loaded layers.
kubectl --context kind-dc1 -n default rollout restart \
  deploy/route-decider deploy/ext-proc-grpc >/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# [8] Apply DC1 Consul config CRDs (ServiceDefaults, ServiceIntentions, etc.)
# ─────────────────────────────────────────────────────────────────────────────
echo "[8/12] Waiting for consul connect-injector webhook to be ready in dc1..."
for _ in {1..60}; do
  ep_ip="$(kubectl --context kind-dc1 -n "${CONSUL_NS}" \
    get endpoints consul-connect-injector \
    -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
  [[ -n "${ep_ip}" ]] && break
  sleep 5
done

echo "  Applying DC1 Consul config CRDs with retries..."
for attempt in {1..12}; do
  if kubectl --context kind-dc1 apply -f "${ROOT_DIR}/manifests/30-consul-config.yaml"; then
    break
  fi
  echo "  Attempt ${attempt}/12 failed; retrying in 5s..."
  sleep 5
  [[ "${attempt}" -eq 12 ]] && { echo "ERROR: consul CRD apply failed."; exit 1; }
done

# ─────────────────────────────────────────────────────────────────────────────
# [9] Deploy manifests into DC2 (failover)
# ─────────────────────────────────────────────────────────────────────────────
echo "[9/12] Applying DC2 backend manifests (no api-gateway)..."
kubectl --context kind-dc2 apply -f "${ROOT_DIR}/manifests/10-services-dc2.yaml"
kubectl --context kind-dc2 apply -f "${ROOT_DIR}/manifests/20-ext-components-dc2.yaml"

kubectl --context kind-dc2 -n default rollout restart \
  deploy/route-decider deploy/ext-proc-grpc >/dev/null || true

# DC2 connect-injector readiness is already guaranteed by step [5b].

# ─────────────────────────────────────────────────────────────────────────────
# [10] Establish cluster peering between DC1 and DC2
# ─────────────────────────────────────────────────────────────────────────────
echo "[10/12] Establishing cluster peering (DC1 → DC2)..."

echo "  Generating peering token from dc1..."
PEERING_TOKEN="$(docker exec consul-server-dc1 sh -c \
  "CONSUL_HTTP_TOKEN=${BOOTSTRAP_TOKEN} CONSUL_HTTP_ADDR=http://127.0.0.1:8500 \
   consul peering generate-token -name peer-dc2")"

if [[ -z "${PEERING_TOKEN}" ]]; then
  echo "ERROR: failed to generate peering token from dc1"
  exit 1
fi

echo "  Establishing peering from dc2 to dc1..."
docker exec consul-server-dc2 sh -c \
  "CONSUL_HTTP_TOKEN=${BOOTSTRAP_TOKEN} CONSUL_HTTP_ADDR=http://127.0.0.1:8500 \
   consul peering establish -name peer-dc1 -peering-token '${PEERING_TOKEN}'"

echo "  Peering state in dc1:"
docker exec consul-server-dc1 sh -c \
  "CONSUL_HTTP_TOKEN=${BOOTSTRAP_TOKEN} CONSUL_HTTP_ADDR=http://127.0.0.1:8500 \
   consul peering list"
echo "  Peering state in dc2:"
docker exec consul-server-dc2 sh -c \
  "CONSUL_HTTP_TOKEN=${BOOTSTRAP_TOKEN} CONSUL_HTTP_ADDR=http://127.0.0.1:8500 \
   consul peering list"

# ─────────────────────────────────────────────────────────────────────────────
# [11] Apply failover + DC2 exported-services configs
# ─────────────────────────────────────────────────────────────────────────────
echo "[11/12] Applying DC1 failover config (ServiceResolvers + ProxyDefaults)..."
for attempt in {1..12}; do
  if kubectl --context kind-dc1 apply -f "${ROOT_DIR}/manifests/50-failover-config.yaml"; then
    break
  fi
  echo "  Attempt ${attempt}/12 failed; retrying in 5s..."
  sleep 5
  [[ "${attempt}" -eq 12 ]] && { echo "ERROR: failover config apply failed."; exit 1; }
done

echo "  Applying DC2 exported-services + intentions config..."
for attempt in {1..12}; do
  if kubectl --context kind-dc2 apply -f "${ROOT_DIR}/manifests/60-dc2-exported-services.yaml"; then
    break
  fi
  echo "  Attempt ${attempt}/12 failed; retrying in 5s..."
  sleep 5
  [[ "${attempt}" -eq 12 ]] && { echo "ERROR: dc2 exported-services apply failed."; exit 1; }
done

# ─────────────────────────────────────────────────────────────────────────────
# [12] Wait for workloads and run verification
# ─────────────────────────────────────────────────────────────────────────────
echo "[12/12] Waiting for DC1 workloads..."

# ── 12a: GatewayClass accepted ────────────────────────────────────────────────
echo "  Waiting for GatewayClass 'consul' to be accepted in dc1..."
for _i in $(seq 1 36); do
  gc_reason="$(kubectl --context kind-dc1 get gatewayclass consul \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].reason}' 2>/dev/null || true)"
  [[ "${gc_reason}" == "Accepted" ]] && { echo "  GatewayClass accepted."; break; }
  echo "    reason=${gc_reason:-<not yet>}; retrying in 5s..."
  sleep 5
done
gc_reason="$(kubectl --context kind-dc1 get gatewayclass consul \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].reason}' 2>/dev/null || true)"
if [[ "${gc_reason}" != "Accepted" ]]; then
  echo "ERROR: GatewayClass 'consul' was not accepted."
  kubectl --context kind-dc1 get gatewayclass consul -o yaml | tail -n 40
  exit 1
fi

# ── 12b: api-gateway Deployment created ───────────────────────────────────────
echo "  Waiting for api-gateway Deployment to be created by Consul controller..."
for _i in $(seq 1 60); do
  kubectl --context kind-dc1 -n default get deploy/api-gateway >/dev/null 2>&1 && break
  sleep 5
done
kubectl --context kind-dc1 -n default get deploy/api-gateway >/dev/null 2>&1 || {
  echo "ERROR: api-gateway Deployment was not created."
  exit 1
}

kubectl --context kind-dc1 -n default rollout status deploy/api-gateway   --timeout=300s
kubectl --context kind-dc1 -n default rollout status deploy/service-a     --timeout=300s
kubectl --context kind-dc1 -n default rollout status deploy/service-b     --timeout=300s
kubectl --context kind-dc1 -n default rollout status deploy/service-c     --timeout=300s
kubectl --context kind-dc1 -n default rollout status deploy/service-d1    --timeout=300s
kubectl --context kind-dc1 -n default rollout status deploy/service-d2    --timeout=300s
kubectl --context kind-dc1 -n default rollout status deploy/route-decider --timeout=300s
kubectl --context kind-dc1 -n default rollout status deploy/ext-proc-grpc --timeout=300s

echo ""
echo "  Waiting for DC2 failover workloads..."
kubectl --context kind-dc2 -n default rollout status deploy/service-a     --timeout=300s
kubectl --context kind-dc2 -n default rollout status deploy/service-b     --timeout=300s
kubectl --context kind-dc2 -n default rollout status deploy/service-c     --timeout=300s
kubectl --context kind-dc2 -n default rollout status deploy/service-d1    --timeout=300s
kubectl --context kind-dc2 -n default rollout status deploy/service-d2    --timeout=300s
kubectl --context kind-dc2 -n default rollout status deploy/route-decider --timeout=300s
kubectl --context kind-dc2 -n default rollout status deploy/ext-proc-grpc --timeout=300s

echo "  Waiting for gateway to serve traffic after ext-proc config update..."
for _i in $(seq 1 60); do
  resp="$(kubectl --context kind-dc1 -n default exec deploy/route-decider -c route-decider -- \
    sh -c "wget -qO- --timeout=5 http://service-api-gateway.default.svc.cluster.local:8443/" 2>/dev/null || true)"
  [[ "${resp}" == *"service-a"* || "${resp}" == *"service-b"* || "${resp}" == *"service-c"* ]] && break
  sleep 3
done

echo ""
echo "Running verification against DC1 (primary)..."
CLUSTER_NAME=dc1 bash "${ROOT_DIR}/verify.sh"

echo ""
echo "============================================================"
echo " Deployment complete."
echo "============================================================"
echo ""
echo " DC1 API Gateway (primary):    curl -i http://127.0.0.1:30003/"
echo ""
echo " Failover test (bring down DC1 services, traffic shifts to DC2):"
echo "   kubectl --context kind-dc1 scale deploy/service-a --replicas=0 -n default"
echo "   curl -i http://127.0.0.1:30003/"
echo ""
echo " Consul UIs:"
echo "   DC1: http://127.0.0.1:8500"
echo "   DC2: http://127.0.0.1:8501"
echo ""
echo " To remove everything: ./down.sh"

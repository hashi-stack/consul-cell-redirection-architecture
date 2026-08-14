#!/usr/bin/env bash
# down.sh — tear down the two-cluster ext-proc failover demo

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Delete DC2 resources first (failover cluster)
if command -v kubectl >/dev/null 2>&1; then
  for ctx in kind-dc2 kind-dc1; do
    if kubectl config get-contexts "${ctx}" >/dev/null 2>&1; then
      echo "Deleting manifests in ${ctx}..."
      kubectl --context "${ctx}" \
        --request-timeout=20s \
        delete -f "${ROOT_DIR}/manifests" \
        --ignore-not-found \
        --wait=false \
        --timeout=20s >/dev/null 2>&1 || true

      echo "Uninstalling Consul Helm release in ${ctx}..."
      helm uninstall consul -n consul \
        --kube-context "${ctx}" \
        --wait --timeout 30s >/dev/null 2>&1 || true
    fi
  done
fi

# Delete kind clusters
for cluster in dc2 dc1; do
  if kind get clusters 2>/dev/null | grep -qx "${cluster}"; then
    kind delete cluster --name "${cluster}"
    echo "Deleted kind cluster '${cluster}'."
  else
    echo "Kind cluster '${cluster}' not found."
  fi
done

# Stop Consul server containers
if command -v docker >/dev/null 2>&1; then
  echo "Stopping Consul server containers..."
  docker compose -f "${ROOT_DIR}/docker-compose.yml" down --remove-orphans 2>/dev/null || true
fi

echo "Teardown complete."

#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-dc1}"
KCTX="kind-${CLUSTER_NAME}"
CONSUL_NS="consul"
BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:-e95b599e-166e-7d80-08ad-aee76e7ddf19}"
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:30003}"
VERIFY_REPEATS="${VERIFY_REPEATS:-3}"
GATEWAY_READY_RETRIES="${GATEWAY_READY_RETRIES:-24}"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found"
    exit 1
  fi
}

assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "ERROR: $label did not contain expected text"
    echo "Expected: $needle"
    echo "Actual: $haystack"
    exit 1
  fi
  echo "PASS: $label"
}

assert_route_repeated() {
  local path="$1"
  local expected="$2"
  local label_prefix="$3"
  local response=""

  for attempt in $(seq 1 "$VERIFY_REPEATS"); do
    response="$(gateway_get "$path")"
    if [[ -z "$response" ]]; then
      echo "ERROR: $label_prefix attempt $attempt returned an empty response"
      exit 1
    fi
    assert_contains "$label_prefix attempt $attempt" "$response" "$expected"
  done
}

probe_route_once() {
  local path="$1"
  local label="$2"
  local response=""
  local probe_retries="${PROBE_RETRIES:-10}"
  local probe_retry_delay="${PROBE_RETRY_DELAY:-5}"

  for attempt in $(seq 1 "$probe_retries"); do
    response="$(gateway_get "$path")"
    if [[ -n "$response" ]]; then
      echo "PROBE: $label -> $response"
      return 0
    fi
    echo "WARN: $label attempt $attempt/$probe_retries returned empty; retrying in ${probe_retry_delay}s..."
    sleep "$probe_retry_delay"
  done

  echo "ERROR: $label returned an empty response after $probe_retries attempts"
  echo "--- Full curl response from NodePort (${GATEWAY_URL}${path}) ---"
  curl -isS --max-time 10 "${GATEWAY_URL}${path}" 2>&1 || true
  echo "--- In-cluster wget response (service-api-gateway:8443${path}) ---"
  kubectl --context "$KCTX" -n default exec deploy/route-decider -c route-decider -- \
    sh -c "wget -qO- --server-response --timeout=10 http://service-api-gateway.default.svc.cluster.local:8443${path} 2>&1" 2>&1 || true
  echo "--- api-gateway Envoy logs (last 40 lines) ---"
  kubectl --context "$KCTX" -n default logs deploy/api-gateway --tail=40 2>&1 || true
  exit 1
}

set_cell() {
  local cell="$1"
  local out=""

  out="$(kubectl --context "$KCTX" -n default exec -i deploy/route-decider -c route-decider -- \
    curl -sS -X POST http://localhost:8080/set \
      -H 'Content-Type: application/json' \
      -d "{\"x-cell\":\"${cell}\"}" 2>/dev/null || true)"

  if [[ "$out" != *"$cell"* ]]; then
    echo "ERROR: failed to set route-decider x-cell to '$cell'"
    echo "route-decider /set response: $out"
    exit 1
  fi
  echo "SET: route-decider x-cell -> $cell ($out)"
}

gateway_get() {
  local path="$1"
  local out=""

  # First attempt host-level NodePort access.
  out="$(curl -fsS --max-time 10 "$GATEWAY_URL$path" 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    printf '%s' "$out"
    return 0
  fi

  # Fallback to in-cluster service access if host NodePort is not reachable.
  out="$(kubectl --context "$KCTX" -n default exec deploy/route-decider -c route-decider -- sh -c "wget -qO- --timeout=10 http://service-api-gateway.default.svc.cluster.local:8443$path" 2>/dev/null || true)"
  printf '%s' "$out"
  return 0
}

gateway_is_ready() {
  local accepted_reason=""
  local programmed_status=""
  local endpoint_ip=""

  accepted_reason="$(kubectl --context "$KCTX" -n default get gateway api-gateway -o jsonpath='{.status.conditions[?(@.type=="Accepted")].reason}' 2>/dev/null || true)"
  programmed_status="$(kubectl --context "$KCTX" -n default get gateway api-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  endpoint_ip="$(kubectl --context "$KCTX" -n default get endpoints service-api-gateway -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"

  if [[ "$accepted_reason" != "NotReconciled" && ( "$programmed_status" == "True" || -n "$endpoint_ip" ) ]]; then
    return 0
  fi

  return 1
}

wait_for_gateway_ready() {
  local attempt

  for attempt in $(seq 1 "$GATEWAY_READY_RETRIES"); do
    if gateway_is_ready; then
      return 0
    fi
    sleep 5
  done

  echo "ERROR: api-gateway was not reconciled/programmed in time."
  echo "Gateway status:"
  kubectl --context "$KCTX" -n default get gateway api-gateway -o yaml | sed -n '1,220p'
  echo "Gateway service endpoints:"
  kubectl --context "$KCTX" -n default get endpoints service-api-gateway -o yaml | sed -n '1,220p'
  echo "Default namespace resources:"
  kubectl --context "$KCTX" -n default get gateway,httproute,svc,pods | cat
  exit 1
}

require_cmd kubectl
require_cmd curl

echo "[verify 1/5] Checking core workloads are ready..."
kubectl --context "$KCTX" -n default rollout status deploy/service-a --timeout=180s >/dev/null
kubectl --context "$KCTX" -n default rollout status deploy/service-b --timeout=180s >/dev/null
kubectl --context "$KCTX" -n default rollout status deploy/service-c --timeout=180s >/dev/null
kubectl --context "$KCTX" -n default rollout status deploy/service-d1 --timeout=180s >/dev/null
kubectl --context "$KCTX" -n default rollout status deploy/service-d2 --timeout=180s >/dev/null
kubectl --context "$KCTX" -n default rollout status deploy/route-decider --timeout=180s >/dev/null
kubectl --context "$KCTX" -n default rollout status deploy/ext-proc-grpc --timeout=180s >/dev/null

echo "[verify 2/5] Checking ext-proc config entry on API gateway service-defaults..."
CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"
cfg_output=""

# The ServiceDefaults CRD is synced to the Consul catalog by the connect-injector
# controller; use the HTTP API directly (no local consul binary required) and
# retry for up to 60 s to tolerate controller sync delay.
for _i in $(seq 1 12); do
  cfg_output="$(curl -fsS --max-time 5 \
    -H "X-Consul-Token: ${BOOTSTRAP_TOKEN}" \
    "${CONSUL_HTTP_ADDR}/v1/config/service-defaults/api-gateway" 2>/dev/null || true)"
  [[ -n "$cfg_output" ]] && break
  echo "  Waiting for service-defaults/api-gateway to appear in Consul (${_i}/12)..."
  sleep 5
done

if [[ -z "$cfg_output" ]]; then
  echo "ERROR: could not read service-defaults/api-gateway from Consul after retries."
  echo "Consul leader: $(curl -fsS --max-time 5 "${CONSUL_HTTP_ADDR}/v1/status/leader" 2>/dev/null || echo '<unreachable>')"
  echo "Consul health: $(curl -fsS --max-time 5 -H "X-Consul-Token: ${BOOTSTRAP_TOKEN}" "${CONSUL_HTTP_ADDR}/v1/agent/self" 2>/dev/null | head -c 200 || echo '<unreachable>')"
  exit 1
elif [[ "$cfg_output" == *"builtin/ext-proc"* ]] || [[ "$cfg_output" == *"ext_proc"* ]] || [[ "$cfg_output" == *"ext-proc"* ]]; then
  echo "PASS: ext-proc extension appears in api-gateway service-defaults"
else
  echo "ERROR: ext-proc extension was not found in api-gateway service-defaults"
  echo "Current config entry:"
  echo "$cfg_output" | head -n 40
  exit 1
fi

if [[ "$cfg_output" == *'"listenerType":"inbound"'* ]] || \
   [[ "$cfg_output" == *'"listenerType": "inbound"'* ]] || \
   [[ "$cfg_output" == *'"ListenerType":"inbound"'* ]] || \
   [[ "$cfg_output" == *'"ListenerType": "inbound"'* ]]; then
  echo "PASS: ext-proc ListenerType is inbound for api-gateway"
else
  echo "ERROR: ext-proc ListenerType is not inbound in service-defaults/api-gateway"
  echo "Current config entry:"
  echo "$cfg_output" | head -n 80
  exit 1
fi

echo "[verify 2b/5] Checking ext-proc config entry on service-c service-defaults..."
svc_c_cfg=""
for _i in $(seq 1 12); do
  svc_c_cfg="$(curl -fsS --max-time 5 \
    -H "X-Consul-Token: ${BOOTSTRAP_TOKEN}" \
    "${CONSUL_HTTP_ADDR}/v1/config/service-defaults/service-c" 2>/dev/null || true)"
  [[ -n "$svc_c_cfg" ]] && break
  echo "  Waiting for service-defaults/service-c (${_i}/12)..."
  sleep 5
done
if [[ "$svc_c_cfg" == *"builtin/ext-proc"* ]] || [[ "$svc_c_cfg" == *"ext-proc-grpc"* ]]; then
  echo "PASS: ext-proc extension appears in service-c service-defaults"
else
  echo "ERROR: ext-proc extension was not found in service-c service-defaults"
  echo "$svc_c_cfg" | head -n 40
  exit 1
fi

echo "[verify 2c/5] Checking ServiceRouter for service-d2 is present in Consul..."
svc_d2_router=""
for _i in $(seq 1 12); do
  svc_d2_router="$(curl -fsS --max-time 5 \
    -H "X-Consul-Token: ${BOOTSTRAP_TOKEN}" \
    "${CONSUL_HTTP_ADDR}/v1/config/service-router/service-d2" 2>/dev/null || true)"
  [[ -n "$svc_d2_router" ]] && break
  echo "  Waiting for service-router/service-d2 (${_i}/12)..."
  sleep 5
done
if [[ "$svc_d2_router" == *"service-d1"* ]]; then
  echo "PASS: service-d2 ServiceRouter is present and routes to service-d1"
else
  echo "ERROR: service-d2 ServiceRouter not found or missing service-d1 destination"
  echo "$svc_d2_router" | head -n 40
  exit 1
fi

echo "[verify 2d/5] Checking ext-proc cluster has live endpoints in gateway Envoy..."
GW_PF_PORT_VERIFY=19600
GW_PF_PID_VERIFY=""
# Reuse port 19000 if already forwarded, otherwise open a fresh one on 19600.
GW_CLUSTERS=$(curl -s --max-time 2 "http://127.0.0.1:19000/clusters" 2>/dev/null || true)
if [[ -z "$GW_CLUSTERS" ]]; then
  kill $(lsof -ti tcp:${GW_PF_PORT_VERIFY}) 2>/dev/null || true
  kubectl --context "$KCTX" -n default port-forward deploy/api-gateway "${GW_PF_PORT_VERIFY}:19000" &>/tmp/gw-pf-verify.log &
  GW_PF_PID_VERIFY=$!
  # Wait up to 10s for the port-forward to be ready.
  for _i in $(seq 1 10); do
    sleep 1
    GW_CLUSTERS=$(curl -s --max-time 2 "http://127.0.0.1:${GW_PF_PORT_VERIFY}/clusters" 2>/dev/null || true)
    [[ -n "$GW_CLUSTERS" ]] && break
  done
  if [[ -n "$GW_PF_PID_VERIFY" ]]; then
    kill "$GW_PF_PID_VERIFY" 2>/dev/null || true
    wait "$GW_PF_PID_VERIFY" 2>/dev/null || true
  fi
fi

echo "$GW_CLUSTERS"
EXT_PROC_ENDPOINT=$(echo "$GW_CLUSTERS" | grep -E 'ext-proc-grpc\.default\.[^:]+\.consul::[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+.*health_flags::healthy' || true)
if [[ -n "$EXT_PROC_ENDPOINT" ]]; then
  echo "PASS: ext-proc-grpc cluster has healthy endpoints in gateway Envoy"
else
  echo "ERROR: ext-proc-grpc cluster has no healthy endpoints in gateway Envoy."
  echo "Live ext-proc-grpc cluster lines:"
  echo "$GW_CLUSTERS" | grep -E 'ext-proc-grpc\.default' | head -n 20 || true
  exit 1
fi

echo "[verify 3/5] Checking router service health endpoints..."
router_probe="$(kubectl --context "$KCTX" -n default exec deploy/route-decider -c route-decider -- sh -lc 'wget -qO- http://127.0.0.1:8080/healthz' 2>/dev/null || true)"
assert_contains "route-decider health" "$router_probe" "ok"

echo "[verify 4/5] Verifying gateway routing behavior..."
wait_for_gateway_ready

echo "[verify 4a/5] Probing live route responses via x-cell..."
# x-cell=A → service-a (cell-route rule 1)
# x-cell=B → service-b (cell-route rule 2)
# no matching x-cell → service-c (service-c-route catch-all)
for cell in A B; do
  set_cell "$cell"
  case "$cell" in
    A) expected="hello from service-a" ;;
    B) expected="hello from service-b" ;;
  esac
  probe_route_once "/" "GET / via ext-proc (x-cell=$cell)"
  assert_route_repeated "/" "$expected" "GET / via ext-proc (x-cell=$cell)"
done

echo "[verify 5/5] Checking ext-proc + route-decider logs for runtime errors and dynamic decisions..."
LOG_TAIL="${LOG_TAIL:-4000}"
ext_proc_grpc_logs="$(kubectl --context "$KCTX" -n default logs -l app=ext-proc-grpc -c ext-proc-grpc --tail="$LOG_TAIL" 2>/dev/null || true)"
route_decider_logs="$(kubectl --context "$KCTX" -n default logs -l app=route-decider -c route-decider --tail="$LOG_TAIL" 2>/dev/null || true)"

if echo "$ext_proc_grpc_logs" | grep -qi "panic"; then
  echo "ERROR: ext-proc-grpc logs show a panic"
  echo "$ext_proc_grpc_logs" | tail -n 40
  exit 1
fi

if [[ "$ext_proc_grpc_logs" != *"route-decider ->"* ]]; then
  echo "ERROR: ext-proc-grpc logs do not show route-decider consultation"
  echo "$ext_proc_grpc_logs" | tail -n 10
  exit 1
fi
echo "PASS: ext-proc-grpc shows route-decider consultation"

if [[ "$route_decider_logs" != *"x-cell=\"B\""* ]]; then
  echo "ERROR: route-decider logs do not show an x-cell=B decision"
  echo "$route_decider_logs" | tail -n 80
  exit 1
fi

echo ""
echo "Verification PASSED: ext-proc testcase is healthy."

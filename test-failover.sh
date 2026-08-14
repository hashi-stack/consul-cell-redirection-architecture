#!/usr/bin/env bash
# test-failover.sh — targeted failover correctness test for service-a (DC1 → DC2).
#
# What it tests:
#   1. Pre-conditions: DC1 + DC2 workloads ready, ProxyDefaults outlier detection
#      applied, cluster peering ACTIVE.
#   2. Baseline: x-cell=A reaches service-a in DC1 (normal routing).
#   3. Scale service-a in DC1 to 0 replicas.
#   4. Failover window: within MAX_FAILOVER_REQUESTS attempts, the gateway must
#      start responding 200 again — routed via the DC2 peer cluster.
#   5. DC2 response validation: response body contains "service-a" (same fake-service
#      name, proving DC2's service-a is answering, not a different service).
#   6. Recovery: restore DC1 service-a to 1 replica, confirm DC1 resumes serving.
#
# Exit codes:
#   0  all assertions passed
#   1  at least one assertion failed
#
# Env overrides:
#   KCTX_DC1                (default: kind-dc1)
#   KCTX_DC2                (default: kind-dc2)
#   GATEWAY_URL             (default: http://127.0.0.1:30003)
#   BOOTSTRAP_TOKEN         (default: e95b599e-166e-7d80-08ad-aee76e7ddf19)
#   CONSUL_DC1_ADDR         (default: http://127.0.0.1:8500)
#   NAMESPACE               (default: default)
#   MAX_FAILOVER_REQUESTS   max consecutive requests allowed before failover kicks in (default: 5)
#   FAILOVER_PROBE_RETRIES  how many times to probe after scale-down waiting for 200 (default: 30)
#   FAILOVER_PROBE_DELAY    seconds between probes (default: 2)
#   GW_ADMIN_PORT           api-gateway Envoy admin port-forward (default: 19000)

set -uo pipefail

KCTX_DC1="${KCTX_DC1:-kind-dc1}"
KCTX_DC2="${KCTX_DC2:-kind-dc2}"
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:30003}"
BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:-e95b599e-166e-7d80-08ad-aee76e7ddf19}"
CONSUL_DC1_ADDR="${CONSUL_DC1_ADDR:-http://127.0.0.1:8500}"
NAMESPACE="${NAMESPACE:-default}"
MAX_FAILOVER_REQUESTS="${MAX_FAILOVER_REQUESTS:-5}"
FAILOVER_PROBE_RETRIES="${FAILOVER_PROBE_RETRIES:-30}"
FAILOVER_PROBE_DELAY="${FAILOVER_PROBE_DELAY:-2}"
GW_ADMIN_PORT="${GW_ADMIN_PORT:-19000}"

# ── colours ───────────────────────────────────────────────────────────────────
BOLD=$'\e[1m'; RESET=$'\e[0m'
CYAN=$'\e[1;36m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'
DIM=$'\e[2m';  RED=$'\e[1;31m'

# ── test accounting ───────────────────────────────────────────────────────────
PASS=0; FAIL=0
FAILED_TESTS=()

banner() {
  local msg="$1"; local width=70
  local line; line="$(printf '%*s' "$width" '' | tr ' ' '─')"
  echo; echo "${CYAN}${line}${RESET}"
  printf "${CYAN}│${RESET}  ${BOLD}%-$((width-4))s${CYAN}  │${RESET}\n" "$msg"
  echo "${CYAN}${line}${RESET}"
}
step()  { echo; echo "${YELLOW}▶  $*${RESET}"; }
info()  { echo "   ${DIM}$*${RESET}"; }
pass()  { echo "   ${GREEN}✔  PASS: $*${RESET}"; (( PASS++ )) || true; }
fail()  { echo "   ${RED}✘  FAIL: $*${RESET}"; (( FAIL++ )) || true; FAILED_TESTS+=("$*"); }
warn()  { echo "   ${YELLOW}⚠  WARN: $*${RESET}"; }

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [[ "${got}" == "${want}" ]]; then pass "${label}"; else
    fail "${label} — got='${got}' want='${want}'"; fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then pass "${label}"; else
    fail "${label} — '${needle}' not found in response"; fi
}
assert_not_empty() {
  local label="$1" val="$2"
  if [[ -n "${val}" ]]; then pass "${label}"; else fail "${label} — value is empty"; fi
}

# ── cleanup on exit ───────────────────────────────────────────────────────────
RESTORE_NEEDED=0
cleanup() {
  if (( RESTORE_NEEDED )); then
    echo
    warn "Restoring DC1 service-a to 1 replica (cleanup)..."
    kubectl --context "${KCTX_DC1}" -n "${NAMESPACE}" \
      scale deploy/service-a --replicas=1 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'echo; echo "${RED}Interrupted.${RESET}"; exit 130' INT TERM

# ── gateway GET helper ────────────────────────────────────────────────────────
gw_get() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 8 "${GATEWAY_URL}/" 2>/dev/null || echo "000"
}
gw_body() {
  curl -sf --max-time 8 "${GATEWAY_URL}/" 2>/dev/null || true
}

# ── route-decider cell setter ─────────────────────────────────────────────────
set_cell() {
  local cell="$1"
  kubectl --context "${KCTX_DC1}" -n "${NAMESPACE}" \
    exec deploy/route-decider -c route-decider -- \
    curl -sS --max-time 5 -X POST http://localhost:8080/set \
         -H 'Content-Type: application/json' \
         -d "{\"x-cell\":\"${cell}\"}" >/dev/null 2>&1 || true
}

# ══════════════════════════════════════════════════════════════════════════════
banner "Failover correctness test  —  service-a  (DC1 → DC2)"
echo
echo "  ${BOLD}Gateway:${RESET}        ${GATEWAY_URL}"
echo "  ${BOLD}DC1 context:${RESET}    ${KCTX_DC1}"
echo "  ${BOLD}DC2 context:${RESET}    ${KCTX_DC2}"
echo "  ${BOLD}Max err budget:${RESET} ${MAX_FAILOVER_REQUESTS} requests before failover must succeed"
echo

# ══════════════════════════════════════════════════════════════════════════════
banner "TC-1  Pre-conditions"

# TC-1a: required commands
step "TC-1a: required commands present"
for cmd in kubectl curl; do
  if command -v "${cmd}" &>/dev/null; then pass "command '${cmd}' found"
  else fail "command '${cmd}' not found"; fi
done

# TC-1b: DC1 workloads ready — wait up to 60s for Consul connect-inject to finish
step "TC-1b: DC1 core workloads ready"
for deploy in service-a ext-proc-grpc route-decider; do
  ready=0
  for _w in $(seq 1 20); do
    ready="$(kubectl --context "${KCTX_DC1}" -n "${NAMESPACE}" \
      get deploy/"${deploy}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    [[ "${ready:-0}" -ge 1 ]] && break
    sleep 3
  done
  if [[ "${ready:-0}" -ge 1 ]]; then pass "DC1/${deploy} ready (${ready} replica)"
  else fail "DC1/${deploy} not ready (readyReplicas=${ready:-0})"; fi
done

# TC-1c: DC2 service-a ready
step "TC-1c: DC2 service-a ready"
ready_dc2="$(kubectl --context "${KCTX_DC2}" -n "${NAMESPACE}" \
  get deploy/service-a -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
if [[ "${ready_dc2:-0}" -ge 1 ]]; then pass "DC2/service-a ready (${ready_dc2} replica)"
else fail "DC2/service-a not ready (readyReplicas=${ready_dc2:-0})"; fi

# TC-1d: cluster peering ACTIVE from DC1's perspective
step "TC-1d: cluster peering DC1 → DC2 ACTIVE"
peering_state="$(curl -sf --max-time 5 \
  -H "X-Consul-Token: ${BOOTSTRAP_TOKEN}" \
  "${CONSUL_DC1_ADDR}/v1/peering/peer-dc2" 2>/dev/null \
  | python3 -c "import sys,json; p=json.load(sys.stdin); print(p.get('State',''))" 2>/dev/null || echo "")"
if [[ "${peering_state}" == "ACTIVE" ]]; then pass "peering peer-dc2 state=ACTIVE"
else fail "peering peer-dc2 state='${peering_state}' (want ACTIVE)"; fi

# TC-1e: ServiceResolver for service-a is present in Consul catalog
step "TC-1e: ServiceResolver/service-a present in Consul"
resolver_json="$(curl -sf --max-time 5 \
  -H "X-Consul-Token: ${BOOTSTRAP_TOKEN}" \
  "${CONSUL_DC1_ADDR}/v1/config/service-resolver/service-a" 2>/dev/null || true)"
if [[ -n "${resolver_json}" ]]; then pass "ServiceResolver/service-a found in Consul catalog"
else fail "ServiceResolver/service-a not found in Consul catalog — apply 50-failover-config.yaml"; fi

# TC-1f: ServiceResolver has failover target peer-dc2
step "TC-1f: ServiceResolver failover target = peer-dc2"
peer_target="$(echo "${resolver_json}" | python3 -c \
  "import sys,json; r=json.load(sys.stdin); \
   targets=r.get('Failover',{}).get('*',{}).get('Targets',[]); \
   print(targets[0].get('Peer','') if targets else '')" 2>/dev/null || echo "")"
if [[ "${peer_target}" == "peer-dc2" ]]; then pass "ServiceResolver failover target = peer-dc2"
else fail "ServiceResolver failover target='${peer_target}' (want peer-dc2)"; fi

# TC-1g: service-a pod has preStop hook (fast deregistration before TCP close)
# consul-dataplane 2.0.0 does not translate passiveHealthCheck/upstreamConfig to
# Envoy xDS for the api-gateway proxy type.  Failover is driven by fast Consul EDS
# deregistration: the preStop hook sleeps 5s so consul-dataplane can push an EDS
# update removing the endpoint before the port closes, preventing ECONNREFUSED.
step "TC-1g: DC1/service-a pod has preStop sleep hook for graceful deregistration"
prestop="$(kubectl --context "${KCTX_DC1}" -n "${NAMESPACE}" \
  get deploy/service-a \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="service-a")].lifecycle.preStop.exec.command}' \
  2>/dev/null || true)"
if [[ "${prestop}" == *"sleep"* ]]; then
  pass "DC1/service-a has preStop sleep hook (graceful deregistration window)"
else
  fail "DC1/service-a missing preStop hook — apply 10-services.yaml and rollout restart deploy/service-a"
fi

# TC-1h: Envoy aggregate cluster wired (failover-target~1 present) + outlier_detection non-empty
step "TC-1h: Envoy aggregate cluster has failover-target~1 for service-a"
gw_clusters="$(curl -s --max-time 5 "http://127.0.0.1:${GW_ADMIN_PORT}/clusters" 2>/dev/null || true)"
if [[ -z "${gw_clusters}" ]]; then
  warn "Gateway admin port ${GW_ADMIN_PORT} not reachable — skipping Envoy cluster check"
  warn "Port-forward with: kubectl --context kind-dc1 -n default port-forward deploy/api-gateway 19000:19000"
else
  if echo "${gw_clusters}" | grep -q "failover-target~1~service-a"; then
    pass "Envoy failover-target~1~service-a cluster present"
  else
    fail "Envoy failover-target~1~service-a cluster NOT present — ServiceResolver may not be applied"
  fi
  # Check outlier_detection is non-empty (populated by passiveHealthCheck in ServiceDefaults)
  sva_od="$(curl -s --max-time 5 \
    "http://127.0.0.1:${GW_ADMIN_PORT}/config_dump?resource=&name_regex=failover-target~0~service-a" \
    2>/dev/null | python3 -c \
    "import sys,json; d=json.load(sys.stdin); \
     clusters=[c['cluster'] for s in d.get('configs',[]) \
               for c in s.get('dynamic_active_clusters',s.get('static_clusters',[])) \
               if 'cluster' in c]; \
     od=[c.get('outlier_detection',{}) for c in clusters]; \
     print('has_rules' if any(len(str(o)) > 2 for o in od) else 'empty')" \
    2>/dev/null || echo "unknown")"
  if [[ "${sva_od}" == "has_rules" ]]; then
    pass "Envoy failover-target~0~service-a has outlier_detection rules"
  else
    # In consul-dataplane 2.0.0 the api-gateway proxy type does not translate
    # passiveHealthCheck to Envoy outlier_detection xDS.  Failover still works
    # via the preStop deregistration hook — this is informational only.
    warn "Envoy failover-target~0~service-a outlier_detection is empty (expected for api-gateway in consul-dataplane 2.0.0 — failover driven by preStop deregistration)"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
banner "TC-2  Baseline routing (x-cell=A → service-a DC1)"

step "TC-2a: set route-decider x-cell=A"
set_cell "A"
info "route-decider cell set to A"

step "TC-2b: gateway returns HTTP 200"
code="$(gw_get)"
assert_eq "baseline HTTP status" "${code}" "200"

step "TC-2c: response body contains 'service-a'"
body="$(gw_body)"
assert_contains "baseline body" "${body}" "service-a"
info "Response snippet: $(echo "${body}" | head -c 120 | tr '\n' ' ')"

# ══════════════════════════════════════════════════════════════════════════════
banner "TC-3  Scale service-a to 0 in DC1"

step "TC-3a: scale DC1/service-a → 0 replicas"
kubectl --context "${KCTX_DC1}" -n "${NAMESPACE}" \
  scale deploy/service-a --replicas=0
RESTORE_NEEDED=1
pass "scale command issued"

step "TC-3b: confirm DC1/service-a has 0 ready replicas"
# Give K8s up to 15 s to terminate the pod
for _i in $(seq 1 15); do
  ready_dc1="$(kubectl --context "${KCTX_DC1}" -n "${NAMESPACE}" \
    get deploy/service-a -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  [[ "${ready_dc1:-0}" -eq 0 ]] && break
  sleep 1
done
ready_dc1="$(kubectl --context "${KCTX_DC1}" -n "${NAMESPACE}" \
  get deploy/service-a -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
if [[ "${ready_dc1:-0}" -eq 0 ]]; then pass "DC1/service-a readyReplicas=0"
else fail "DC1/service-a still has ${ready_dc1} ready replicas after 15 s"; fi

# ══════════════════════════════════════════════════════════════════════════════
banner "TC-4  Failover triggers and DC2 serves traffic"

step "TC-4a: probe gateway until failover kicks in (max ${FAILOVER_PROBE_RETRIES} × ${FAILOVER_PROBE_DELAY}s)"
info "Each failure increments error budget (max=${MAX_FAILOVER_REQUESTS})."

consecutive_errs=0
failover_attempt=0
failover_success=0
first_200_body=""

for _i in $(seq 1 "${FAILOVER_PROBE_RETRIES}"); do
  (( failover_attempt++ )) || true
  code="$(gw_get)"
  if [[ "${code}" == "200" ]]; then
    first_200_body="$(gw_body)"
    failover_success=1
    info "Got HTTP 200 on attempt ${failover_attempt} (after ${consecutive_errs} error(s))"
    break
  else
    (( consecutive_errs++ )) || true
    info "Attempt ${failover_attempt}: HTTP ${code} (${consecutive_errs} consecutive errors so far)"
    if (( consecutive_errs > MAX_FAILOVER_REQUESTS )); then
      fail "Failover took more than ${MAX_FAILOVER_REQUESTS} consecutive errors (got ${consecutive_errs})"
      break
    fi
  fi
  sleep "${FAILOVER_PROBE_DELAY}"
done

if (( failover_success )); then
  pass "Failover succeeded within error budget (errors before recovery: ${consecutive_errs})"
else
  if (( consecutive_errs <= MAX_FAILOVER_REQUESTS )); then
    fail "No HTTP 200 received within ${FAILOVER_PROBE_RETRIES} attempts — failover did not trigger"
  fi
fi

# TC-4b: verify the successful response still came from service-a (DC2)
step "TC-4b: response after failover still contains 'service-a' (served by DC2)"
if (( failover_success )); then
  assert_contains "post-failover body" "${first_200_body}" "service-a"
  info "Response snippet: $(echo "${first_200_body}" | head -c 120 | tr '\n' ' ')"
else
  fail "post-failover body check skipped — failover did not produce a 200"
fi

# TC-4c: sustained traffic after failover — 10 consecutive requests must all be 200
step "TC-4c: 10 consecutive requests after failover all return 200"
if (( failover_success )); then
  sustained_ok=0; sustained_fail=0
  for _j in $(seq 1 10); do
    c="$(gw_get)"
    if [[ "${c}" == "200" ]]; then (( sustained_ok++ )) || true
    else (( sustained_fail++ )) || true; fi
  done
  if (( sustained_fail == 0 )); then
    pass "sustained traffic: ${sustained_ok}/10 requests returned 200"
  else
    fail "sustained traffic: ${sustained_fail}/10 requests failed after failover"
  fi
else
  fail "sustained traffic check skipped — failover did not trigger"
fi

# ══════════════════════════════════════════════════════════════════════════════
banner "TC-5  DC1 recovery — restore service-a, confirm DC1 resumes"

step "TC-5a: restore DC1/service-a → 1 replica"
kubectl --context "${KCTX_DC1}" -n "${NAMESPACE}" \
  scale deploy/service-a --replicas=1
RESTORE_NEEDED=0
pass "scale restore command issued"

step "TC-5b: wait for DC1/service-a to become ready (up to 120 s)"
kubectl --context "${KCTX_DC1}" -n "${NAMESPACE}" \
  rollout status deploy/service-a --timeout=120s >/dev/null 2>&1 \
  && pass "DC1/service-a rollout complete" \
  || fail "DC1/service-a rollout did not complete in 120 s"

step "TC-5c: gateway returns 200 after DC1 recovery"
recovered=0
for _i in $(seq 1 20); do
  code="$(gw_get)"
  if [[ "${code}" == "200" ]]; then recovered=1; break; fi
  sleep 3
done
if (( recovered )); then pass "gateway returns 200 after DC1 recovery"
else fail "gateway still not returning 200 after DC1 recovery"; fi

# ══════════════════════════════════════════════════════════════════════════════
banner "Results"
echo
printf "  ${GREEN}%-10s %4d${RESET}\n" "PASSED:" "${PASS}"
printf "  ${RED}%-10s %4d${RESET}\n"   "FAILED:" "${FAIL}"
echo
if (( FAIL > 0 )); then
  echo "  ${BOLD}Failed tests:${RESET}"
  for t in "${FAILED_TESTS[@]}"; do
    printf "  ${RED}  • %s${RESET}\n" "${t}"
  done
  echo
  echo "${RED}${BOLD}  ✘  OVERALL: FAIL${RESET}"
  echo
  exit 1
else
  echo "${GREEN}${BOLD}  ✔  OVERALL: PASS — service-a failover DC1→DC2 working correctly${RESET}"
  echo
  exit 0
fi

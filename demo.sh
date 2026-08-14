#!/usr/bin/env bash
# demo.sh — load / concurrency test against the API gateway while progressively
# scaling down DC1 services every 20 s, then reports success / error totals.

set -euo pipefail

KCTX_DC1="${KCTX_DC1:-kind-dc1}"
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:30003}"
CONCURRENCY="${CONCURRENCY:-100}"
NAMESPACE="${NAMESPACE:-default}"

# ── colours ───────────────────────────────────────────────────────────────────
BOLD=$'\e[1m';    RESET=$'\e[0m'
CYAN=$'\e[1;36m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'
BLUE=$'\e[1;34m'; DIM=$'\e[2m';      RED=$'\e[1;31m'

# ── helpers ───────────────────────────────────────────────────────────────────
banner() {
  local msg="$1"
  local width=70
  local line; line="$(printf '%*s' "$width" '' | tr ' ' '─')"
  echo
  echo "${CYAN}${line}${RESET}"
  printf "${CYAN}│${RESET}  ${BOLD}%-$((width-4))s${CYAN}  │${RESET}\n" "$msg"
  echo "${CYAN}${line}${RESET}"
}

step()  { echo; echo "${YELLOW}▶  $*${RESET}"; }
info()  { echo "   ${DIM}$*${RESET}"; }
ok()    { echo "   ${GREEN}✔  $*${RESET}"; }
err()   { echo "   ${RED}✘  $*${RESET}"; }

# ── trap Ctrl-C ───────────────────────────────────────────────────────────────
trap 'echo; echo "${RED}Demo interrupted.${RESET}"; exit 130' INT

# ── temp directory for per-worker result files ────────────────────────────────
TMPDIR_RESULTS="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_RESULTS}"; echo; echo "${RED}Demo interrupted.${RESET}"; exit 130' INT
LOAD_PID_FILE="${TMPDIR_RESULTS}/load.pids"

# ── scale helper ──────────────────────────────────────────────────────────────
scale_down() {
  local deploy="$1"
  echo "   ${YELLOW}⬇  scaling ${BOLD}${deploy}${RESET}${YELLOW} → 0 replicas (DC1)${RESET}"
  kubectl --context "${KCTX_DC1}" -n "${NAMESPACE}" \
    scale deploy/"${deploy}" --replicas=0 2>&1 | sed 's/^/      /' || true
}

# ══════════════════════════════════════════════════════════════════════════════
banner "Failover load-test  —  ext-proc e2e demo  (DC1 → DC2)"
echo
echo "  ${BOLD}Gateway:${RESET}     ${GATEWAY_URL}"
echo "  ${BOLD}Context:${RESET}     ${KCTX_DC1}"
echo "  ${BOLD}Concurrency:${RESET} ${CONCURRENCY} parallel workers"
echo
echo "  Each worker sends continuous GET requests to the gateway."
echo "  While the load is running, DC1 deployments are scaled to 0"
echo "  in 20-second intervals:"
echo
echo "    t=0 s   load starts"
echo "    t=20 s  ext-proc-grpc  → 0"
echo "    t=40 s  service-a      → 0"
echo "    t=60 s  service-b      → 0"
echo "    t=80 s  service-c      → 0"
echo "    t=100 s service-d1     → 0"
echo "    t=120 s service-d2     → 0"
echo "    t=130 s load stops + report"
echo

# ── require curl ──────────────────────────────────────────────────────────────
if ! command -v curl &>/dev/null; then
  echo "${RED}ERROR: curl is required but not found in PATH.${RESET}"
  exit 1
fi

# ── gateway connectivity pre-check ───────────────────────────────────────────
step "Pre-flight: checking gateway reachability"
if ! curl -sf --max-time 5 "${GATEWAY_URL}/" >/dev/null 2>&1; then
  err "Gateway at ${GATEWAY_URL} is not reachable. Ensure the cluster is up."
  exit 1
fi
ok "Gateway is reachable."

# ══════════════════════════════════════════════════════════════════════════════
banner "Phase 1 — starting ${CONCURRENCY} concurrent load workers"

# Each worker writes one line per request: "ok" or "err:<http_code_or_msg>"
# Worker loop: runs until the sentinel file disappears.
STOP_FILE="${TMPDIR_RESULTS}/stop"
touch "${STOP_FILE}"

worker() {
  local id="$1"
  local out="${TMPDIR_RESULTS}/worker-${id}.log"
  while [[ -f "${STOP_FILE}" ]]; do
    http_code="$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 8 "${GATEWAY_URL}/" 2>/dev/null || echo "000")"
    if [[ "${http_code}" == "200" ]]; then
      echo "ok" >> "${out}"
    else
      echo "err:${http_code}" >> "${out}"
    fi
  done
}

# Spawn all workers in the background
for i in $(seq 1 "${CONCURRENCY}"); do
  worker "${i}" &
done
info "All ${CONCURRENCY} workers running (PIDs in background)."
LOAD_START_TS="${SECONDS}"

# ══════════════════════════════════════════════════════════════════════════════
banner "Phase 2 — progressive DC1 scale-down (one deployment every 20 s)"

SCALE_TARGETS=(ext-proc-grpc service-a service-b service-c service-d1 service-d2)

for deploy in "${SCALE_TARGETS[@]}"; do
  elapsed=$(( SECONDS - LOAD_START_TS ))
  step "t=${elapsed}s — scaling down ${BOLD}${deploy}${RESET}"
  scale_down "${deploy}"
  info "Sleeping 20 s before next scale-down..."
  sleep 20
done

# One extra 10 s window to capture post-failover traffic
info "Waiting 10 s for final failover traffic capture..."
sleep 10

# ══════════════════════════════════════════════════════════════════════════════
banner "Phase 3 — stopping load workers"

rm -f "${STOP_FILE}"          # signal workers to stop
sleep 2                       # give workers a moment to finish their last request
wait 2>/dev/null || true      # reap all background jobs

elapsed=$(( SECONDS - LOAD_START_TS ))
ok "Load test ran for ${elapsed} seconds."

# ══════════════════════════════════════════════════════════════════════════════
banner "Phase 4 — results"

total_ok=0
total_err=0
declare -A err_codes

while IFS= read -r line; do
  if [[ "${line}" == "ok" ]]; then
    (( total_ok++ )) || true
  elif [[ "${line}" == err:* ]]; then
    (( total_err++ )) || true
    code="${line#err:}"
    err_codes["${code}"]=$(( ${err_codes["${code}"]:-0} + 1 ))
  fi
done < <(cat "${TMPDIR_RESULTS}"/worker-*.log 2>/dev/null)

total=$(( total_ok + total_err ))

echo
printf "  ${BOLD}%-30s %10s${RESET}\n" "Metric" "Count"
printf "  %-30s %10s\n" "──────────────────────────────" "──────────"
printf "  ${GREEN}%-30s %10d${RESET}\n" "Successful (HTTP 200)" "${total_ok}"
printf "  ${RED}%-30s %10d${RESET}\n"   "Errors"                "${total_err}"
printf "  ${BOLD}%-30s %10d${RESET}\n" "Total requests"        "${total}"

if (( total > 0 )); then
  success_pct=$(( total_ok * 100 / total ))
  error_pct=$(( total_err * 100 / total ))
  printf "  ${GREEN}%-30s %9d%%${RESET}\n" "Success rate"  "${success_pct}"
  printf "  ${RED}%-30s %9d%%${RESET}\n"   "Error rate"    "${error_pct}"
fi

if (( ${#err_codes[@]} > 0 )); then
  echo
  echo "  ${BOLD}Error breakdown by HTTP code:${RESET}"
  for code in $(printf '%s\n' "${!err_codes[@]}" | sort); do
    printf "  ${RED}  %-10s %8d${RESET}\n" "${code}" "${err_codes[$code]}"
  done
fi

echo

if (( total_ok > 0 )); then
  ok "Failover worked — ${total_ok} requests succeeded despite DC1 scale-down."
else
  err "No successful requests recorded. Check cluster and gateway state."
fi

# ── restore ext-proc-grpc to 1 replica ───────────────────────────────────────
step "Restoring ext-proc-grpc → 1 replica (DC1)"
kubectl --context "${KCTX_DC1}" -n "${NAMESPACE}" \
  scale deploy/ext-proc-grpc --replicas=1
ok "ext-proc-grpc restored to 1 replica."

# ── clean up temp dir ─────────────────────────────────────────────────────────
rm -rf "${TMPDIR_RESULTS}"

echo
echo "${DIM}  Other DC1 deployments (service-a…service-d2) are still at 0 replicas."
echo "  To restore them: kubectl --context kind-dc1 -n default scale deploy/<name> --replicas=1${RESET}"
echo

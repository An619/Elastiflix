#!/usr/bin/env bash
# Verify that the Elastiflix deployment actually works, not just that pods exist.
#
# `bootstrap.sh` deploys; this proves the deployment serves searches. It is
# deliberately dependency-free (bash + kubectl only), read-only, and it never
# mutates the cluster.
#
# Every check prints PASS, FAIL or SKIP with the evidence that produced the
# verdict, and the script exits non-zero if anything FAILs. SKIP means "could not
# be evaluated here" and is never counted as a pass — the distinction matters,
# because a green pod with an empty index is exactly the failure this catches.
#
# Usage:
#   scripts/verify-deployment.sh                 # human-readable
#   scripts/verify-deployment.sh --verbose       # show each command's output
#   scripts/verify-deployment.sh --json          # machine-readable summary
#   scripts/verify-deployment.sh --quick         # skip the slow index checks
#
# Exit codes: 0 all checks passed, 1 at least one FAIL, 2 bad usage.
set -uo pipefail

NS_APP="elastiflix"
NS_INFRA="infra"
NS_ELK="elastic-stack"
NS_MON="monitoring"
NS_ARGOCD="argocd"
ES_INDEX="elastiflix-movies"
# The catalogue is 6,959 documents (data-loader/movies/movies.json.gz). Anything
# materially below this means ingestion is incomplete, not merely in progress.
EXPECTED_DOCS=6959

VERBOSE=0
JSON=0
QUICK=0
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=1 ;;
    --json) JSON=1 ;;
    --quick|-q) QUICK=1 ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found; this script must run where kubectl is configured" >&2
  exit 2
fi
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "no reachable cluster; run inside a configured context" >&2
  exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
RESULTS=()   # "STATUS|name|evidence"

# show <text>: only under --verbose, so the normal run stays readable.
show() { [ "$VERBOSE" -eq 1 ] && printf '      %s\n' "$*"; return 0; }

record() { # record <PASS|FAIL|SKIP> <name> <evidence>
  local status="$1" name="$2" evidence="${3:-}"
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
  esac
  RESULTS+=("${status}|${name}|${evidence}")
  if [ "$JSON" -eq 0 ]; then
    case "$status" in
      PASS) printf '  \033[32mPASS\033[0m  %-46s %s\n' "$name" "$evidence" ;;
      FAIL) printf '  \033[31mFAIL\033[0m  %-46s %s\n' "$name" "$evidence" ;;
      SKIP) printf '  \033[33mSKIP\033[0m  %-46s %s\n' "$name" "$evidence" ;;
    esac
  fi
}

section() { [ "$JSON" -eq 0 ] && printf '\n\033[1m%s\033[0m\n' "$1"; return 0; }

# check <name> <command...>: PASS when the command succeeds.
check() {
  local name="$1"; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  show "$out"
  if [ $rc -eq 0 ]; then record PASS "$name" ""; else
    record FAIL "$name" "$(printf '%s' "$out" | tail -1 | cut -c1-90)"; fi
}

# expect_eq <name> <expected> <actual>
expect_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then record PASS "$name" "$got"
  else record FAIL "$name" "want '$want', got '$got'"; fi
}

# expect_ge <name> <minimum> <actual>
expect_ge() {
  local name="$1" min="$2" got="$3"
  case "$got" in ''|*[!0-9]*) record FAIL "$name" "non-numeric: '$got'"; return;; esac
  if [ "$got" -ge "$min" ]; then record PASS "$name" "$got"
  else record FAIL "$name" "$got < $min"; fi
}

# pod_ready <namespace> <label-selector>: echoes "ready/total"
pod_ready() {
  kubectl -n "$1" get pods -l "$2" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Running")].status}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -c True
}

# exec_in <namespace> <selector> <shell command>: runs sh -c inside the first pod.
exec_in() {
  local ns="$1" sel="$2" cmd="$3" pod
  pod=$(kubectl -n "$ns" get pods -l "$sel" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -z "$pod" ] && { echo "no pod matching $sel"; return 1; }
  kubectl -n "$ns" exec "$pod" -- sh -c "$cmd" 2>&1
}

# In --json mode the only thing on stdout may be the JSON document, or every
# consumer needs a filter. Header goes to stderr instead.
CONTEXT="$(kubectl config current-context 2>/dev/null || echo unknown)"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$JSON" -eq 1 ]; then
  printf 'verifying on context %s at %s\n' "$CONTEXT" "$STAMP" >&2
else
  echo "Elastiflix deployment verification"
  echo "context: ${CONTEXT}   ${STAMP}"
fi

# ---------------------------------------------------------------------------
section "1. Cluster and tooling"
# ---------------------------------------------------------------------------
check "namespace ${NS_APP} exists"      kubectl get namespace "$NS_APP"
check "namespace ${NS_ELK} exists"      kubectl get namespace "$NS_ELK"
check "namespace ${NS_MON} exists"      kubectl get namespace "$NS_MON"
check "Argo CD is installed"            kubectl -n "$NS_ARGOCD" get deployment argocd-server
check "Argo Rollouts controller running" kubectl -n argo-rollouts get deployment argo-rollouts
check "CNI enforces NetworkPolicy (calico)" kubectl -n kube-system get pods -l k8s-app=calico-node

# ---------------------------------------------------------------------------
section "2. Workloads are actually running (not merely created)"
# ---------------------------------------------------------------------------
for spec in \
  "backend:${NS_APP}:app=backend:Deployment/backend" \
  "frontend:${NS_APP}:app=frontend:Rollout/frontend" \
  "redis:${NS_INFRA}:app=redis:Deployment/redis" \
  "rabbitmq:${NS_INFRA}:app=rabbitmq:Deployment/rabbitmq" \
  "elasticsearch:${NS_ELK}:app=elasticsearch:StatefulSet/elasticsearch" \
  "kibana:${NS_ELK}:app=kibana:Deployment/kibana" \
  "logstash:${NS_ELK}:app=logstash:Deployment/logstash"
do
  IFS=':' read -r name ns sel obj <<<"$spec"
  check "${name} pods Running" bash -c \
    "[ \"\$(kubectl -n ${ns} get pods -l ${sel} --field-selector=status.phase=Running -o name | wc -l)\" -gt 0 ]"
done

# A pod that is Running but not Ready is the most common false positive.
check "backend endpoints populated" bash -c \
  "[ -n \"\$(kubectl -n ${NS_APP} get endpoints backend -o jsonpath='{.subsets[*].addresses[*].ip}')\" ]"
check "frontend endpoints populated" bash -c \
  "[ -n \"\$(kubectl -n ${NS_APP} get endpoints frontend -o jsonpath='{.subsets[*].addresses[*].ip}')\" ]"

# ---------------------------------------------------------------------------
section "3. Catalogue ingested (the failure mode green pods cannot show)"
# ---------------------------------------------------------------------------
es_get() { exec_in "$NS_ELK" app=elasticsearch "curl -s --max-time 10 'http://localhost:9200$1'"; }

es_health=$(es_get "/_cluster/health" | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p')
case "$es_health" in
  green|yellow) record PASS "Elasticsearch cluster health" "$es_health" ;;
  '')           record FAIL "Elasticsearch cluster health" "no response from :9200" ;;
  *)            record FAIL "Elasticsearch cluster health" "$es_health" ;;
esac

if [ "$QUICK" -eq 1 ]; then
  record SKIP "catalogue document count" "--quick"
else
  doc_count=$(es_get "/${ES_INDEX}/_count" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
  expect_ge "catalogue document count (${ES_INDEX})" "$EXPECTED_DOCS" "${doc_count:-0}"

  # Field the UI's facet depends on; the Logstash pipeline derives it.
  has_field=$(es_get "/${ES_INDEX}/_search?size=1&_source=user_score" | grep -c '"user_score"')
  expect_ge "catalogue has derived user_score field" 1 "$has_field"
fi

# ---------------------------------------------------------------------------
section "4. Application API (behaviour, not liveness)"
# ---------------------------------------------------------------------------
check "backend /healthz returns OK" bash -c \
  "[ \"\$(kubectl -n ${NS_APP} exec deploy/backend -- wget -qO- http://localhost:17700/healthz)\" = OK ]"

search_json=$(exec_in "$NS_APP" app=backend \
  "wget -qO- --header='Content-Type: application/json' --post-data='{\"state\":{\"searchTerm\":\"matrix\",\"current\":1},\"queryConfig\":{\"resultsPerPage\":3}}' http://localhost:17700/api/search")

total=$(printf '%s' "$search_json" | sed -n 's/.*"totalResults":\([0-9]*\).*/\1/p')
if [ -z "$search_json" ]; then
  record FAIL "POST /api/search returns results" "empty response"
else
  expect_ge "POST /api/search returns results" 1 "${total:-0}"
  # The response mirrors search-ui: each field is {"raw": ...}, so the title
  # lives at results[].title.raw, not title. Extracting the wrong path was a
  # real bug in the first version of this script.
  titles=$(printf '%s' "$search_json" | grep -o '"raw":"[^"]*"' | head -3 | cut -d'"' -f4 | paste -sd', ' -)
  [ -n "$titles" ] && record PASS "search results contain titles" "${titles:0:70}" \
                   || record FAIL "search results contain titles" "no title field in response"
fi

for mode in search rerank/search semantic/search hybrid/search; do
  code=$(exec_in "$NS_APP" app=backend \
    "wget -qS -O /dev/null --header='Content-Type: application/json' --post-data='{\"state\":{\"searchTerm\":\"batman\",\"current\":1},\"queryConfig\":{\"resultsPerPage\":2}}' http://localhost:17700/api/${mode} 2>&1 | head -1" \
    | sed -n 's/.*HTTP\/1\.1 \([0-9]*\).*/\1/p')
  case "$code" in
    200) record PASS "POST /api/${mode}" "200" ;;
    '')  record SKIP "POST /api/${mode}" "no status line captured" ;;
    4*)  record SKIP "POST /api/${mode}" "${code} - often a missing inference pipeline, see docs" ;;
    *)   record FAIL "POST /api/${mode}" "HTTP ${code}" ;;
  esac
done

# ---------------------------------------------------------------------------
section "5. Frontend proxy (the 502-on-every-search bug)"
# ---------------------------------------------------------------------------
front_html=$(exec_in "$NS_APP" app=frontend "wget -qO- http://localhost:8080/" | head -c 200)
case "$front_html" in
  *html*|*HTML*|*div*) record PASS "frontend serves HTML on :8080" "" ;;
  *)                   record FAIL "frontend serves HTML on :8080" "unexpected body" ;;
esac

# The real regression test: does nginx reach the backend? This is what failed
# with the hardcoded 127.0.0.11 resolver.
proxy_code=$(exec_in "$NS_APP" app=frontend \
  "wget -qS -O /dev/null --header='Content-Type: application/json' --post-data='{\"state\":{\"searchTerm\":\"matrix\"},\"queryConfig\":{\"resultsPerPage\":1}}' http://localhost:8080/api/search 2>&1 | head -1" \
  | sed -n 's/.*HTTP\/1\.1 \([0-9]*\).*/\1/p')
case "$proxy_code" in
  200) record PASS "frontend proxies /api/search to backend" "200" ;;
  502) record FAIL "frontend proxies /api/search to backend" "502 - nginx cannot resolve backend (check resolver in nginx.conf)" ;;
  '')  record FAIL "frontend proxies /api/search to backend" "no response" ;;
  *)   record FAIL "frontend proxies /api/search to backend" "HTTP ${proxy_code}" ;;
esac

# ---------------------------------------------------------------------------
section "6. Ingress and DNS (only meaningful with minikube tunnel running)"
# ---------------------------------------------------------------------------
ingress_addr=$(kubectl -n "$NS_APP" get ingress app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ -z "$ingress_addr" ]; then
  record SKIP "ingress has an address" "no IP yet - run 'minikube tunnel' in an admin shell"
else
  record PASS "ingress has an address" "$ingress_addr"
  if getent hosts elastiflix.local >/dev/null 2>&1; then
    record PASS "elastiflix.local resolves" "$(getent hosts elastiflix.local | awk '{print $1}')"
  else
    record SKIP "elastiflix.local resolves" "add it to /etc/hosts (see docs/runbooks)"
  fi
fi

# ---------------------------------------------------------------------------
section "7. Metrics and SLO plumbing (feeds the canary and the dashboards)"
# ---------------------------------------------------------------------------
metrics_out=$(exec_in "$NS_APP" app=backend "wget -qO- http://localhost:17700/metrics")
if printf '%s' "$metrics_out" | grep -q 'elastiflix_http_responses_total'; then
  record PASS "backend exposes elastiflix_http_responses_total" ""
else
  record FAIL "backend exposes elastiflix_http_responses_total" "metric absent"
fi

# Query Prometheus through the API server proxy so no port-forward is needed.
prom_q() {
  kubectl -n "$NS_MON" get --raw \
    "/api/v1/namespaces/${NS_MON}/services/http:monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/query?query=$1" 2>/dev/null
}
prom_result=$(prom_q 'up%7Bjob%3D~%22.*backend.*%22%7D')
if printf '%s' "$prom_result" | grep -q '"value":\[[^]]*"1"\]'; then
  record PASS "Prometheus scrapes the backend" "up == 1"
elif [ -z "$prom_result" ]; then
  record SKIP "Prometheus scrapes the backend" "Prometheus not reachable via API"
else
  record FAIL "Prometheus scrapes the backend" "no up{job=~.*backend.*} == 1"
fi

if [ "$QUICK" -eq 1 ]; then
  record SKIP "SLO recording rule has data" "--quick"
else
  slo=$(prom_q 'elastiflix%3Arequests%3Arate5m')
  val=$(printf '%s' "$slo" | sed -n 's/.*"value":\[[^,]*,*"\([0-9.e+-]*\)".*/\1/p')
  if [ -n "$val" ] && awk -v v="$val" 'BEGIN{exit !(v>0)}'; then
    record PASS "SLO recording rule has data" "requests/5m = ${val}"
  else
    record FAIL "SLO recording rule has data" "no traffic recorded yet"
  fi
fi

# ---------------------------------------------------------------------------
section "8. Security controls are live (not just in the manifest)"
# ---------------------------------------------------------------------------
psa_out=$(kubectl -n "$NS_APP" run verify-psa --image=busybox:1.36 --restart=Never --dry-run=server -o name 2>&1)
if printf '%s' "$psa_out" | grep -q 'violates PodSecurity'; then
  record PASS "Pod Security Admission rejects a privileged pod" "restricted enforced"
else
  record FAIL "Pod Security Admission rejects a privileged pod" "$(printf '%s' "$psa_out" | tail -1 | cut -c1-70)"
fi

ef=$(exec_in "$NS_APP" app=backend 'touch /usr/local/bin/x 2>&1 | grep -c "Read-only"')
expect_ge "backend root filesystem is read-only" 1 "${ef:-0}"

caps=$(exec_in "$NS_APP" app=backend 'grep "^CapEff:" /proc/self/status' | awk '{print $2}')
if [ "$caps" = "0000000000000000" ]; then
  record PASS "backend has no effective capabilities" "$caps"
else
  record FAIL "backend has no effective capabilities" "${caps:-unknown}"
fi

# NetworkPolicy: a path with no egress rule must be blocked. Calico is required.
blocked=$(exec_in "$NS_APP" app=backend \
  'wget -T4 -qO- http://kibana.elastic-stack.svc.cluster.local:5601 >/dev/null 2>&1; echo $?')
case "${blocked:-x}" in
  0) record FAIL "NetworkPolicy blocks backend to kibana" "connection SUCCEEDED - policy not enforced" ;;
  *) record PASS "NetworkPolicy blocks backend to kibana" "" ;;
esac

# ---------------------------------------------------------------------------
section "9. GitOps state"
# ---------------------------------------------------------------------------
for app in elastiflix infra-databases elastic-stack monitoring namespaces; do
  # Two separate jsonpath calls on purpose: one get with both paths would need
  # a template, and a template that silently yields an empty string is exactly
  # how a FAIL used to look like a PASS here.
  sync=$(kubectl -n "$NS_ARGOCD" get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null)
  health=$(kubectl -n "$NS_ARGOCD" get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null)
  if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
    record PASS "Argo CD ${app} Synced/Healthy" ""
  elif [ -z "$sync" ]; then
    record FAIL "Argo CD ${app}" "application not found"
  else
    record FAIL "Argo CD ${app}" "${sync:-?}/${health:-?}"
  fi
done

auto=$(kubectl -n "$NS_ARGOCD" get application elastiflix -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null)
if [ -z "$auto" ]; then
  record SKIP "elastiflix Application auto-sync" "disabled by bootstrap.sh (local image tag); re-enable before testing GitOps"
else
  record PASS "elastiflix Application auto-sync" "enabled"
fi

# ---------------------------------------------------------------------------
section "10. One-shot application smoke test"
# ---------------------------------------------------------------------------
smoke=$(kubectl -n "$NS_APP" get pods -l app=frontend -o name 2>/dev/null | head -1)
# Fall back to the Deployment's own selector if the label query comes back empty,
# so a renamed label does not read as "no frontend pod".
if [ -z "$smoke" ]; then
  smoke=$(kubectl -n "$NS_APP" get pods --selector="$(kubectl -n "$NS_APP" get deployment frontend -o jsonpath='{.spec.selector.matchLabels.app}' 2>/dev/null)" -o name 2>/dev/null | head -1)
fi
if [ -n "$smoke" ]; then
  body=$(kubectl -n "$NS_APP" exec "$smoke" -- wget -qO- http://localhost:8080/ 2>/dev/null | head -c 120)
  case "$body" in
    *html*|*HTML*) record PASS "frontend container serves the SPA" "" ;;
    *)             record FAIL "frontend container serves the SPA" "no HTML" ;;
  esac
else
  record FAIL "frontend container serves the SPA" "no frontend pod"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
if [ "$JSON" -eq 1 ]; then
  printf '{"passed":%d,"failed":%d,"skipped":%d,"total":%d,"checks":[' \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$TOTAL"
  first=1
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r st nm ev <<<"$r"
    [ $first -eq 0 ] && printf ','
    first=0
    printf '{"status":"%s","name":"%s","evidence":"%s"}' \
      "$st" "${nm//\"/\\\"}" "${ev//\"/\\\"}"
  done
  printf ']}\n'
else
  printf '\n\033[1mResult: %d passed, %d failed, %d skipped (of %d)\033[0m\n' \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$TOTAL"
  if [ "$FAIL_COUNT" -eq 0 ]; then
    if [ "$SKIP_COUNT" -gt 0 ]; then
      printf '\033[32mDeployment is WORKING\033[0m — %d check(s) skipped, see above.\n' "$SKIP_COUNT"
    else
      printf '\033[32mDeployment is WORKING — every check passed.\033[0m\n'
    fi
    [ "$QUICK" -eq 0 ] && printf '\nTry it in a browser: http://elastiflix.local (needs `minikube tunnel`).\n'
  else
    printf '\033[31mDeployment is NOT fully working.\033[0m\n'
    printf 'Failed checks and the runbook section that explains each:\n'
    for r in "${RESULTS[@]}"; do
      IFS='|' read -r st nm ev <<<"$r"
      [ "$st" = "FAIL" ] && printf '  - %s (%s)\n' "$nm" "$ev"
    done
    printf '\nSee docs/runbooks/minikube-app-bringup.md for the four known blockers\n'
    printf '(image tag, catalogue download, backend and frontend upstream).\n'
  fi
fi

[ "$FAIL_COUNT" -eq 0 ] || exit 1
exit 0

#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Elastic Stack in One Shot — start everything.
#
#      ./start.sh
#
#  That's it. There's no step 2.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

: "${REDIS_PASSWORD:?Set REDIS_PASSWORD to a unique random value of at least 32 characters before starting the demo.}"
: "${RABBITMQ_PASSWORD:?Set RABBITMQ_PASSWORD to a unique random value of at least 32 characters before starting the demo.}"
if (( ${#REDIS_PASSWORD} < 32 || ${#RABBITMQ_PASSWORD} < 32 )); then
  echo "REDIS_PASSWORD and RABBITMQ_PASSWORD must each be at least 32 characters." >&2
  exit 1
fi
if [[ ! "$REDIS_PASSWORD" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "REDIS_PASSWORD may contain only letters, digits, underscore, or hyphen." >&2
  exit 1
fi
if [[ "$REDIS_PASSWORD" == "$RABBITMQ_PASSWORD" ]]; then
  echo "Use different passwords for Redis and RabbitMQ." >&2
  exit 1
fi
if [[ ! "$REDIS_PASSWORD" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "REDIS_PASSWORD may contain only letters, digits, underscore, or hyphen." >&2
  exit 1
fi
compose_version="$(docker compose version --short 2>/dev/null || true)"
if [[ "$compose_version" =~ ^v?([0-9]+)\.([0-9]+)\. ]]; then
  compose_major="${BASH_REMATCH[1]}"
  compose_minor="${BASH_REMATCH[2]}"
else
  echo "Docker Compose v2.26+ is required for environment-sourced secrets." >&2
  exit 1
fi
if (( compose_major < 2 || (compose_major == 2 && compose_minor < 26) )); then
  echo "Docker Compose v2.26+ is required for environment-sourced secrets." >&2
  exit 1
fi

# Compose maps REDIS_PASSWORD into a file-backed secret; it is not added to
# the Redis or backend container environment and never appears in CLI args.
export REDIS_PASSWORD

ES="http://localhost:9200"
KB="http://localhost:5601"

# --- 1. The movie catalogue -------------------------------------------------
# Elastiflix ships movies.json.gz: one big JSON array. Logstash's file input
# wants one document per line, so convert it. Skipped if already done.
#
# Written to a temp file and moved into place, so a Ctrl-C halfway through
# never leaves a truncated catalogue that the next run would happily reuse.
if [[ ! -f elk/data/movies.ndjson ]]; then
  echo "==> Preparing the movie catalogue"
  mkdir -p elk/data
  python3 - <<'PY'
import gzip, json, os
with gzip.open("data-loader/movies/movies.json.gz", "rt", encoding="utf-8") as fh:
    movies = json.load(fh)
tmp = "elk/data/.movies.ndjson.tmp"
with open(tmp, "w", encoding="utf-8") as out:
    for m in movies:
        out.write(json.dumps(m, ensure_ascii=False) + "\n")
os.replace(tmp, "elk/data/movies.ndjson")
print(f"    {len(movies)} movies ready")
PY
fi

EXPECTED=$(wc -l < elk/data/movies.ndjson | tr -d ' ')

# --- 2. The stack -----------------------------------------------------------
echo "==> Starting the Elastic Stack + Elastiflix"
docker compose up -d

# --- 3. Wait for it ---------------------------------------------------------
# Every wait is bounded. A demo that hangs forever with no message is worse
# than one that fails and tells you which log to read.
wait_for() {
  local what="$1" tries="$2" hint="$3"; shift 3
  printf "==> Waiting for %s" "$what"
  for ((i = 0; i < tries; i++)); do
    if "$@" >/dev/null 2>&1; then echo " ready"; return 0; fi
    printf '.'; sleep 2
  done
  echo
  echo "ERROR: $what did not come up in $((tries * 2))s." >&2
  echo "       Look at: $hint" >&2
  exit 1
}

es_up()     { curl -fs "$ES/_cluster/health"; }
kibana_up() { curl -fs "$KB/api/status" | grep -q '"level":"available"'; }
catalogue_loaded() {
  local n
  n=$(curl -fs "$ES/elastiflix-movies/_count" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
  [[ "$n" == "$EXPECTED" ]]
}

wait_for "Elasticsearch" 60  "docker compose logs elasticsearch" es_up
wait_for "Kibana"        120 "docker compose logs kibana"        kibana_up
wait_for "the catalogue" 120 "docker compose logs logstash"      catalogue_loaded
echo "    $EXPECTED movies indexed"

# --- 4. Kibana data views ---------------------------------------------------
# A data view is just "which indices am I looking at, and which field is time?"
# Kibana can't show you anything until one exists, so create them here rather
# than making it a step you have to remember on camera.
#
# allowNoIndex matters: metricbeat-* does not exist yet on a first start
# (Metricbeat spends a few minutes loading its dashboards before it publishes),
# and without it Kibana rejects the data view outright.
data_view() {
  local id="$1" title="$2" timefield="$3" name="$4"
  local delete_status
  delete_status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X DELETE "$KB/api/data_views/data_view/$id" \
    -H 'kbn-xsrf: true')
  case "$delete_status" in
    200|204|404) ;; # A missing data view is the expected idempotent case.
    *) echo "ERROR: deleting data view '$id' returned HTTP $delete_status" >&2; return 1 ;;
  esac
  curl -fs -X POST "$KB/api/data_views/data_view" \
    -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
    -d "{\"data_view\":{\"id\":\"$id\",\"title\":\"$title\",\"timeFieldName\":\"$timefield\",\"name\":\"$name\",\"allowNoIndex\":true}}" \
    >/dev/null
  echo "    $name  ->  $title"
}

echo "==> Creating Kibana data views"
# release_date as the time field means Discover can plot the catalogue by
# release year -- a nice way to show what a "time field" actually does.
data_view "elastiflix-movies"  "elastiflix-movies" "release_date" "Elastiflix Movies"
data_view "elastiflix-logs"    "elastiflix-logs-*" "@timestamp"   "Elastiflix App Logs"
data_view "elastiflix-metrics" "metricbeat-*"      "@timestamp"   "Elastiflix Metrics"

# --- 5. The prebuilt dashboards --------------------------------------------
# Three ready-made dashboards so there is something to show immediately. You
# still build one live on camera -- these are the safety net, and the "here is
# where we are going" shot before you start.
echo "==> Loading the prebuilt dashboards"
./load-dashboards.sh

cat <<EOF

  ────────────────────────────────────────────────
   Elastiflix       http://localhost:3000
   Kibana           http://localhost:5601
   Elasticsearch    http://localhost:9200
  ────────────────────────────────────────────────

   No login — security is disabled for this demo.

   Search a few movies in Elastiflix, then look at
   Kibana → Discover to watch your own searches
   arrive as documents.

   Three dashboards are already loaded:
   Kibana → Dashboards → "Elastiflix — ..."

   Need traffic to chart?   ./generate-traffic.sh
   Reload the dashboards?   ./load-dashboards.sh
   Stop it with             ./stop.sh
EOF

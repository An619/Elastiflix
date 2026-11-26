#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/scripts/elasticsearch-snapshot.sh"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/bin"
printf 'test-api-key\n' > "$TEMP_DIR/api-key"
printf 'test CA\n' > "$TEMP_DIR/ca.crt"
: > "$TEMP_DIR/curl.log"

cat > "$TEMP_DIR/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
method=GET
url=
body=
write_out=
previous=
for arg in "$@"; do
  case "$previous" in
    --request) method=$arg ;;
    --url) url=$arg ;;
    --data-binary) body=$arg ;;
    --write-out) write_out=$arg ;;
    --header)
      if [[ "$arg" == @* ]] && grep -Fq "Authorization: ApiKey test-api-key" "${arg#@}"; then
        printf 'auth-header=loaded\n' >> "$CURL_CAPTURE"
      fi
      ;;
  esac
  if [[ "$arg" == --request || "$arg" == --url || "$arg" == --data-binary || "$arg" == --write-out || "$arg" == --header ]]; then
    previous=$arg
  else
    previous=
  fi
done
printf 'request=%s %s\n' "$method" "$url" >> "$CURL_CAPTURE"
[[ -z "$body" ]] || printf 'body=%s\n' "$body" >> "$CURL_CAPTURE"
if [[ "$url" == */_status ]]; then
  printf '%s\n' "${MOCK_SNAPSHOT_STATUS:-{\"snapshots\":[{\"state\":\"SUCCESS\"}]}}"
elif [[ "$write_out" == '%{http_code}' ]]; then
  printf '%s' "${MOCK_INDEX_STATUS:-404}"
else
  printf '%s\n' '{"acknowledged":true,"accepted":true}'
fi
MOCK_CURL
chmod +x "$TEMP_DIR/bin/curl"

run_script() {
  env \
    PATH="$TEMP_DIR/bin:$PATH" \
    CURL_CAPTURE="$TEMP_DIR/curl.log" \
    ES_URL="https://elasticsearch.example.test:9200" \
    ES_API_KEY_FILE="$TEMP_DIR/api-key" \
    ES_CA_FILE="$TEMP_DIR/ca.crt" \
    "$SCRIPT" "$@"
}

assert_contains() {
  grep -Fq -- "$1" "$2" || { printf 'Expected to find %s in %s\n' "$1" "$2" >&2; exit 1; }
}

: > "$TEMP_DIR/curl.log"
SNAPSHOT_BUCKET=elastiflix-dr-test AWS_REGION=us-east-2 SNAPSHOT_BASE_PATH=elastiflix/test run_script register >/dev/null
assert_contains 'auth-header=loaded' "$TEMP_DIR/curl.log"
assert_contains 'PUT https://elasticsearch.example.test:9200/_snapshot/elastiflix-s3' "$TEMP_DIR/curl.log"
assert_contains '"bucket":"elastiflix-dr-test"' "$TEMP_DIR/curl.log"
if grep -Fq 'test-api-key' "$TEMP_DIR/curl.log"; then
  echo 'API key leaked into curl arguments or request body' >&2
  exit 1
fi

: > "$TEMP_DIR/curl.log"
run_script apply-policy >/dev/null
assert_contains 'PUT https://elasticsearch.example.test:9200/_slm/policy/elastiflix-daily' "$TEMP_DIR/curl.log"
assert_contains '"schedule":"0 30 2 * * ?"' "$TEMP_DIR/curl.log"
assert_contains '"expire_after":"30d","min_count":7,"max_count":35' "$TEMP_DIR/curl.log"

: > "$TEMP_DIR/curl.log"
if run_script restore elastiflix-manual-test >"$TEMP_DIR/out" 2>"$TEMP_DIR/err"; then
  echo 'Restore without explicit confirmation unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'set CONFIRM_RESTORE=' "$TEMP_DIR/err"
[[ ! -s "$TEMP_DIR/curl.log" ]] || { echo 'Unconfirmed restore made an HTTP request' >&2; exit 1; }

: > "$TEMP_DIR/curl.log"
if env CONFIRM_RESTORE='RESTORE elastiflix-movies into elastiflix-movies from elastiflix-manual-test' MOCK_INDEX_STATUS=200 \
  PATH="$TEMP_DIR/bin:$PATH" CURL_CAPTURE="$TEMP_DIR/curl.log" \
  ES_URL="https://elasticsearch.example.test:9200" ES_API_KEY_FILE="$TEMP_DIR/api-key" ES_CA_FILE="$TEMP_DIR/ca.crt" \
  "$SCRIPT" restore elastiflix-manual-test >"$TEMP_DIR/out" 2>"$TEMP_DIR/err"; then
  echo 'Restore over an existing index unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'target index already exists' "$TEMP_DIR/err"

: > "$TEMP_DIR/curl.log"
if env CONFIRM_RESTORE='RESTORE elastiflix-movies into elastiflix-movies from elastiflix-manual-test' \
  MOCK_SNAPSHOT_STATUS='{"snapshots":[{"state":"FAILED"}]}' \
  PATH="$TEMP_DIR/bin:$PATH" CURL_CAPTURE="$TEMP_DIR/curl.log" \
  ES_URL="https://elasticsearch.example.test:9200" ES_API_KEY_FILE="$TEMP_DIR/api-key" ES_CA_FILE="$TEMP_DIR/ca.crt" \
  "$SCRIPT" restore elastiflix-manual-test >"$TEMP_DIR/out" 2>"$TEMP_DIR/err"; then
  echo 'Restore from an unsuccessful snapshot unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'snapshot is not marked SUCCESS' "$TEMP_DIR/err"
if grep -Fq '/_restore?wait_for_completion=true' "$TEMP_DIR/curl.log"; then
  echo 'Unsuccessful snapshot triggered a restore request' >&2
  exit 1
fi

: > "$TEMP_DIR/curl.log"
env CONFIRM_RESTORE='RESTORE elastiflix-movies into elastiflix-movies-dr-test from elastiflix-manual-test' \
  RESTORE_TARGET_INDEX=elastiflix-movies-dr-test \
  PATH="$TEMP_DIR/bin:$PATH" CURL_CAPTURE="$TEMP_DIR/curl.log" \
  ES_URL="https://elasticsearch.example.test:9200" ES_API_KEY_FILE="$TEMP_DIR/api-key" ES_CA_FILE="$TEMP_DIR/ca.crt" \
  "$SCRIPT" restore elastiflix-manual-test >"$TEMP_DIR/out"
assert_contains 'POST https://elasticsearch.example.test:9200/_snapshot/elastiflix-s3/elastiflix-manual-test/_restore?wait_for_completion=true' "$TEMP_DIR/curl.log"
assert_contains 'include_global_state":false' "$TEMP_DIR/curl.log"
assert_contains '"rename_replacement":"elastiflix-movies-dr-test"' "$TEMP_DIR/curl.log"
assert_contains 'Restore request completed' "$TEMP_DIR/out"

echo 'Elasticsearch snapshot script tests passed (mocked HTTP; no cluster or AWS calls).'

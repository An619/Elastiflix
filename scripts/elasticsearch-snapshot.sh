#!/usr/bin/env bash
# Manage Elasticsearch S3 snapshots through the authenticated REST API.
# This script does not provision AWS resources or delete/overwrite indices.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/elasticsearch-snapshot.sh COMMAND [SNAPSHOT]

Commands:
  register          Register the configured S3 repository (one-time setup)
  verify            Ask Elasticsearch to verify repository access
  apply-policy      Configure daily snapshots with bounded retention
  policy-status     Show SLM status and the configured policy
  snapshot [NAME]   Create and wait for a manual snapshot
  list              List snapshots in the repository
  restore SNAPSHOT  Restore the catalog only if the target index is absent

Required environment:
  ES_URL                 HTTPS URL for the Elasticsearch endpoint
  ES_API_KEY_FILE        File containing a least-privilege Elasticsearch API key
  ES_CA_FILE             Trusted CA certificate for Elasticsearch HTTPS

Required only for `register`:
  SNAPSHOT_BUCKET         Existing, approved S3 bucket
  AWS_REGION              Region containing the S3 bucket

Optional:
  SNAPSHOT_REPOSITORY     Default: elastiflix-s3
  SNAPSHOT_POLICY_ID      Default: elastiflix-daily
  SNAPSHOT_BASE_PATH      Default: elastiflix/<CLUSTER_ID>
  CLUSTER_ID              Default: elastiflix
  ES_INDEX                Default: elastiflix-movies
  RESTORE_TARGET_INDEX    Default: ES_INDEX; set a staging index for restore drills

Restore is deliberately guarded. Set CONFIRM_RESTORE to the exact phrase
"RESTORE <source-index> into <target-index> from <snapshot>". The script refuses to overwrite an index.
EOF
}

fail() {
  printf 'elasticsearch-snapshot: %s\n' "$*" >&2
  exit 1
}

command_name=${1:-}
[[ -n "$command_name" ]] || { usage >&2; exit 2; }
case "$command_name" in
  register|verify|apply-policy|policy-status|snapshot|list|restore) ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; fail "unknown command: $command_name" ;;
esac

ES_URL=${ES_URL:-}
ES_API_KEY_FILE=${ES_API_KEY_FILE:-/run/secrets/elasticsearch/snapshot-api-key}
ES_CA_FILE=${ES_CA_FILE:-/run/secrets/elasticsearch/ca.crt}
SNAPSHOT_REPOSITORY=${SNAPSHOT_REPOSITORY:-elastiflix-s3}
SNAPSHOT_POLICY_ID=${SNAPSHOT_POLICY_ID:-elastiflix-daily}
CLUSTER_ID=${CLUSTER_ID:-elastiflix}
ES_INDEX=${ES_INDEX:-elastiflix-movies}
RESTORE_TARGET_INDEX=${RESTORE_TARGET_INDEX:-$ES_INDEX}

[[ "$ES_URL" =~ ^https://[^[:space:]]+$ ]] || fail "ES_URL must be an HTTPS URL"
ES_URL=${ES_URL%/}
[[ -r "$ES_API_KEY_FILE" ]] || fail "API key file is not readable: $ES_API_KEY_FILE"
[[ -r "$ES_CA_FILE" ]] || fail "CA file is not readable: $ES_CA_FILE"
command -v curl >/dev/null 2>&1 || fail "curl is required"

for value in "$SNAPSHOT_REPOSITORY" "$SNAPSHOT_POLICY_ID" "$ES_INDEX" "$RESTORE_TARGET_INDEX" "$CLUSTER_ID"; do
  [[ "$value" =~ ^[a-zA-Z0-9._-]+$ ]] || fail "invalid repository, policy, index, or cluster identifier: $value"
done

api_key=$(tr -d '\r\n' < "$ES_API_KEY_FILE")
[[ "$api_key" =~ ^[A-Za-z0-9+/=_-]+$ ]] || fail "API key file must contain only one encoded API key"
unset api_key

umask 077
auth_header_file=$(mktemp)
trap 'rm -f "$auth_header_file"' EXIT
printf 'Authorization: ApiKey %s\n' "$(tr -d '\r\n' < "$ES_API_KEY_FILE")" > "$auth_header_file"

request() {
  local method=$1 path=$2 body=${3:-}
  local -a args=(
    --fail --silent --show-error
    --connect-timeout 10 --max-time "${CURL_MAX_TIME:-1800}"
    --cacert "$ES_CA_FILE"
    --header "@$auth_header_file"
    --header 'Accept: application/json'
    --request "$method"
    --url "${ES_URL}${path}"
  )
  if [[ -n "$body" ]]; then
    args+=(--header 'Content-Type: application/json' --data-binary "$body")
  fi
  curl "${args[@]}"
}

require_snapshot() {
  local snapshot=${1:-}
  [[ "$snapshot" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || fail "snapshot name must be 1-128 lowercase letters, digits, dots, underscores, or hyphens"
  printf '%s' "$snapshot"
}

case "$command_name" in
  register)
    SNAPSHOT_BUCKET=${SNAPSHOT_BUCKET:-}
    AWS_REGION=${AWS_REGION:-}
    [[ "$SNAPSHOT_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || fail "SNAPSHOT_BUCKET must be an existing valid S3 bucket name"
    [[ "$AWS_REGION" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] || fail "AWS_REGION must be an AWS region name"
    SNAPSHOT_BASE_PATH=${SNAPSHOT_BASE_PATH:-elastiflix/$CLUSTER_ID}
    [[ "$SNAPSHOT_BASE_PATH" =~ ^[A-Za-z0-9._/-]+$ && "$SNAPSHOT_BASE_PATH" != /* && "$SNAPSHOT_BASE_PATH" != *..* ]] || fail "SNAPSHOT_BASE_PATH must be a safe relative S3 prefix"
    body=$(cat <<JSON
{"type":"s3","settings":{"bucket":"$SNAPSHOT_BUCKET","region":"$AWS_REGION","base_path":"$SNAPSHOT_BASE_PATH"}}
JSON
)
    request PUT "/_snapshot/$SNAPSHOT_REPOSITORY" "$body"
    ;;
  verify)
    request POST "/_snapshot/$SNAPSHOT_REPOSITORY/_verify"
    ;;
  apply-policy)
    body=$(cat <<JSON
{"schedule":"0 30 2 * * ?","name":"<elastiflix-{now/d}>","repository":"$SNAPSHOT_REPOSITORY","config":{"indices":"$ES_INDEX","ignore_unavailable":false,"include_global_state":false,"partial":false},"retention":{"expire_after":"30d","min_count":7,"max_count":35}}
JSON
)
    request PUT "/_slm/policy/$SNAPSHOT_POLICY_ID" "$body"
    ;;
  policy-status)
    request GET "/_slm/status"
    printf '\n'
    request GET "/_slm/policy/$SNAPSHOT_POLICY_ID"
    ;;
  snapshot)
    snapshot=$(require_snapshot "${2:-elastiflix-manual-$(date -u +%Y%m%dT%H%M%SZ)}")
    body=$(cat <<JSON
{"indices":"$ES_INDEX","ignore_unavailable":false,"include_global_state":false,"partial":false}
JSON
)
    request PUT "/_snapshot/$SNAPSHOT_REPOSITORY/$snapshot?wait_for_completion=true" "$body"
    ;;
  list)
    request GET "/_snapshot/$SNAPSHOT_REPOSITORY/_all"
    ;;
  restore)
    snapshot=$(require_snapshot "${2:-}")
    expected="RESTORE $ES_INDEX into $RESTORE_TARGET_INDEX from $snapshot"
    [[ ${CONFIRM_RESTORE:-} == "$expected" ]] || fail "set CONFIRM_RESTORE='$expected' after reviewing the restore runbook"
    snapshot_status=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 --cacert "$ES_CA_FILE" --header "@$auth_header_file" --header 'Accept: application/json' --url "${ES_URL}/_snapshot/${SNAPSHOT_REPOSITORY}/${snapshot}/_status") || fail "could not read snapshot status"
    printf '%s' "$snapshot_status" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"SUCCESS"' || fail "snapshot is not marked SUCCESS; refusing restore"
    index_status=$(curl --silent --show-error --connect-timeout 10 --max-time 30 --cacert "$ES_CA_FILE" --header "@$auth_header_file" --output /dev/null --write-out '%{http_code}' --url "${ES_URL}/${RESTORE_TARGET_INDEX}") || fail "could not check target index"
    [[ "$index_status" == 404 ]] || fail "target index already exists or its state is unknown (HTTP $index_status); preserve it and perform a reviewed cutover"
    if [[ "$RESTORE_TARGET_INDEX" == "$ES_INDEX" ]]; then
      body=$(cat <<JSON
{"indices":"$ES_INDEX","ignore_unavailable":false,"include_global_state":false,"include_aliases":false}
JSON
)
    else
      body=$(cat <<JSON
{"indices":"$ES_INDEX","ignore_unavailable":false,"include_global_state":false,"include_aliases":false,"rename_pattern":"^$ES_INDEX$","rename_replacement":"$RESTORE_TARGET_INDEX"}
JSON
)
    fi
    request POST "/_snapshot/$SNAPSHOT_REPOSITORY/$snapshot/_restore?wait_for_completion=true" "$body"
    printf '\nRestore request completed. Verify index health, document count, mappings, and application reads before reopening writes.\n'
    ;;
esac

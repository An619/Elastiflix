#!/usr/bin/env bash
# Configure least-privilege Elasticsearch clients after TLS-enabled ES is up.
# This script mutates Elasticsearch users/API keys but never applies Kubernetes
# resources or provisions AWS resources. Run it only when an operator approves.
set -euo pipefail

secret_dir="${ELASTICSEARCH_SECRET_DIR:-.secrets/elasticsearch}"
es_url="${ELASTICSEARCH_URL:-https://localhost:9200}"
for command in curl jq; do
  command -v "$command" >/dev/null 2>&1 || { echo "Required command not found: $command" >&2; exit 127; }
done
for file in ca.crt elastic-password kibana-password; do
  [[ -r "$secret_dir/$file" ]] || { echo "Missing $secret_dir/$file; run scripts/prepare-elasticsearch-tls.sh first." >&2; exit 2; }
done

elastic_password="$(<"$secret_dir/elastic-password")"
kibana_password="$(<"$secret_dir/kibana-password")"
if [[ ! "$elastic_password" =~ ^[A-Fa-f0-9]{64}$ || ! "$kibana_password" =~ ^[A-Fa-f0-9]{64}$ ]]; then
  echo "Bootstrap passwords must be 64 hexadecimal characters; refusing to build API requests." >&2
  exit 2
fi

work_dir="$(mktemp -d)"
chmod 700 "$work_dir"
trap 'rm -rf "$work_dir"' EXIT
umask 077
cat > "$work_dir/curl.conf" <<EOF
user = "elastic:$elastic_password"
fail-with-body
silent
show-error
connect-timeout = 5
max-time = 30
EOF
chmod 600 "$work_dir/curl.conf"
ready=0
for _ in $(seq 1 60); do
  if curl --config "$work_dir/curl.conf" --cacert "$secret_dir/ca.crt" \
    "$es_url/" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 5
done
if (( ready == 0 )); then
  echo "Elasticsearch did not become reachable at $es_url with the prepared CA/credentials." >&2
  exit 1
fi

jq -n --rawfile password "$secret_dir/kibana-password" \
  '{password: ($password | rtrimstr("\n"))}' > "$work_dir/kibana-password.json"
curl --config "$work_dir/curl.conf" --cacert "$secret_dir/ca.crt" \
  --request PUT "$es_url/_security/user/kibana_system/_password" \
  --header 'Content-Type: application/json' \
  --data-binary "@$work_dir/kibana-password.json" >/dev/null

cat > "$work_dir/backend-role.json" <<'JSON'
{
  "cluster": ["monitor"],
  "indices": [
    {
      "names": ["elastiflix-movies"],
      "privileges": ["read", "view_index_metadata"]
    }
  ]
}
JSON
cat > "$work_dir/logstash-role.json" <<'JSON'
{
  "cluster": ["monitor", "manage_index_templates"],
  "indices": [
    {
      "names": ["elastiflix-movies", "elastiflix-logs-*"],
      "privileges": ["create_index", "manage", "write", "create_doc", "view_index_metadata"]
    }
  ]
}
JSON

create_api_key() {
  local name="$1" roles_file="$2" output_file="$3"
  jq -n --arg name "$name" --slurpfile role "$roles_file" \
    '{name: $name, role_descriptors: {($name): $role[0]}}' > "$work_dir/$name-request.json"
  curl --config "$work_dir/curl.conf" --cacert "$secret_dir/ca.crt" \
    --request POST "$es_url/_security/api_key" \
    --header 'Content-Type: application/json' \
    --data-binary "@$work_dir/$name-request.json" > "$work_dir/$name-response.json"
  jq -er '.encoded | select(type == "string" and length > 0)' \
    "$work_dir/$name-response.json" | tr -d '\n' > "$output_file"
  chmod 600 "$output_file"
}

create_api_key elastiflix-backend "$work_dir/backend-role.json" "$secret_dir/backend-api-key"
create_api_key elastiflix-logstash "$work_dir/logstash-role.json" "$secret_dir/logstash-api-key"

jq -n \
  --rawfile elastic_password "$secret_dir/elastic-password" \
  --rawfile kibana_password "$secret_dir/kibana-password" \
  --rawfile backend_api_key "$secret_dir/backend-api-key" \
  --rawfile logstash_api_key "$secret_dir/logstash-api-key" \
  '{"elastic-password":($elastic_password|rtrimstr("\n")),
    "kibana-password":($kibana_password|rtrimstr("\n")),
    "backend-api-key":($backend_api_key|rtrimstr("\n")),
    "logstash-api-key":($logstash_api_key|rtrimstr("\n"))}' \
  > "$secret_dir/elasticsearch-credentials.json"
jq -n \
  --rawfile ca_crt "$secret_dir/ca.crt" \
  --rawfile tls_crt "$secret_dir/tls.crt" \
  --rawfile tls_key "$secret_dir/tls.key" \
  '{ca_crt:$ca_crt, tls_crt:$tls_crt, tls_key:$tls_key}' \
  > "$secret_dir/elasticsearch-tls.json"
chmod 600 "$secret_dir"/{elasticsearch-credentials.json,elasticsearch-tls.json}
printf 'Elasticsearch users configured and least-privilege API keys written to %s.\n' "$secret_dir"
printf 'The API keys are not printed. Apply/store the generated secrets only through an approved local or AWS secret path.\n'

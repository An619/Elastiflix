#!/usr/bin/env bash
# Prepare local-development Elasticsearch TLS material only. This script does
# not contact or modify a Kubernetes cluster or AWS account.
set -euo pipefail

for command in openssl; do
  command -v "$command" >/dev/null 2>&1 || { echo "Required command not found: $command" >&2; exit 127; }
done

secret_dir="${1:-.secrets/elasticsearch}"
if [[ -e "$secret_dir/ca.crt" || -e "$secret_dir/tls.crt" || -e "$secret_dir/elastic-password" ]]; then
  echo "TLS or credential files already exist under $secret_dir; refusing to overwrite them." >&2
  exit 2
fi

umask 077
mkdir -p "$secret_dir"
chmod 700 "$secret_dir"

cat > "$secret_dir/ca-openssl.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = distinguished_name
x509_extensions = ca_extensions

[distinguished_name]
CN = Elastiflix local Elasticsearch CA

[ca_extensions]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF

cat > "$secret_dir/server-openssl.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = distinguished_name
req_extensions = server_extensions

[distinguished_name]
CN = elasticsearch

[server_extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
subjectAltName = @alternate_names

[alternate_names]
DNS.1 = elasticsearch
DNS.2 = elasticsearch.elastic-stack
DNS.3 = elasticsearch.elastic-stack.svc
DNS.4 = elasticsearch.elastic-stack.svc.cluster.local
DNS.5 = localhost
IP.1 = 127.0.0.1
EOF

openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 365 \
  -config "$secret_dir/ca-openssl.cnf" -extensions ca_extensions \
  -keyout "$secret_dir/ca.key" -out "$secret_dir/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -sha256 \
  -config "$secret_dir/server-openssl.cnf" \
  -keyout "$secret_dir/tls.key" -out "$secret_dir/tls.csr" >/dev/null 2>&1
openssl x509 -req -sha256 -days 365 \
  -in "$secret_dir/tls.csr" \
  -CA "$secret_dir/ca.crt" -CAkey "$secret_dir/ca.key" -CAcreateserial \
  -out "$secret_dir/tls.crt" \
  -extfile "$secret_dir/server-openssl.cnf" -extensions server_extensions >/dev/null 2>&1

openssl rand -hex 32 | tr -d '\n' > "$secret_dir/elastic-password"
openssl rand -hex 32 | tr -d '\n' > "$secret_dir/kibana-password"
chmod 600 "$secret_dir"/{ca.key,ca.crt,tls.key,tls.crt,elastic-password,kibana-password}
printf 'Prepared private Elasticsearch TLS and bootstrap credentials in %s.\n' "$secret_dir"
printf 'No cluster or AWS resources were changed. Keep this directory out of Git and back it up securely.\n'

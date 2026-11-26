#!/usr/bin/env bash
# Apply locally generated Elasticsearch credentials/certificates to Minikube.
# This mutates Kubernetes Secrets; never execute without operator approval.
set -euo pipefail

: "${KUBE_CONTEXT:?Set KUBE_CONTEXT to the reviewed Minikube context name.}"
: "${REDIS_PASSWORD_FILE:?Set REDIS_PASSWORD_FILE to the private file used during local bootstrap.}"
: "${RABBITMQ_PASSWORD_FILE:?Set RABBITMQ_PASSWORD_FILE to the private file used during local bootstrap.}"
[[ -r "$REDIS_PASSWORD_FILE" && -r "$RABBITMQ_PASSWORD_FILE" ]] || { echo "Password files are not readable." >&2; exit 2; }
redis_password="$(<"$REDIS_PASSWORD_FILE")"
rabbitmq_password="$(<"$RABBITMQ_PASSWORD_FILE")"
current_context="$(kubectl config current-context)"
if [[ "$current_context" != "$KUBE_CONTEXT" ]]; then
  echo "Refusing to mutate context '$current_context'; expected '$KUBE_CONTEXT'." >&2
  exit 2
fi
if (( ${#redis_password} < 32 || ${#rabbitmq_password} < 32 )) || [[ "$redis_password" == "$rabbitmq_password" ]]; then
  echo "Redis and RabbitMQ passwords must be distinct and at least 32 characters." >&2
  exit 2
fi
secret_dir="${ELASTICSEARCH_SECRET_DIR:-.secrets/elasticsearch}"
for file in elastic-password kibana-password backend-api-key logstash-api-key ca.crt tls.crt tls.key; do
  [[ -r "$secret_dir/$file" ]] || { echo "Missing $secret_dir/$file; prepare TLS and run configure-elasticsearch-security.sh first." >&2; exit 2; }
done

umask 077
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
cp -- "$REDIS_PASSWORD_FILE" "$tmp_dir/redis-password"
cp -- "$RABBITMQ_PASSWORD_FILE" "$tmp_dir/rabbitmq-password"
chmod 600 "$tmp_dir"/*

kubectl create secret generic elasticsearch-bootstrap \
  --namespace elastic-stack \
  --from-file=elastic-password="$secret_dir/elastic-password" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic elasticsearch-tls \
  --namespace elastic-stack \
  --from-file=ca.crt="$secret_dir/ca.crt" \
  --from-file=tls.crt="$secret_dir/tls.crt" \
  --from-file=tls.key="$secret_dir/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic elasticsearch-security \
  --namespace elastic-stack \
  --from-file=kibana-password="$secret_dir/kibana-password" \
  --from-file=logstash-api-key="$secret_dir/logstash-api-key" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic backend-secret \
  --namespace elastiflix \
  --from-file=redis-password="$tmp_dir/redis-password" \
  --from-file=rabbitmq-password="$tmp_dir/rabbitmq-password" \
  --from-file=es-api-key="$secret_dir/backend-api-key" \
  --from-file=es-ca.crt="$secret_dir/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -
printf 'Local Elasticsearch Secrets applied to the explicitly selected context. Secret values were not printed.\n'

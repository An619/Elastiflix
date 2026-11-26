# Phase 3: Manual cluster validation runbook

This runbook is for the operator-approved runtime phase. **Nothing in this document has been run against a cluster from this workspace.** The read-only report script does not modify cluster state; the optional tests below may create short-lived diagnostic workloads and should only be run after the operator selects and approves the target cluster.

## 1. Confirm the target and collect a baseline

From the repository root, use an operator shell with a reviewed kubeconfig:

```bash
kubectl config current-context
bash scripts/phase3-cluster-report.sh
```

The report lists nodes, Metrics API availability, HPAs/PDBs, workload readiness, NetworkPolicies, ingress, External Secrets status, and Prometheus CRs. It does not output Secret data. Stop if the displayed context is not the intended cluster.

## 2. HPA, PDB, and scheduling

On Minikube, enable or install metrics-server before testing. Confirm metrics are served and the app resources are ready:

```bash
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes
kubectl get hpa,pdb -n elastiflix
kubectl describe hpa -n elastiflix
kubectl get pods -n elastiflix -o wide
```

Generate controlled load using an approved test client, observe the HPA target and replica changes, then stop the load and observe scale-down. Do not treat a configured HPA as validated until both scaling directions are observed. Confirm PDB `ALLOWED DISRUPTIONS` and test voluntary eviction only in a non-production cluster with a rollback plan.

## 3. NetworkPolicy/CNI behavior

First verify the cluster CNI supports and has NetworkPolicy enforcement enabled. Listing NetworkPolicy objects alone does not prove enforcement. In a disposable test namespace/cluster, test at least:

- allowed frontend-to-backend API traffic;
- allowed backend-to-Elasticsearch, Redis, and RabbitMQ traffic;
- Prometheus-to-backend `/metrics` and RabbitMQ metrics scrapes;
- denied traffic from an unrelated namespace to app, infra, Elastic Stack, and monitoring pods;
- required DNS and Filebeat-to-Logstash traffic.

Use temporary diagnostic pods with a reviewed image and explicit cleanup. Record the source pod/namespace, destination Service, port, and observed result. Do not run broad egress tests against production workloads.

## 4. Prometheus, Redis, RabbitMQ, and alerts

Confirm CRDs and target discovery, then inspect endpoint status in Prometheus:

```bash
kubectl get servicemonitors,prometheusrules -n monitoring
kubectl get svc redis rabbitmq -n infra -o wide
kubectl get networkpolicy -n infra
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
```

In Prometheus, verify targets for the backend and RabbitMQ are `UP`, and query:

```promql
elastiflix_redis_up
elastiflix_redis_memory_used_bytes
elastiflix_redis_connected_clients
rabbitmq_queue_messages
rabbitmq_connections
```

Open the Grafana infrastructure dashboard using the documented port-forward and confirm series have recent samples. Check PrometheusRule evaluation for Redis/RabbitMQ/backend alerts. Alertmanager is intentionally disabled until an owner supplies and approves a receiver; rule evaluation is not notification delivery.

## 5. Filebeat and Elastic Stack

Check Filebeat's mount and delivery on the target node runtime, then inspect its logs and Logstash readiness:

```bash
kubectl get ds/filebeat -n elastic-stack -o wide
kubectl logs -n elastic-stack ds/filebeat --tail=100
kubectl get pods,svc -n elastic-stack -o wide
```

Confirm container logs arrive in Elasticsearch and Kibana. Elasticsearch HTTP and transport TLS, authenticated health probes, Kibana's `kibana_system` account, and separate least-privilege backend/Logstash API keys are configured. For an operator-approved local setup, `bootstrap.sh` invokes the local TLS/security preparation scripts; the standalone scripts are `scripts/prepare-elasticsearch-tls.sh`, `scripts/configure-elasticsearch-security.sh`, and (for an already prepared cluster) `scripts/apply-local-elasticsearch-secrets.sh`. The security-configuration script creates users/API keys and therefore mutates Elasticsearch; run it only against the intended local endpoint after approval. Do not copy generated private keys or credentials into Git. Before any production use, validate TLS trust, Elastic 9.1/Logstash plugin compatibility, probe behavior, role privileges, and recovery/rotation procedures on Minikube. AWS ESO expects Secrets Manager records `elastiflix/elasticsearch` and `elastiflix/elasticsearch-tls` with the property names defined in `kubernetes/aws/secrets/eso.yaml`; populate those through the approved AWS secret-management process, not this local script.

## 6. AWS-only ingress and External Secrets

Before enabling AWS ingress, the operator must supply an approved ACM certificate ARN and DNS hostname. Add them to `kubernetes/aws/ingress-aws.yaml`, verify the DNS record and ALB subnet/security-group assumptions, and review the plan/change request. Only then, with explicit approval, register the Application:

```bash
kubectl apply -f kubernetes/argocd-aws-ingress.yaml
```

For ESO, verify the IRSA trust relationship and AWS region, then check only object status/conditions (never print Secret values):

```bash
kubectl get clustersecretstore aws-secretsmanager -o yaml
kubectl get externalsecrets -A
kubectl describe externalsecret -n infra redis-secret
kubectl describe externalsecret -n infra rabbitmq-secret
```

Do not apply AWS manifests or provision AWS resources as part of this validation runbook without separate operator approval.

## Evidence to record

Record the selected cluster/context, CNI and version, metrics-server status, HPA scale-up/scale-down observations, PDB disruption status, allowed and denied network flows, backend/Redis/RabbitMQ scrape status, Filebeat delivery status, ESO sync conditions, and any deviations. Redact hostnames, account IDs, Secret names where sensitive, and all credentials before sharing the report.

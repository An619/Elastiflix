# Phase 6: Backup, restore, and disaster recovery

## Scope and status

This phase adds an operator-run Elasticsearch snapshot client, an Elasticsearch SLM schedule, mocked safety tests, and recovery procedures. It is repository configuration only: no S3 bucket, IAM role, Elasticsearch repository, snapshot, or restore was created or called from this workspace. Backups are **not active** until an operator supplies an approved S3 destination and identity, registers the repository, applies the SLM policy, and verifies a real snapshot.

## Recovery objectives (proposed; not an SLA)

| Data/service | Proposed RPO | Proposed RTO | Recovery approach and caveat |
|---|---:|---:|---|
| Elasticsearch movie catalog (`elastiflix-movies`) | 24 hours | 4 hours | Daily SLM snapshot to an approved S3 repository; restore into an empty index or isolated cluster. Targets require a successful scheduled snapshot and a restore drill on representative data. |
| Terraform remote state | 24 hours | 4 hours | Existing state-bucket versioning and DynamoDB point-in-time recovery provide rollback/recovery controls. The bootstrap root has local state that must be protected separately. These are same-region controls, not a regional failover design. |
| Redis cache | No data RPO | 1 hour | Recreate as a cache; do not treat cache contents as authoritative. |
| RabbitMQ search events | Best effort | 4 hours | Recreate the broker. Historical search events may be lost; this phase does not define those events as system-of-record data. |
| Grafana dashboards, Prometheus rules, Kubernetes/Terraform/Ansible configuration | Git commit RPO | 4 hours | Reapply reviewed configuration after dependencies are restored. Prometheus time-series data and Elasticsearch/Kibana logs are not backed up by this catalog policy. |

The RPO/RTO values are planning targets for the current small, single-node demo deployment, not measured performance or production commitments. Production owners must approve objectives and demonstrate them in a representative recovery exercise before relying on them.

## Elasticsearch snapshot design

- Use Elasticsearch Snapshot Lifecycle Management (SLM), not copies of the live data PVC. The schedule is daily at **02:30 UTC**, with a **30-day** expiration, at least **7** retained snapshots, and a maximum of **35**. Only `elastiflix-movies` is included; global cluster state is excluded.
- Store snapshots in an **existing, approved, dedicated S3 bucket** in the selected AWS region and under a cluster-specific prefix. Do not reuse the Terraform-state bucket. Require bucket-level public-access blocks, TLS-only access, server-side encryption, versioning, access logging, and an approved retention/access policy. If SSE-KMS is used, the Elasticsearch identity and KMS key policy must allow only the necessary operations.
- Elasticsearch nodes need the S3 snapshot repository module/plugin and an AWS identity that can access only the approved bucket prefix. Prefer EKS IRSA or the platform's approved workload identity; do not put static AWS access keys in manifests. The S3 repository client is registered through the Elasticsearch API. Minikube/local environments need their own explicitly approved credential path and must not reuse production credentials.
- Use a dedicated Elasticsearch API key stored in an operator-managed secret file. Do not use the `elastic` superuser or reuse the application's read/search API key. Grant only the repository/SLM/snapshot permissions needed for the selected operation; retention requires snapshot deletion permission scoped to the repository.
- S3 versioning is an additional recovery layer, not a substitute for Elasticsearch snapshot APIs. Do not attach an S3 lifecycle rule that expires snapshot objects independently: SLM must remove complete snapshots coherently.
- Cross-region replication is **not configured**. Same-region snapshots do not protect against a regional outage or loss of the AWS account. Select and fund a second region, destination bucket, KMS key, replication role, and retention policy before claiming regional disaster recovery; Terraform state replication remains an owner-approved follow-up.

## Operator procedure: enable snapshots

Prerequisites: an approved S3 bucket and prefix, compatible S3 repository support on every Elasticsearch node, an AWS workload identity scoped to that prefix, a dedicated snapshot API key, network access to Elasticsearch, and the trusted CA certificate. Check these before registering anything. Keep credentials out of command-line arguments, shell history, logs, Git, and chat.

Set `ES_URL`, `ES_CA_FILE`, and `ES_API_KEY_FILE` in the operator's secured environment. The API key file must contain only the key; the script reads it into a mode-0600 temporary curl header file and removes that file on exit. The script requires HTTPS and a CA file.

```bash
# Register the already-approved bucket; this changes Elasticsearch repository configuration.
SNAPSHOT_BUCKET='<approved-bucket>' \
AWS_REGION='<bucket-region>' \
SNAPSHOT_BASE_PATH='elastiflix/<cluster-id>' \
scripts/elasticsearch-snapshot.sh register

# Confirm the Elasticsearch nodes can access S3, then enable the daily SLM policy.
scripts/elasticsearch-snapshot.sh verify
scripts/elasticsearch-snapshot.sh apply-policy
scripts/elasticsearch-snapshot.sh policy-status

# Optional manual snapshot before a maintenance or restore exercise.
scripts/elasticsearch-snapshot.sh snapshot
scripts/elasticsearch-snapshot.sh list
```

These commands are deliberately **not** run by CI, Argo CD, Ansible bootstrap, or this workspace. `register` and `apply-policy` mutate Elasticsearch configuration and require the normal change approval. Inspect the policy and confirm a successful snapshot before treating backups as operational.

## Restore and drill procedure

1. Start with an isolated, empty Elasticsearch cluster for a drill. Confirm the S3 repository is registered and verified, TLS trust works, the snapshot is listed, and its state is `SUCCESS`.
2. Restore the catalog to a **staging index** first. This tests readability without replacing the live index:

   ```bash
   RESTORE_TARGET_INDEX='elastiflix-movies-dr-test' \
   CONFIRM_RESTORE='RESTORE elastiflix-movies into elastiflix-movies-dr-test from <snapshot-name>' \
   scripts/elasticsearch-snapshot.sh restore '<snapshot-name>'
   ```

   Replace `<snapshot-name>` with a real name from `list`. The script refuses a missing/failed snapshot, any target index that already exists or cannot be checked, and a restore without the exact confirmation phrase. It never deletes an existing index and always sets `include_global_state=false`.
3. Verify restored index health, document count against the source snapshot, mappings/settings, representative search results, and application connectivity. Record measured recovery time and the age of the restored snapshot. Remove a drill index only through the approved change process.
4. For production recovery, freeze writes and follow the incident/change process. Prefer restoring to a new index, verify it, then perform an explicitly reviewed application cutover. The current application uses a concrete index name rather than an alias; update `ES_INDEX` only in a reviewed deployment change. Do not delete or overwrite the current index through this helper.
5. After a real incident or drill, capture the snapshot ID, source/target, document counts, measured RPO/RTO, failures, and remediation. Repeat at least quarterly and after material Elasticsearch, IAM, storage, or repository changes.

The helper supports `register`, `verify`, `apply-policy`, `policy-status`, `snapshot`, `list`, and guarded `restore`; it is not a backup monitor. Alerting on missing/failed SLM runs, bucket capacity, and restore errors must be configured and tested by the service owner before claiming operational coverage.

## Validation performed in the workspace

- `bash -n` passed for the snapshot client and its test.
- `scripts/test-elasticsearch-snapshot.sh` passed with a mocked `curl`. It checks repository/policy requests, secret handling, explicit restore confirmation, refusal to overwrite, and staging-index rename. The test made no network, cluster, or AWS calls.
- The existing Terraform state bootstrap was inspected: S3 state versioning and DynamoDB point-in-time recovery are configured. No Terraform plan/apply or state recovery was performed.

## Outstanding owner actions

- Approve RPO/RTO and retention for each environment; targets above are proposals.
- Provision or select the dedicated S3 snapshot bucket and approve region, encryption/KMS, access logging, versioning, retention, and cost.
- Configure the least-privilege AWS workload identity and Elasticsearch API key; confirm repository support is installed on all nodes.
- Enable the SLM policy, monitor its success/freshness, and complete a timed restore drill.
- Decide whether a second-region copy is required and approve its cost and operating model.
- Back up the bootstrap Terraform local state according to the platform's protected-state procedure; never commit state or generated credentials.

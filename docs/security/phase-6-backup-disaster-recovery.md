# Phase 6 — Backup, restore, and disaster recovery

## Status: tooling and procedure in place, backups NOT active

This phase adds an operator-run Elasticsearch snapshot client, a tested SLM
policy definition, and a restore procedure. Nothing here creates a bucket, IAM
role, repository, snapshot, or restore. **Backups are inactive until an operator
supplies an approved S3 destination and identity, registers the repository,
applies the SLM policy, and verifies a real snapshot.**

The tooling was ported from PR #32 (`arena/90ec80bf-elastiflix`), which shares no
history with the current `main`. It was reviewed and re-tested here rather than
merged, and two extra refusal tests were added (plaintext-HTTP endpoint and a
non-conforming snapshot name).

## Probe results (what exists in current `main`)

| Component | State | Evidence |
|---|---|---|
| Elasticsearch snapshot/SLM tooling | **Delivered on this branch** — was absent from `main`, only on PR #32 | `git diff origin/main origin/arena-90ec80bf` lists `scripts/elasticsearch-snapshot.sh` as added; restored here as `scripts/elasticsearch-snapshot.sh` + mocked test |
| Terraform state bucket durability | **Partially configured** — `encrypt = true` and a DynamoDB lock table, but no versioning/PITR proven | `terraform/backend.tf` |
| MinIO | Present, demo-only, placeholder credentials | `minio.yaml` |
| Velero | **Absent, and no longer claimed** — `README.md` used to mention it; this branch removed that claim (see `docs/audit/repository-architecture.md` finding A5). No manifests, no namespace | `grep -rn velero` returns only audit documents |
| Restore ever tested | **No** | no snapshot has been taken |

`terraform/backend-bootstrap.tf` (added in this branch) closes the state-bucket
gap with versioning, SSE-KMS, public-access blocks and DynamoDB PITR. It does
**not** create the bucket, because the bucket must exist before `terraform init`,
and creating it there would be a chicken-and-egg dependency. It must be
`terraform import`ed against the existing bucket and table.

## Recovery objectives — proposals, not commitments

| Data / service | Proposed RPO | Proposed RTO | Approach and caveat |
|---|---:|---:|---|
| `elastiflix-movies` index | 24 h | 4 h | Daily SLM snapshot to an approved S3 repository; restore into an empty index or isolated cluster. Requires one successful scheduled snapshot **and** a timed restore drill. |
| Terraform state | 24 h | 4 h | S3 versioning plus DynamoDB PITR (same region). Not a regional failover design. |
| Redis | none | 1 h | Recreate as a cache. Cache contents are not authoritative (ADR-0004). |
| RabbitMQ `search_events` | best effort | 4 h | Recreate the broker. Historical search events may be lost; they are analytics, not system-of-record data. |
| Git (manifests, rules, dashboards, Terraform, this runbook) | commit | 4 h | Re-apply reviewed configuration after dependencies are restored. |
| Prometheus TSDB, Elasticsearch/Kibana logs | none | n/a | Deliberately out of scope. Do not describe this as a complete backup story. |

These numbers are planning targets for a single-node demo deployment. They are
**not measured**, and nobody has demonstrated them.

## Elasticsearch snapshot design

- **SLM, not PVC copies.** Schedule `0 30 2 * * ?` (02:30 UTC daily),
  `expire_after: 30d`, `min_count: 7`, `max_count: 35`, `include_global_state:
  false`, `partial: false`, indices limited to `elastiflix-movies`.
- **Destination:** an existing, approved, dedicated S3 bucket — never the
  Terraform state bucket. Requires public-access blocks, TLS-only access,
  server-side encryption, versioning, access logging, and an approved retention
  policy. Do not attach an independent S3 lifecycle expiry to snapshot objects:
  SLM must remove complete snapshots coherently.
- **Identity:** the Elasticsearch nodes need the S3 repository plugin and an AWS
  identity scoped to the bucket prefix — IRSA where possible. No static keys in
  manifests or Git.
- **Credential:** a dedicated Elasticsearch API key with only the repository,
  SLM and snapshot permissions required, stored in an operator-managed file. Do
  not use the `elastic` superuser and do not reuse the application's search key.
- **Cross-region replication is not configured.** Same-region snapshots do not
  survive a regional outage or account loss. Do not claim regional DR until a
  second region, bucket, key and replication role are approved and funded.

## Operator procedure: enable snapshots

Prerequisites: approved bucket and prefix, S3 repository support on every node,
a workload identity scoped to that prefix, a dedicated API key, network access
to Elasticsearch, and the trusted CA certificate. Keep credentials out of argv,
shell history, logs, Git and chat.

The script requires `ES_URL` to be **HTTPS** and `ES_CA_FILE` to exist; it reads
the API key from a file into a `0600` temporary curl header file and deletes it on
exit.

```bash
export ES_URL='https://elasticsearch.example:9200'
export ES_CA_FILE=/secure/path/ca.crt
export ES_API_KEY_FILE=/secure/path/snapshot-api-key

# 1. Register the already-approved bucket (mutates Elasticsearch configuration).
SNAPSHOT_BUCKET='<approved-bucket>' \
AWS_REGION='<bucket-region>' \
SNAPSHOT_BASE_PATH='elastiflix/<cluster-id>' \
  scripts/elasticsearch-snapshot.sh register

# 2. Prove the nodes can reach S3.
scripts/elasticsearch-snapshot.sh verify

# 3. Enable the daily policy, then confirm it exists.
scripts/elasticsearch-snapshot.sh apply-policy
scripts/elasticsearch-snapshot.sh policy-status

# 4. Take one snapshot now and list it.
scripts/elasticsearch-snapshot.sh snapshot
scripts/elasticsearch-snapshot.sh list
```

None of this runs in CI, Argo CD, or Ansible. `register` and `apply-policy`
change Elasticsearch state and need the normal change approval.

Commands: `register`, `verify`, `apply-policy`, `policy-status`, `snapshot`,
`list`, `restore`.

## Restore and drill procedure

1. Start from an isolated, empty cluster. Confirm the repository is registered
   and verified, TLS trust works, the snapshot is listed, and its state is
   `SUCCESS`.
2. Restore into a **staging index** first:

   ```bash
   RESTORE_TARGET_INDEX='elastiflix-movies-dr-test' \
   CONFIRM_RESTORE='RESTORE elastiflix-movies into elastiflix-movies-dr-test from <snapshot>' \
     scripts/elasticsearch-snapshot.sh restore '<snapshot>'
   ```

   The script refuses a missing or non-`SUCCESS` snapshot, any target index that
   already exists or cannot be checked, and any restore without the exact
   confirmation phrase. It never deletes an index and always sets
   `include_global_state=false`.
3. Verify: cluster health, document count against the source, mappings and
   settings, representative search results, and application reads. Record the
   measured time and the age of the restored snapshot.
4. Production recovery: freeze writes, follow incident/change process, prefer
   restoring to a new index, verify, then a reviewed cutover. The application
   uses a concrete index name, not an alias — `ES_INDEX` changes are deployment
   changes, not restore steps.
5. Record snapshot ID, source/target, document counts, measured RPO/RTO,
   failures and remediation. Repeat at least quarterly and after material
   Elasticsearch, IAM, storage or repository changes.

The client is not a backup monitor. Alerting on missing or failed SLM runs,
bucket capacity, and restore failures must be configured and tested separately.

## Minikube / local

Local clusters have no S3 repository and no IAM role. Options, in order of
preference: (a) skip snapshots locally and treat the loader as the source of
truth (`data-loader/` can re-index from scratch), or (b) register a MinIO-backed
snapshot repository with its own explicitly local credentials. Never reuse an
AWS production credential locally.

## Validation performed

- `bash -n` passes for the snapshot client and its test.
- `scripts/test-elasticsearch-snapshot.sh` passes with a mocked `curl`: it
  asserts the repository and policy requests, that the API key never appears in
  curl arguments or the request body, that restore requires the exact
  confirmation phrase, that an existing target index is refused, that a
  non-`SUCCESS` snapshot is refused, that the staging rename is applied, that a
  plaintext HTTP endpoint is rejected before any request, and that a
  non-conforming snapshot name is rejected before any request. **No network,
  cluster or AWS call is made.**
- Terraform state durability was reviewed statically; no plan or apply ran.

## Outstanding owner actions

- Approve RPO/RTO and retention per environment.
- Provision or select the dedicated S3 snapshot bucket; approve region,
  encryption/KMS, access logging, versioning, retention and cost.
- Configure the least-privilege identity and Elasticsearch API key; confirm the
  repository plugin is installed on every node.
- Enable the SLM policy, monitor its success and freshness, and complete a timed
  restore drill.
- Decide whether a second-region copy is required, and fund it.
- Import the existing state bucket and lock table into
  `terraform/backend-bootstrap.tf` and review the plan before applying.

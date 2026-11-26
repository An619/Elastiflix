# Manual validation runbook: Phase 1–7 in Minikube first, AWS only after sign-off

This runbook walks through repository checks and Phase 1–7 validation on a disposable Minikube cluster first. **Do not run the AWS staging sections at the end until every required Minikube check passes, AWS-specific inputs/costs are reviewed, and the owner explicitly approves moving on.** A Minikube pass does not prove AWS behavior.

Commands are labeled:

- **[READ-ONLY]**: inspect or validate only.
- **[LOCAL CHANGE]**: changes the local repository or Minikube.
- **[AWS CHANGE — APPROVAL REQUIRED]**: creates or changes AWS resources, spends money, changes cluster state, or publishes the app.

Expected output below is a pass criterion, not a promise of exact text. Cloud IDs, resource counts, timings, and versions vary by environment.

## Important gates before starting

1. Run AWS commands only from an operator shell with an explicitly selected AWS profile and account. Never paste keys, tokens, kubeconfigs, Terraform state/plan contents, Elasticsearch API keys, or secret values into chat or Git.
2. Use a disposable Minikube cluster first, then an isolated **dev/staging** AWS account/environment and a distinct Terraform state key. Do not point these commands at production.
3. Terraform/Ansible and several `kubectl` commands mutate resources. Review each plan/change and get the account owner's approval before running commands marked as changes.
4. The current AWS Ingress is internet-facing **HTTP only**. It requires no custom/private DNS name, but it publishes unencrypted traffic on the public internet. Use only for a non-sensitive demo. Production exposure requires HTTPS and an approved certificate/domain.
5. The local Minikube Argo CD root and child Applications target `arena/90ec80bf-elastiflix` so a bootstrap from this branch tests this branch's manifests. EKS GitOps remains on its existing `main` revision; this branch-only revision is for local Minikube testing and must be reviewed before any merge to `main`. Verify all local Application source revisions before calling the branch test successful.
6. Minikube does not validate AWS IRSA, EKS add-ons, EBS CSI, AWS Secrets Manager, ALB, or S3. Those have separate AWS staging checks below.

### Get the branch on your laptop

The test files are on `arena/90ec80bf-elastiflix`, not `main`. From your existing clone, first make sure you have no local changes you need to preserve (`git status --short`); stash or back them up before switching if necessary. Then fetch and create a local tracking branch:

```bash
git fetch origin
git switch --track origin/arena/90ec80bf-elastiflix
git status -sb
```

If the local branch already exists, use `git switch arena/90ec80bf-elastiflix` after fetching. **Expected:** `git status -sb` shows `arena/90ec80bf-elastiflix` tracking `origin/arena/90ec80bf-elastiflix`; do not continue from `main`. These commits prepare the local test branch only; they do not deploy AWS or authorize merging to `main`.

## Phase 1 — CI/CD and supply-chain checks

Run from the repository root. Use Node.js 22 and Terraform 1.9.8 (the CI Terraform version).

### 1.1 Repository and shell checks

**[READ-ONLY]**

```bash
git status --short
git diff --check
bash -n bootstrap.sh start.sh scripts/*.sh
bash scripts/test-elasticsearch-snapshot.sh
```

**Pass when:** `git diff --check` and `bash -n` exit 0; the snapshot test ends successfully and reports its mocked checks passed. It must not make AWS or Elasticsearch calls.

### 1.2 Frontend and backend tests

**[READ-ONLY; downloads locked dependencies into ignored `node_modules`]**

```bash
(
  cd frontend
  npm ci --legacy-peer-deps
  CI=true npm test -- --watchAll=false
  npm run build
)

(
  cd backend
  npm ci
  npm test
)
```

**Pass when:** frontend tests finish with zero failures and the production build completes; backend `npm test` exits 0. Test counts may change as tests are added.

### 1.3 Observability validation

**[READ-ONLY; creates a temporary Python virtual environment]**

```bash
python3 -m venv /tmp/observability-venv
/tmp/observability-venv/bin/pip install --disable-pip-version-check --no-input \
  --only-binary=:all: PyYAML==6.0.4 promql-parser==0.12.0
/tmp/observability-venv/bin/python -m unittest data-loader/test_validate_observability.py
/tmp/observability-venv/bin/python scripts/validate-observability.py
```

**Pass when:** both Python commands exit 0 and the validator reports successful parsing of the configured Prometheus rules and Grafana dashboards.

### 1.4 Terraform formatting and validation

**[READ-ONLY validation; `init` downloads providers/modules and may create lock files]**

```bash
terraform version
terraform fmt -check -recursive terraform/
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
terraform -chdir=terraform/backend-bootstrap init -backend=false
terraform -chdir=terraform/backend-bootstrap validate
```

**Pass when:** Terraform reports version 1.9.8 (or the CI-pinned version), formatting is clean, and both roots report `Success! The configuration is valid.` Review and commit generated `.terraform.lock.hcl` files if produced; do not use `-upgrade` just to get a passing result.

### 1.5 Ansible and manifest checks

**[READ-ONLY; creates a temporary Python virtual environment]**

```bash
python3 -m venv /tmp/ansible-venv
/tmp/ansible-venv/bin/pip install --disable-pip-version-check --no-input ansible-core==2.19.6
/tmp/ansible-venv/bin/ansible-playbook --syntax-check ansible/playbook.yml

kubectl kustomize kubernetes/environments/minikube > /tmp/elastiflix-minikube.yaml
kubectl kustomize kubernetes/environments/eks > /tmp/elastiflix-eks.yaml
kubectl kustomize kubernetes/gitops/local > /tmp/elastiflix-gitops-local.yaml
kubectl kustomize kubernetes/gitops/eks > /tmp/elastiflix-gitops-eks.yaml
test -s /tmp/elastiflix-minikube.yaml
test -s /tmp/elastiflix-eks.yaml
test -s /tmp/elastiflix-gitops-local.yaml
test -s /tmp/elastiflix-gitops-eks.yaml
```

**Pass when:** Ansible prints `playbook: ansible/playbook.yml` and exits 0; each `kubectl kustomize` build exits 0 and creates a non-empty output file. These renders do not prove controller/runtime behavior.

CI additionally runs Gitleaks, dependency audits, SonarCloud, Hadolint, Trivy, Checkov, and strict Kubeconform. Treat the **hosted PR checks** as authoritative for those tools. Kubeconform's equivalent from CI is:

```bash
# Linux x86-64; otherwise use the hosted CI job or a verified platform build.
curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
  https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz \
  | tar -xz -C /tmp kubeconform
/tmp/kubeconform -strict -ignore-missing-schemas -summary \
  kubernetes/application/ kubernetes/infra/ \
  kubernetes/elastic-stack/ kubernetes/aws/ kubernetes/monitoring/
```

**Pass when:** Kubeconform exits 0 with no built-in schema errors; unknown custom-resource schemas may be reported as ignored by this configured command.

### 1.6 Hosted PR checks (separate from Minikube)

Hosted Gitleaks, dependency, SonarCloud, Hadolint, Trivy, Checkov, and Kubeconform gates run in GitHub Actions. They are useful before sign-off, but they are not a prerequisite for starting disposable local Minikube tests and they do not prove AWS readiness. This test branch is published only so the operator can fetch it and test the current files locally; publishing it does not authorize an AWS deployment or a merge to `main`. Inspect the branch's hosted checks as an additional signal, not as proof of Minikube or AWS runtime behavior.


**Expected:** hosted checks have no blocking failures. PR builds normally skip `docker-push`; a CI pass does not provision or validate a Kubernetes cluster.

Before Phase 1 sign-off, have the platform owner review the SSM-agent startup handling noted in `docs/security/phase-1-cicd-devsecops.md` and record the decision.

## Phase 2 — Infrastructure code and Kubernetes hardening

### 2.1 Local code review (no cloud resources)

The Terraform checks in Phase 1 validate syntax/schema. **Do not apply Terraform to Minikube**; Terraform describes AWS infrastructure. Confirm the inputs and security defaults are explicit:

```bash
rg -n 'cluster_version|availability_zone_names|cluster_endpoint_public_access_cidrs' terraform
rg -n 'version =|cluster_addons|aws-ebs-csi-driver|attach_ebs_csi_policy' terraform
```

**Expected:** cluster version and three AZ names are required operator inputs; EKS API is private by default; Terraform defines CoreDNS/kube-proxy/VPC CNI and EBS CSI add-ons, with a dedicated EBS CSI IRSA role. The exact versions are the repository pins. Do not upgrade Terraform module major versions as part of this runbook.

### 2.2 Minikube setup

Prerequisites: Minikube, kubectl, Helm, OpenSSL, curl, jq, Docker/runtime, and at least the resources requested by `bootstrap.sh` (4 CPUs, 7.5 GB RAM, 30 GB disk). The bootstrap installs software and applies resources to **the current Minikube context**.

**[LOCAL CHANGE]** First confirm you are not pointed at a remote cluster:

```bash
minikube version
minikube profile list
kubectl config get-contexts
```

**Expected:** Minikube is installed; `profile list` may show no profile before the first start. `kubectl config get-contexts` lists configured contexts without changing them. If an existing `minikube` profile is listed and you want to inspect it, run `minikube status -p minikube` and expect its components to be `Running` or a clear stopped/not-started status. Never continue if the active `kubectl` context is a remote/production cluster; after bootstrap, explicitly verify the context is `minikube` before any `kubectl` mutation.

The bootstrap now creates strong local Redis/RabbitMQ passwords automatically on first run and saves them in ignored, mode-0600 files under `.secrets/minikube`. On reruns it reuses those files or safely recovers existing Kubernetes Secret values, and refuses implicit credential rotation. Keep `.secrets/minikube` and `.secrets/elasticsearch` protected and backed up; if the Elasticsearch directory is missing while its Kubernetes Secret exists, the script stops rather than replacing the existing credentials.

Run the whole local bootstrap with one command:

```bash
./bootstrap.sh
```

**Expected:** Minikube starts with requested resources; ingress, Argo CD, Argo Rollouts, Falco, namespaces, local secrets, and the local GitOps root are installed. Argo CD automatically syncs the root and child Applications. The script waits for every local Application to be `Synced` and `Healthy`, waits for app/dependency rollouts and ready frontend/backend Service endpoints, then prints the Minikube IP and demo URLs. It exits non-zero with the failing `kubectl`/Helm command if a prerequisite or readiness gate fails. No manual Argo CD sync is required. Passwords are never printed or committed.

If bootstrap fails, inspect the error and `kubectl config current-context`; do not continue against any context other than Minikube. Before declaring a branch test successful, verify the root and all local child Applications use `arena/90ec80bf-elastiflix` as their source revision. The EKS GitOps configuration is not changed for this Minikube-only test.

### 2.3 Verify local hardening resources

**[READ-ONLY]**

```bash
test "$(kubectl config current-context)" = minikube
kubectl get nodes -o wide
kubectl get applications -n argocd
kubectl get pods -A
kubectl get pvc -A
kubectl get hpa,pdb -A
kubectl get networkpolicies -A
kubectl get secrets -n infra
kubectl get secrets -n elastiflix
```

**Expected:** current context is `minikube`; the node is `Ready`; Argo Applications become `Synced`/`Healthy`; required pods become `Running` (or successful Jobs `Completed`); PVCs used by running workloads become `Bound`; HPA/PDB and NetworkPolicy objects exist. Secret commands list only metadata/names—never run `kubectl get secret -o yaml` or print `.data` values.

For controller image/class inventory:

```bash
scripts/phase4-controller-report.sh minikube
```

**Expected:** output identifies context `minikube`, Argo Rollouts image `v1.10.2`, a non-`latest` ingress-nginx image, and `IngressClass present: nginx`. If a deployment or class is absent, stop and diagnose rather than treating it as a pass.

### 2.4 NetworkPolicy enforcement smoke test (optional; disposable Minikube only)

A `NetworkPolicy` object is not proof that the CNI enforces it. First confirm the selected Minikube CNI supports enforcement. If not, record this test as **not validated locally** and use an approved policy-capable test cluster; do not mark it passed.

The following creates two short-lived diagnostic pods. The `elastiflix` pod is labeled as a frontend peer so it should reach the backend. The `default` namespace pod is not an allowed peer and should be blocked. This is a **local cluster mutation**; use only on disposable Minikube.

```bash
cat > /tmp/elastiflix-netpolicy-smoke.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: np-allowed-check
  namespace: elastiflix
  labels:
    app: frontend
spec:
  automountServiceAccountToken: false
  restartPolicy: Always
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: curl
      image: curlimages/curl:8.12.1
      command: ["sh", "-c", "sleep 3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
        runAsNonRoot: true
        runAsUser: 1000
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 50m
          memory: 64Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: np-denied-check
  namespace: default
  labels:
    app: unrelated-network-test
spec:
  automountServiceAccountToken: false
  restartPolicy: Always
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: curl
      image: curlimages/curl:8.12.1
      command: ["sh", "-c", "sleep 3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
        runAsNonRoot: true
        runAsUser: 1000
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 50m
          memory: 64Mi
YAML

kubectl apply -f /tmp/elastiflix-netpolicy-smoke.yaml
kubectl wait --for=condition=Ready pod/np-allowed-check -n elastiflix --timeout=120s
kubectl wait --for=condition=Ready pod/np-denied-check -n default --timeout=120s
kubectl exec -n elastiflix np-allowed-check -- \
  curl --connect-timeout 3 --max-time 5 -fsS \
  http://backend.elastiflix.svc.cluster.local:17700/healthz
```

**Expected allowed result:** `OK` and exit status 0. This proves the diagnostic pod can reach the backend over the allowed path.

Then test the denied path:

```bash
BACKEND_IP="$(kubectl get svc backend -n elastiflix -o jsonpath='{.spec.clusterIP}')"
if kubectl exec -n default np-denied-check -- \
  curl --connect-timeout 2 --max-time 4 -fsS \
  "http://${BACKEND_IP}:17700/healthz"; then
  echo "FAIL: unrelated namespace reached backend"
  exit 1
else
  echo "PASS: unrelated namespace was blocked (confirm the allowed test passed first)"
fi
```

**Expected denied result:** the request times out/fails and the command prints the `PASS` line. If it returns `OK`, NetworkPolicy enforcement is absent or the rules are too permissive. A failed allowed test means the denied test is inconclusive.

Clean up even if one test fails:

```bash
kubectl delete pod np-allowed-check -n elastiflix --wait=true --ignore-not-found
kubectl delete pod np-denied-check -n default --wait=true --ignore-not-found
rm -f /tmp/elastiflix-netpolicy-smoke.yaml
```

**Expected:** both pods report deleted or not found; no test pod remains.

## Phase 3 — Runtime checks in Minikube

### 3.1 Cluster inventory and metrics-server

**[LOCAL CHANGE for enabling the add-on; otherwise read-only]**

```bash
minikube addons enable metrics-server
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes
kubectl top nodes
kubectl get hpa,pdb -n elastiflix
kubectl describe hpa -n elastiflix
bash scripts/phase3-cluster-report.sh
```

**Expected:** metrics-server add-on reports enabled; raw metrics output contains node metrics; `kubectl top nodes` shows CPU/memory; HPA metrics are available rather than `<unknown>`; the read-only report ends with `Report complete. No cluster resources were changed.` The report may show warnings for AWS-only ESO/ALB resources in Minikube—those are not local pass criteria.

For scale testing, use only the disposable Minikube cluster. Generate representative load from a reviewed test client, then run `kubectl get hpa -n elastiflix -w` in another terminal. Stop the generator and verify scaling returns toward the configured minimum. **Pass when:** an HPA observes metrics and scales both up and down; record the commands/client, load duration, and observed replicas. Do not inject load into AWS production.

### 3.2 Application, ingress, and workload health

**[READ-ONLY]**

```bash
kubectl get pods,svc -n elastiflix -o wide
kubectl get pods,svc,pvc -n infra -o wide
kubectl get pods,svc,pvc -n elastic-stack -o wide
kubectl get ingress -n elastiflix -o wide
minikube ip
```

**Expected:** frontend/backend and supporting pods are ready, Services have endpoints, required PVCs are `Bound`, and local Ingresses use the `nginx` class. If ingress name resolution is not configured, map the displayed Minikube IP to `elastiflix.local` and `api.elastiflix.local` in the local hosts file, or use the documented Minikube tunnel if your driver needs it.

```bash
MINIKUBE_IP="$(minikube ip)"
curl --fail --silent --show-error --resolve "elastiflix.local:80:${MINIKUBE_IP}" \
  --output /dev/null --write-out 'frontend HTTP %{http_code}\n' \
  http://elastiflix.local/
curl --fail --silent --show-error --resolve "api.elastiflix.local:80:${MINIKUBE_IP}" \
  http://api.elastiflix.local/
```

**Expected:** frontend reports HTTP `200`; backend prints `Hello from the backend!`. A connection refusal/timeout means ingress/IP/tunnel is not ready; diagnose before proceeding.

### 3.3 Redis, RabbitMQ, Elastic Stack, and Filebeat

**[READ-ONLY]**

```bash
kubectl get pods,svc,pvc -n infra -o wide
kubectl get pods,svc,pvc -n elastic-stack -o wide
kubectl get ds/filebeat -n elastic-stack -o wide
kubectl get networkpolicies -A
```

**Expected:** Redis, RabbitMQ, Elasticsearch, Kibana, Logstash, and Filebeat workloads show Ready/Running; persistent claims used by these workloads are Bound; Filebeat DaemonSet has a ready pod on each eligible node. `NetworkPolicy` objects exist, but only mark enforcement passed if the CNI smoke test above succeeded.

For Elasticsearch logs, inspect only a short sanitized tail; **do not print credentials, Secret contents, or API-key headers**:

```bash
kubectl logs -n elastic-stack statefulset/elasticsearch --tail=50
kubectl logs -n elastic-stack deployment/logstash --tail=50
kubectl logs -n elastic-stack daemonset/filebeat --tail=50
```

**Expected:** no repeated crash/restart, TLS, authentication, or connection errors. Confirm representative application logs arrive in Elasticsearch/Kibana through the UI; a running pod alone is not evidence of delivery.

### 3.4 Prometheus, Redis/RabbitMQ metrics, and alerts

**[READ-ONLY except port-forward process]** Run the port-forward in a dedicated terminal and leave it running:

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
```

In a second terminal:

```bash
kubectl get servicemonitors,prometheusrules -n monitoring
kubectl get svc redis rabbitmq -n infra -o wide
curl --fail --silent --show-error --get \
  --data-urlencode 'query=up' http://127.0.0.1:9090/api/v1/query
curl --fail --silent --show-error --get \
  --data-urlencode 'query=elastiflix_http_responses_total' \
  http://127.0.0.1:9090/api/v1/query
```

**Expected:** the JSON responses contain `"status":"success"`; expected scrape targets become `up`/value `1`; after making app requests, the response metric has series. Query the Redis/RabbitMQ metric names listed in `docs/security/phase-3-manual-validation.md`. Alert rules should load/evaluate; Alertmanager is disabled, so **no notification delivery is expected**.

Open Grafana via its documented port-forward:

```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
```

**Expected:** Grafana loads on `http://localhost:3000`; the provisioned dashboards render and have current samples. Do not treat empty series or a seven-day SLO window as mature before enough traffic/history exists.

## Phase 4 — Argo CD and progressive delivery

### 4.1 Check local controllers and Apps

```bash
scripts/phase4-controller-report.sh minikube
kubectl get applications -n argocd
kubectl get rollout frontend -n elastiflix -o wide
kubectl get analysisruns -n elastiflix
```

**Expected:** controller report passes version/class checks; the local root and child Applications become `Synced`/`Healthy`; Rollout reports healthy/available; AnalysisRuns appear when the canary steps run. If the Rollouts kubectl plugin is installed, use:

```bash
kubectl argo rollouts get rollout frontend -n elastiflix
```

**Expected:** the CLI reports rollout status and stable/canary revisions. The exact revision depends on the deployed image.

### 4.2 Exercise a canary only with a reviewed test image

A genuine weighted canary needs a **different, valid test image digest** and a GitOps change in a disposable Minikube environment. Do not patch an image in a production cluster. Update the Minikube-only frontend image using the normal reviewed GitOps process; then inspect the rollout:

```bash
kubectl argo rollouts get rollout frontend -n elastiflix --watch
kubectl get analysisruns -n elastiflix -w
```

**Expected:** the rollout advances through configured weights 10%, 25%, 50%, then 100%; analysis succeeds with controlled traffic and the stable Service remains available. To test abort/recovery, use a purpose-built failing image in disposable Minikube and confirm the rollout aborts/returns traffic to stable. Do not use a failure image in AWS staging or production without explicit approval.

**Pass when:** observed request routing follows weights (not merely replica counts), analysis behavior is recorded, and stable-service recovery is demonstrated. If no test image or traffic generator is available, record this check as pending instead of claiming success.

## Phase 5 — SLO and observability

The Minikube tests in Phase 3 validate local Prometheus/Grafana plumbing. Use a non-production owner-approved test to exercise the SLO rules; do not inject errors into production.

**[READ-ONLY]** With the Prometheus port-forward running:

```bash
kubectl get prometheusrules -n monitoring
curl --fail --silent --show-error --get \
  --data-urlencode 'query=elastiflix_http_responses_total' \
  http://127.0.0.1:9090/api/v1/query
curl --fail --silent --show-error --get \
  --data-urlencode 'query=elastiflix_http_request_duration_seconds_count' \
  http://127.0.0.1:9090/api/v1/query
```

**Expected:** Prometheus returns `"status":"success"`; metrics have series after requests; the rule objects are loaded. Confirm dashboard panels render and the seven-day query is not presented as mature until seven days of data are retained. The service owner must approve or change the proposed 99.5% objective. Alertmanager delivery remains **not complete** until a receiver/escalation policy is approved and tested with a non-production destination.

**Phase 5 pass evidence:** capture approved objective, actual retention, target/rule status, dashboard rendering, and—if enabled—test notification delivery. A passing local query is not evidence of paging.

## Phase 6 — Backup, restore, and DR

### 6.1 Local safety test only

```bash
bash -n scripts/elasticsearch-snapshot.sh scripts/test-elasticsearch-snapshot.sh
bash scripts/test-elasticsearch-snapshot.sh
```

**Expected:** shell syntax exits 0; mocked safety checks pass, including explicit restore confirmation and refusal to overwrite an existing index. This test makes no AWS/S3/Elasticsearch call. Do not register a production bucket or use production credentials from Minikube.

### 6.2 AWS staging snapshot/restore — not part of Minikube; do not run yet

Before running: an owner must approve a **dedicated existing S3 bucket** (not the Terraform state bucket), prefix, region, encryption/retention, logging, cost, least-privilege workload identity (prefer IRSA), Elasticsearch S3 repository support on all nodes, and a dedicated snapshot API key. The current Terraform code does not provision this snapshot bucket/identity. Stop if any prerequisite is missing.

Create a protected API-key file using the organization's approved secret manager. Do not put the API key in a shell command or shell history. Then set paths/endpoint in the secured operator shell:

```bash
export ES_URL='https://<approved-elasticsearch-endpoint>'
export ES_CA_FILE="$HOME/.secrets/elasticsearch/ca.crt"
export ES_API_KEY_FILE="$HOME/.secrets/elasticsearch/snapshot-api-key"
test -s "$ES_CA_FILE" && test -s "$ES_API_KEY_FILE"
chmod 600 "$ES_API_KEY_FILE"
```

**Expected:** both files exist and are readable only by the operator. Do not `cat` the API key file.

The following commands **change Elasticsearch configuration or create a snapshot**. Run only against approved non-production AWS staging after a reviewed change:

```bash
SNAPSHOT_BUCKET='<approved-dedicated-bucket>' \
AWS_REGION="$AWS_REGION" \
SNAPSHOT_BASE_PATH="elastiflix/<staging-cluster-id>" \
scripts/elasticsearch-snapshot.sh register

scripts/elasticsearch-snapshot.sh verify
scripts/elasticsearch-snapshot.sh apply-policy
scripts/elasticsearch-snapshot.sh policy-status
scripts/elasticsearch-snapshot.sh snapshot
scripts/elasticsearch-snapshot.sh list
```

**Expected:** `register` returns an acknowledged repository response; `verify` lists Elasticsearch nodes; `apply-policy` returns the policy definition; `policy-status` reports SLM running and the policy; `snapshot` returns a snapshot with state `SUCCESS`; `list` shows that snapshot. Exact JSON and snapshot names vary. Any authorization, S3, TLS, or repository error is a stop condition—do not treat a registered repository as a successful backup.

For a restore drill, use an isolated/staging index that does not already exist. Replace the snapshot name with one shown by `list`:

```bash
SNAPSHOT_NAME='<successful-snapshot-name>'
RESTORE_TARGET_INDEX='elastiflix-movies-dr-test'
CONFIRM_RESTORE="RESTORE elastiflix-movies into ${RESTORE_TARGET_INDEX} from ${SNAPSHOT_NAME}" \
RESTORE_TARGET_INDEX="$RESTORE_TARGET_INDEX" \
scripts/elasticsearch-snapshot.sh restore "$SNAPSHOT_NAME"
```

**Expected:** restore request completes to the staging index only. Verify index health, document count, mappings, and representative search results through the approved Elasticsearch client/UI. Do not restore over the live index. Record measured RPO/RTO and drill evidence. Backups are operational only after a successful scheduled snapshot, monitoring for missed/failed snapshots, and a successful restore drill.

## Minikube completion gate — stop here before AWS

Do not continue to the AWS staging section until you have run the Minikube steps above and recorded each check as **PASS**, **FAIL**, or **PENDING**. For this local gate, required checks are: Phase 1 repository/app/observability/Terraform/Ansible/render checks; Phase 2 Minikube bootstrap and hardening inventory; Phase 3 workload, ingress, dependencies, HPA/PDB, metrics and dashboards; Phase 4 GitOps/controller health and canary behavior (or clearly recorded pending if no safe test image/traffic generator exists); Phase 5 SLO rules/dashboard evidence and the explicit note that alert delivery is pending without an approved receiver; and Phase 6 local snapshot-script safety tests. **Minikube cannot prove EKS, IRSA, EBS CSI, AWS Secrets Manager, ALB, S3 backups, or AWS restore behavior.**

If any required check fails, stop and fix it locally before considering AWS. If an optional check cannot be run, record why instead of marking it passed. Only after local checks pass should we separately review the AWS inputs, promotional-credit eligibility/remaining balance, current cost plan, and the planned short AWS test window. AWS commands below are a future separate step and require explicit approval; do not run them as part of this Minikube walkthrough.

## AWS staging — repeat only the AWS-specific parts of Phases 2–6

Minikube success is not approval to create AWS resources. Use the separate `terraform/backend-bootstrap/README.md`, `terraform/environments/*.example`, `docs/security/phase-2-terraform-aws.md`, and `docs/security/phase-3-manual-validation.md` as the source of truth. Do not use production values for this procedure.

### A. Preflight and identity

**[READ-ONLY]** Select the owner-approved profile and region. The sample default is `us-east-2`; set the actual approved region if different.

```bash
export AWS_PROFILE='<approved-profile>'
export AWS_REGION='us-east-2'
aws sts get-caller-identity
aws ec2 describe-availability-zones --region "$AWS_REGION" \
  --filters Name=state,Values=available \
  --query 'AvailabilityZones[].ZoneName' --output table
```

**Expected:** `get-caller-identity` account matches the approved staging account; AZ output contains the three distinct AZ names selected for the VPC. Stop on an unexpected account/role or wrong region. Confirm supported EKS version, quotas, log-bucket policy, and regional costs with the owner before proceeding.

Check state-resource ownership before any bootstrap. Set names only after owner confirmation:

```bash
export STATE_BUCKET='<owner-confirmed-state-bucket>'
export STATE_LOCK_TABLE='<owner-confirmed-lock-table>'
aws s3api head-bucket --bucket "$STATE_BUCKET" --region "$AWS_REGION"
aws dynamodb describe-table --table-name "$STATE_LOCK_TABLE" --region "$AWS_REGION" \
  --query 'Table.TableStatus' --output text
```

**Expected:** if resources exist, `head-bucket` exits 0 (usually no output) and DynamoDB returns `ACTIVE`; verify owner/purpose and use the existing infrastructure. If a bucket is missing, access is denied, or ownership is unclear, STOP—do not create duplicates. Only bootstrap a new state backend after the owner confirms neither resource exists and approves the plan/cost.

### B. Bootstrap a new state backend only when necessary

**[AWS CHANGE — APPROVAL REQUIRED; skip if an approved backend already exists]** An approved same-account/same-region audit-log bucket must already exist. Do not use the state bucket as its own logging destination.

```bash
cp terraform/backend-bootstrap/backend-bootstrap.tfvars.example \
  terraform/backend-bootstrap/backend-bootstrap.tfvars
# Edit the ignored local file with the approved region, globally unique new state
# bucket name, lock-table name, and existing audit-log bucket name.
terraform -chdir=terraform/backend-bootstrap init
terraform -chdir=terraform/backend-bootstrap plan \
  -var-file=backend-bootstrap.tfvars -out=backend-bootstrap.tfplan
terraform -chdir=terraform/backend-bootstrap show -no-color \
  backend-bootstrap.tfplan
```

**Expected:** plan shows only intended S3/KMS/DynamoDB bootstrap resources. Review all bucket policy, logging destination, KMS, lifecycle, and cost details. If an existing resource appears, or any destructive/unexpected action appears, STOP and resolve state ownership.

Only after explicit review/approval:

```bash
terraform -chdir=terraform/backend-bootstrap apply backend-bootstrap.tfplan
terraform -chdir=terraform/backend-bootstrap output
```

**Expected:** apply completes with no errors and outputs the state bucket name, lock table name, and KMS key ARN. Securely back up the bootstrap local state. Do not commit local `.tfstate`, `.tfvars`, backend configs, or plans.

### C. Configure and review the main EKS plan

Copy the examples only after the backend values and environment inputs are approved:

```bash
cp terraform/environments/dev.backend.hcl.example terraform/environments/dev.backend.hcl
cp terraform/environments/dev.tfvars.example terraform/environments/dev.tfvars
```

Edit those ignored local files. Set the approved bucket/table/KMS ARN and preserve the dev backend key unless the owner approves a state migration. In `dev.tfvars`, set three real available AZ names and a currently supported EKS `cluster_version`; never leave `REPLACE_WITH_*` placeholders. Confirm `aws_region` matches `kubernetes/aws/secrets/eso.yaml` unless that manifest has been reviewed for the selected region.

**[READ-ONLY plan; initialization accesses the selected remote backend]**

```bash
terraform -chdir=terraform init \
  -backend-config=environments/dev.backend.hcl
terraform -chdir=terraform validate
terraform -chdir=terraform plan \
  -var-file=environments/dev.tfvars -out=dev.tfplan
terraform -chdir=terraform show -no-color dev.tfplan
```

**Expected:** validation succeeds; plan shows intended VPC, EKS, node group, bastion, IAM/IRSA, core add-ons, EBS CSI add-on, and related resources. Review every replacement/destroy, IAM policy, public endpoint setting, subnet, and cost. With private endpoint CIDRs empty, the EKS API should be private-only. STOP if there are unexpected deletes/replacements, unknown state ownership, broad public access, unapproved cost, or wrong account/region.

Only after owner approval, apply the saved plan:

```bash
terraform -chdir=terraform apply dev.tfplan
```

**Expected:** `Apply complete!` with resource counts varying by account/state. Do not rerun a new plan without review if the saved plan is stale. Keep `dev.tfplan` private and remove it securely after the change process permits.

### D. Reach the private EKS API and run the approved bootstrap

The cluster endpoint is private by default. Before this step, establish the owner-approved network path (VPN or approved bastion/SSM forwarding). SSM shell access alone is not automatically a route from your laptop to the EKS API. Stop if the path is not configured.

```bash
export EKS_CLUSTER_NAME="$(terraform -chdir=terraform output -raw eks_cluster_name)"
export ALB_CONTROLLER_ROLE_ARN="$(terraform -chdir=terraform output -raw alb_controller_role_arn)"
export ESO_ROLE_ARN="$(terraform -chdir=terraform output -raw eso_role_arn)"
export AWS_REGION="$(terraform -chdir=terraform output -raw aws_region)"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"
kubectl config current-context
kubectl cluster-info
```

**Expected:** kubeconfig points at the intended EKS cluster and `kubectl cluster-info` reaches the private API. Stop if current context/account is wrong or requests time out; do not run Ansible until connectivity is proven.

**[AWS CLUSTER CHANGE — APPROVAL REQUIRED]**

```bash
ansible-playbook --syntax-check ansible/playbook.yml
ansible-playbook ansible/playbook.yml
```

**Expected:** syntax check exits 0; playbook completes without failed tasks and reports controller versions. This installs/configures Argo CD, Rollouts, External Secrets Operator, AWS Load Balancer Controller, service accounts, and GitOps registration.

### E. AWS Phase 2/3 checks: add-ons, storage, ESO, and workloads

**[READ-ONLY]**

```bash
aws eks describe-addon --cluster-name "$EKS_CLUSTER_NAME" \
  --addon-name aws-ebs-csi-driver --region "$AWS_REGION" \
  --query 'addon.status' --output text
kubectl get nodes -o wide
kubectl get csidriver ebs.csi.aws.com
kubectl get storageclass gp3
kubectl get applications -n argocd
kubectl get pods -A
kubectl get pvc -A
kubectl get clustersecretstore aws-secretsmanager
kubectl get externalsecrets -A
```

**Expected:** EBS add-on status is `ACTIVE`; nodes are `Ready`; EBS CSI driver and `gp3` StorageClass exist; GitOps Applications become `Synced`/`Healthy`; workload pods are ready; used PVCs are `Bound`; `aws-secretsmanager` ClusterSecretStore reports Ready. ESO ExternalSecrets should show Ready/SecretSynced conditions once the owner-provisioned AWS secret records exist. Inspect status only—never output Secret contents.

Before syncing ESO, the owner must provision the documented AWS Secrets Manager records/properties from `kubernetes/aws/secrets/eso.yaml` (Redis, RabbitMQ, Elasticsearch credentials, and TLS properties), and confirm ESO IRSA trust is restricted to its service account. Missing secrets or region mismatch are stop conditions.

Run the read-only report and AWS controller check:

```bash
bash scripts/phase3-cluster-report.sh
scripts/phase4-controller-report.sh eks
kubectl get hpa,pdb -n elastiflix
kubectl get networkpolicies -A
```

**Expected:** report ends with `Report complete. No cluster resources were changed.`; controller report confirms Rollouts `v1.10.2`, non-`latest` AWS Load Balancer Controller image, and `IngressClass present: alb`. HPA metrics must be available and CNI enforcement must be verified with allowed/denied tests—not inferred from policy objects alone.

### F. AWS Phase 4: public demo Ingress and Rollouts

First get explicit approval for public HTTP exposure. If approved, the AWS-generated ALB hostname avoids a custom/private DNS name but traffic is unencrypted.

**[AWS PUBLIC EXPOSURE CHANGE — APPROVAL REQUIRED]**

```bash
kubectl apply -f kubernetes/argocd-aws-ingress.yaml
kubectl -n argocd get application aws-ingress -o wide
kubectl -n elastiflix get ingress app-ingress -w
```

Wait for the ingress status hostname and Argo Application health. Then:

```bash
ALB_HOST="$(kubectl -n elastiflix get ingress app-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
printf 'Public demo URL: http://%s/\n' "$ALB_HOST"
curl --fail --silent --show-error --head "http://${ALB_HOST}/"
```

**Expected:** hostname is non-empty, Application is `Synced`/`Healthy`, and curl receives HTTP `200` (or a documented application redirect/status reviewed by the owner). The endpoint is publicly reachable over HTTP. Do not test with confidential data.

Only after Ingress is healthy, manually sync the already-registered `elastiflix` workload Application in Argo CD. If the Argo CD CLI is installed/authenticated:

```bash
argocd app sync elastiflix
argocd app wait elastiflix --sync --health
```

**Expected:** `Synced` and `Healthy`, workloads ready. Test ALB weighted routing only with a reviewed staging image update and controlled requests; verify actual target-group weights and stable recovery as in the Phase 4 checklist. Do not use a failure image or change canary images in production.

### G. AWS Phase 5/6 checks and exit evidence

Repeat Phase 5 Prometheus queries/dashboard checks against AWS staging, confirming retention and approved owner SLO. Alertmanager notifications remain unproven until a receiver is approved and delivery is tested. Run Phase 6 only after the dedicated bucket, workload identity, plugin, key, and change approvals are in place; follow the real snapshot/restore commands above.

Keep a dated evidence record with: commit/PR and CI run URL; selected environment/account/region (redact account ID where required); Terraform plan/apply review; cluster context and versions; add-on/IRSA/ESO status; PVC and NetworkPolicy results; Argo/Rollouts and observed traffic weights; Prometheus/rule/retention results; public endpoint approval and status; snapshot ID, restore target, and measured RPO/RTO. Never include credentials or Secret data.

## Completion checklist

| Phase | Complete only when |
|---|---|
| 1 — CI/CD | PR checks pass; approved merge's main workflow publishes/signs images successfully; Phase 1 owner follow-up is recorded. |
| 2 — IaC/Kubernetes hardening | Terraform checks and reviewed staging plan pass; owner-approved apply succeeds; cluster hardening and state ownership are verified. |
| 3 — Runtime reliability | Workloads, policies, metrics-server/HPA/PDB, storage, Redis/RabbitMQ, Elastic Stack, and Filebeat behaviors are observed in the target environment. |
| 4 — GitOps/progressive delivery | Apps sync; installed controllers match reviewed pins; actual weighted traffic, analysis, abort, and stable recovery are demonstrated. |
| 5 — SRE/SLO | Owner approves the objective; live metrics/rules/dashboard/retention are verified; notification delivery is tested if claimed. |
| 6 — Backup/DR | Approved storage/identity is active; scheduled snapshot succeeds; monitored freshness is in place; isolated restore drill meets owner-approved objectives. |

Do not mark AWS phases complete based only on Minikube, YAML rendering, Terraform validation, or an AWS plan. Never run `terraform destroy` as part of this runbook.

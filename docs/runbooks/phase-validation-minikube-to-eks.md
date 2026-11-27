# Phase-by-phase validation on Minikube, then EKS

**Purpose:** prove each of the seven phases works, on a local cluster first, then on EKS.
Every command, port, hostname, resource name and expected output below was read out of this
tree — none are invented. Where an expected output depends on your machine, it says so.

**Read §0 before running anything.** It describes two things that will otherwise look like
broken code and are not.

Legend: ✅ pass criterion · ⚠️ expected-but-surprising · ❌ means stop and diagnose.

---

## 0. Before you start: prerequisites and three facts that change the commands

### 0.0 Sizing — this will not fit in a small Minikube

`bootstrap.sh` starts Minikube with `--cpus=4 --memory=7500 --disk-size=30g --cni=calico`.
That is a floor, not a suggestion: Elasticsearch alone reserves 512Mi–1Gi, and
kube-prometheus-stack adds a Prometheus, Grafana, Alertmanager-disabled, kube-state-metrics and
node-exporter set. On a 2-CPU/4GB machine expect `Pending` pods and `OOMKilled` containers, which
looks like a manifest bug and is not. Let `bootstrap.sh` choose the size rather than passing your
own smaller values.



### 0.1 The manifests pin a commit that is not the tip

```console
$ grep -rn "image: an619" kubernetes/
kubernetes/application/backend/deployment.yaml:44:  image: an619/elastiflix-backend:30703b0142e155085ba428b208d97fe54c089562
kubernetes/application/frontend/deployment.yaml:64: image: an619/elastiflix-frontend:30703b0142e155085ba428b208d97fe54c089562
```

`bootstrap.sh` builds images tagged `$(git rev-parse HEAD)` — on this branch that is
`243acab…`, not `30703b0…`. **Those tags do not match, so `bootstrap.sh` alone leaves both app
pods in `ImagePullBackOff`.** That is not a bug in the manifests; it is the reviewed-promotion
model: the tag only moves when a human promotes a digest. §1.3 shows the local-only override.

### 0.2 Argo CD watches `main`, not your branch

```console
$ grep -n "targetRevision" kubernetes/argocd-app.yaml
19:    targetRevision: main
```

So Argo CD will sync `main`'s manifests, **not your working tree**. Any edit you make locally is
invisible to it unless you either push to `main` (don't) or apply the file directly:

```bash
kubectl apply -f kubernetes/application/ -n elastiflix
```

For phase testing, **apply manifests directly and use Argo CD only to demonstrate the sync
mechanism** (§4). Mixing the two will confuse you: Argo CD will revert your direct edits on the
next reconcile, because `selfHeal: true`.

### 0.3 Two credentials are generated, not published

- **Argo CD admin password:** printed by `bootstrap.sh` and recoverable any time with
  `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`
- **Redis / RabbitMQ passwords:** generated per-bootstrap, stored in the `infra` and `elastiflix`
  namespaces as Secrets. Retrieve before you need them:
  `kubectl -n infra get secret redis-secret -o jsonpath='{.data.redis-password}' | base64 -d`

### 0.4 Hosts file, once

```bash
# Linux / macOS / WSL — run once
echo "$(minikube ip) elastiflix.local api.elastiflix.local kibana.local grafana.local argocd.local" | sudo tee -a /etc/hosts
```

`minikube tunnel` must stay running in its own terminal for any host-based access. On Windows
run it from an **Administrator** shell.

---

## Phase 1 — CI/CD and supply chain

This phase is **not** validated on the cluster; it is validated by the pipeline. Run it where
the code is.

### 1.1 The pipeline shape, offline

```bash
python3 -m pip install --quiet PyYAML   # only dependency; skip if already installed
python3 -c "
import yaml, glob
for f in sorted(glob.glob('.github/workflows/*.yml')):
    d = yaml.safe_load(open(f)); on = d.get(True) or d.get('on')
    kind = 'entry point' if any(k in (on or {}) for k in ('push','pull_request')) else 'reusable'
    print(f'{f.split(\"/\")[-1]:24} {kind}')
"
```

**Expected** — exactly one entry point:

```
code-quality.yml         reusable
code-tests.yml           reusable
dependency-scan.yml      reusable
devsecops.yml            entry point
docker-push.yml          reusable
docker-scans.yml         reusable
secret-scanning.yml      reusable
sonar-scan.yml           reusable
```

✅ Pass: `devsecops.yml` is the only line reading `entry point`.

### 1.2 The Checkov gate fails closed

The gate script is the security boundary — prove it rejects a bad report rather than trusting it.

```bash
python3 -m venv /tmp/ckv && /tmp/ckv/bin/pip install --quiet checkov==3.4.10
mkdir -p /tmp/checkov
/tmp/ckv/bin/checkov -d kubernetes/ --framework kubernetes --compact \
  --output json --output-file-path /tmp/checkov
/tmp/ckv/bin/python scripts/check-checkov-report.py /tmp/checkov/results_json.json; echo "exit=$?"
```

**Expected:**

```
## Kubernetes Checkov gate

| Passed | Failed | Suppressed | Parse errors |
| ---: | ---: | ---: | ---: |
| 656 | 0 | 30 | 0 |

exit=0
```

Now prove it can fail — feed it a report with an unreasoned suppression:

```bash
python3 - <<'PY' > /tmp/bad.json
import json
print(json.dumps({"summary":{"passed":1,"failed":0,"skipped":1,"parsing_errors":0},
 "results":{"failed_checks":[],"skipped_checks":[
   {"check_id":"CKV_K8S_15","resource":"X","check_result":{"suppress_comment":""}}]}}))
PY
python3 scripts/check-checkov-report.py /tmp/bad.json; echo "exit=$?"
```

**Expected:** `Checkov gate failed: 1 suppression(s) without a reason: CKV_K8S_15` and `exit=1`.

✅ Pass: 656/0/30 with exit 0, **and** exit 1 on the bad report. The second is what makes the first meaningful.

### 1.3 ⚠️ The image-tag gap from §0.1 — see it, then fix it

```bash
kubectl -n elastiflix get pods -o wide
```

**Expected if you ran `bootstrap.sh` unchanged:**

```
NAME                        READY   STATUS             RESTARTS   AGE
backend-...                 0/1     ImagePullBackOff   0          2m
frontend-...                0/1     ImagePullBackOff   0          2m
```

That is §0.1 working as designed. **Local-only fix** (never commit this):

```bash
TAG=$(git rev-parse HEAD)
sed -i.bak "s|an619/elastiflix-backend:.*|an619/elastiflix-backend:${TAG}|" kubernetes/application/backend/deployment.yaml
sed -i.bak "s|an619/elastiflix-frontend:.*|an619/elastiflix-frontend:${TAG}|" kubernetes/application/frontend/deployment.yaml
kubectl apply -f kubernetes/application/
kubectl -n elastiflix rollout status deployment/backend --timeout=180s
kubectl -n elastiflix rollout status rollout/frontend --timeout=180s
```

**Expected:** `deployment "backend" successfully rolled out` and
`rollout "frontend" successfully rolled out`.

Restore when finished: `mv kubernetes/application/backend/deployment.yaml.bak kubernetes/application/backend/deployment.yaml` (same for frontend).

---

## Phase 2 — Kubernetes hardening

### 2.1 Pod Security Admission actually rejects

```bash
kubectl -n elastiflix run psa-probe --image=busybox:1.36 --restart=Never -- sleep 60
```

**Expected** — rejected, not created:

```
Error from server (Forbidden): pods "psa-probe" is forbidden: violates PodSecurity "restricted:latest":
allowPrivilegeEscalation != false (container "psa-probe" must set securityContext.allowPrivilegeEscalation=false),
unrestricted capabilities (container "psa-probe" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true, seccompProfile (pod or container "psa-probe" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

✅ Pass: `Forbidden ... violates PodSecurity "restricted:latest"`. Note your exact wording may
list the violations in a slightly different order — the verdict is what matters.

Repeat in a namespace that is audit-only, to see the difference:

```bash
kubectl -n elastic-stack run psa-probe --image=busybox:1.36 --restart=Never -- sleep 5
```

**Expected:** created successfully; the API server emits a **warning** on stderr containing
`would violate PodSecurity "restricted:latest"` but does not reject. Clean up:
`kubectl -n elastic-stack delete pod psa-probe --ignore-not-found`

### 2.2 Read-only root filesystem is real

```bash
kubectl -n elastiflix exec deploy/backend -- sh -c 'touch /usr/local/bin/x 2>&1; echo "rc=$?"'
kubectl -n elastiflix exec deploy/backend -- sh -c 'touch /tmp/x && echo "tmp writable"'
```

**Expected:**

```
touch: /usr/local/bin/x: Read-only file system
rc=1
tmp writable
```

✅ Pass: root is `EROFS`, `/tmp` is writable. This proves the `readOnlyRootFilesystem: true` +
`emptyDir` pairing is correct — a very common way to ship a pod that crash-loops.

### 2.3 Capabilities are dropped

```bash
kubectl -n elastiflix exec deploy/backend -- sh -c 'grep Cap /proc/self/status'
```

**Expected:** `CapEff:` and `CapPrm:` lines of **all zeros** (`0000000000000000`).

```bash
kubectl -n elastiflix exec deploy/backend -- id
```

**Expected:** `uid=1000 gid=1000` — never `uid=0`.

### 2.4 NetworkPolicy is enforced (Calico)

The default Minikube CNI accepts NetworkPolicy and ignores it; `bootstrap.sh` uses
`--cni=calico` for exactly this reason. Confirm you have Calico:

```bash
kubectl -n kube-system get pods -l k8s-app=calico-node -o name | head -3
```

**Expected:** at least one `pod/calico-node-...`.

Now the real test — backend must **not** reach something it has no egress rule for:

```bash
kubectl -n elastiflix exec deploy/backend -- \
  sh -c 'timeout 5 wget -qO- http://kibana.elastic-stack.svc.cluster.local:5601 2>&1 | head -2; echo "rc=$?"'
```

**Expected:** a timeout / `rc=124` (or a connection error) — **not** an HTML page. If you get
Kibana's HTML, Calico is not enforcing and every policy below is decorative.

And a path that **is** allowed, so you know the test isn't just "everything is blocked":

```bash
kubectl -n elastiflix exec deploy/backend -- sh -c 'timeout 5 nc -z redis.infra.svc.cluster.local 6379 && echo "redis reachable" || echo "nc unavailable or blocked"'
kubectl -n elastiflix exec deploy/backend -- sh -c 'timeout 5 nc -z elasticsearch.elastic-stack.svc.cluster.local 9200 && echo "es reachable" || echo "nc unavailable or blocked"'
```

**Expected:** `redis reachable` and `es reachable`.

⚠️ `nc` comes from busybox in `node:22-alpine`; if your image build differs you will see
`nc unavailable or blocked`. In that case use the app itself as the probe instead — a search that
returns results proves Redis and ES are both reachable:

```bash
kubectl -n elastiflix port-forward svc/backend 17700:17700 &
curl -s -X POST http://localhost:17700/api/search -H 'Content-Type: application/json' \
  -d '{"state":{"searchTerm":"matrix","current":1},"queryConfig":{"resultsPerPage":3}}' | head -c 300
```

**Expected:** JSON containing a `results` array with movie titles.

### 2.5 Inventory of what Phase 2 added

```bash
kubectl -n elastiflix get networkpolicy
kubectl -n elastiflix get hpa,pdb
```

**Expected:**

```
NAME              POD-SELECTOR   AGE
default-deny      <none>         ...
allow-dns-egress  <none>         ...
backend-egress    app=backend    ...
backend-ingress   app=backend    ...
frontend-egress   app=frontend   ...
frontend-ingress  app=frontend   ...

NAME                                          REFERENCE            TARGETS         MINPODS  MAXPODS  REPLICAS
horizontalpodautoscaler.autoscaling/backend   Deployment/backend   cpu: 1%/70%     2        6        ...
horizontalpodautoscaler.autoscaling/frontend  Rollout/frontend     cpu: 2%/70%     2        6        ...

NAME                            MIN AVAILABLE   ALLOWED DISRUPTIONS
poddisruptionbudget/backend     1               1
poddisruptionbudget/frontend    1               1
```

⚠️ `TARGETS` shows `<unknown>/70%` for a minute or two until metrics-server warms up. If it stays
`<unknown>` for more than ~2 minutes, `minikube addons enable metrics-server` is missing.

✅ Pass: six NetworkPolicies, two HPAs reading a real percentage, two PDBs with
`ALLOWED DISRUPTIONS` ≥ 0.

### 2.6 Proof the policies would reject a broken manifest

Cheap and conclusive — ask the API server to validate a privileged pod:

```bash
kubectl -n elastiflix apply --dry-run=server -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: evil}
spec:
  hostPID: true
  containers:
    - name: evil
      image: busybox
      securityContext: {privileged: true}
      command: ["sleep","10"]
YAML
```

**Expected:** `Error ... violates PodSecurity "restricted:latest": host namespaces (hostPID=true), privileged (container "evil" must not set securityContext.privileged=true) ...`

---

## Phase 3 — Terraform and AWS

**Nothing in Phase 3 runs on Minikube.** It is infrastructure. Validate it offline here, and
defer the real apply to §8.

### 3.1 Format and validate, no AWS creds needed

```bash
cd terraform
terraform init -backend=false
terraform fmt -check -recursive . && echo "fmt: clean"
terraform validate
```

**Expected:**

```
fmt: clean
Success! The configuration is valid.
```

✅ Pass: no diff from `fmt` (CI fails on any diff) and `Success!`.

### 3.2 Aliasing and state changes are visible in the plan

```bash
terraform plan -var-file=environments/dev.tfvars.example 2>&1 | tail -30
```

**Expected:** a plan summary ending in `Plan: N to add, 0 to change, 0 to destroy.` and, in the
body, `aws_eks_cluster` with `endpoint_public_access = false` (the default; §0 of Phase 3 in
`docs/security/phase-3-*.md`). ⚠️ This needs real AWS credentials and will fail with
`No valid credential sources found` if you have none — that is the expected outcome without an
account, and it does **not** mean the config is broken (step 3.1 already proved that).

### 3.3 The ALB policy is scoped, not full-access

```bash
python3 -c "
import json; p=json.load(open('policies/aws-load-balancer-controller-v2.7.2.json'))
print('statements:', len(p['Statement']))
print('full-access strings present:', any('ElasticLoadBalancingFullAccess' in json.dumps(s) for s in p['Statement']))
"
```

**Expected:** a statement count (nonzero) and `False`.

✅ Pass: `False` — the broad managed policy is gone.

---

## Phase 4 — GitOps and progressive delivery

### 4.1 Argo CD is reconciling

```bash
kubectl -n argocd get applications
```

**Expected:**

```
NAME            SYNC STATUS   HEALTH STATUS
elastic-stack   Synced        Healthy
elastiflix      Synced        Healthy
infra-databases Synced        Healthy
monitoring      Synced        Healthy
namespaces      Synced        Healthy
```

⚠️ Because of §0.2, `elastiflix` will report `Synced` against **`main`'s** manifests, which
reference the `30703b0` tag. If `main`'s images do not exist in your local daemon you will see
`Healthy` but pods in `ImagePullBackOff`; that combination is §0.1, not a GitOps failure.

### 4.2 A drift is actually healed

```bash
kubectl -n elastiflix scale deployment/backend --replicas=5
sleep 20
kubectl -n elastiflix get deployment backend -o jsonpath='{.spec.replicas}{"\n"}'
```

**Expected:** you set `5`; `selfHeal: true` puts it back. The second command prints **`2`**
(the manifest value, or the HPA's min). This is the single best proof that GitOps is live.

### 4.3 The canary ladder is real

```bash
kubectl argo rollouts get rollout frontend -n elastiflix --watch
```

**Expected** — four steps, with an AnalysisRun after each of the first three:

```
Status:          ✔ Healthy
Strategy:        Canary
  Step:          7/7
  ...
  ✔    1  Set Weight 10%
  ✔    2  Pause 30s
  ✔    3  Analysis: frontend-canary-health  ✔
  ✔    4  Set Weight 25%
  ...
```

✅ Pass: weights `10 / 25 / 50 / 100` and three analysis runs. ⚠️ The analysis **fails closed**
if Prometheus has no data: `successCondition: result[0] > 0` with
`or vector(0)` means "no traffic ⇒ 0 ⇒ fail". So generate traffic (Phase 5.4) before triggering
a canary, or the rollout aborts by design.

### 4.4 Force an abort (the interesting one)

```bash
# in one shell
kubectl argo rollouts get rollout frontend -n elastiflix --watch

# in another: simulate a broken image
kubectl argo rollouts set image frontend frontend=an619/elastiflix-frontend:does-not-exist -n elastiflix
```

**Expected:** the pod goes `ImagePullBackOff`, the rollout sticks at the current step and then
reports `Degraded`/`Progressing: false`; **stable traffic is unaffected** — the `frontend` Service
still points at the old ReplicaSet. Undo with:

```bash
kubectl argo rollouts undo frontend -n elastiflix
```

✅ Pass: `kubectl -n elastiflix get pods -l app=frontend` continues serving; the rollouts UI shows
`✖ Degraded` rather than a bad release going live.

### 4.5 AppProject scoping is enforced

```bash
kubectl -n argocd get appproject elastiflix -o yaml | grep -A5 "namespaceResourceBlacklist"
```

**Expected:** `ResourceQuota` and `LimitRange` listed as blacklisted — Argo CD refuses to manage
them, which is why they are not in this repo.

---

## Phase 5 — Observability and SRE

### 5.1 The scrape target is actually up

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
sleep 3
curl -s 'http://localhost:9090/api/v1/query?query=up{job=~".*backend.*"}' | python3 -m json.tool | head -30
```

**Expected:** `"value": ["<ts>", "1"]` — a `1` means Prometheus reached `/metrics`. A `0` or an
empty `"result": []` means one of the three prerequisites in the header comment of
`kubernetes/monitoring/observability.yaml` is unmet (selector, port name, NetworkPolicy).

Check the three directly if it fails:

```bash
kubectl -n elastiflix get svc backend -o jsonpath='{.spec.ports[*].name}{"\n"}'   # want: http
kubectl -n monitoring get servicemonitor elastiflix-backend -o jsonpath='{.metadata.labels}{"\n"}'  # want: release=monitoring
```

### 5.2 The metrics the SLO rules depend on exist

```bash
curl -s 'http://localhost:9090/api/v1/query?query=elastiflix:error_ratio:rate5m' | python3 -m json.tool
```

**Expected:** a `"result"` array with one series and a numeric value (`0` when there are no
errors). Empty `result: []` means the recording rule is loaded but its input series is absent.

### 5.3 Rules are loaded, alerts are evaluable

```bash
curl -s http://localhost:9090/api/v1/rules | python3 -c "
import json,sys
d=json.load(sys.stdin)['data']['groups']
for g in d:
    for r in g['rules']:
        if r['name'].startswith(('elastiflix','Elastiflix')):
            print(f\"{g['name']:28} {r['type']:8} {r['name']}\")"
```

**Expected:** 6 alerts and 10 recording rules, names beginning `Elastiflix…` and `elastiflix:…`.

⚠️ `Alertmanager` is **disabled** (`enabled: false` in `argocd-monitoring.yaml`), so alerts will
show as firing in Prometheus but nothing pages. That is deliberate — see §9 of the audit report.

### 5.4 Generate load so the SLO series have data

`generate-traffic.sh` defaults to `http://localhost:17700`, so it must be pointed at the cluster
(and the backend must be reachable from your shell — `kubectl port-forward` is the simplest way):

```bash
kubectl -n elastiflix port-forward svc/backend 17700:17700 &
API=http://localhost:17700/api/search ./generate-traffic.sh 3
```

**Expected:** `==> Sending 54 searches to http://localhost:17700/api/search`, then silent
successes (the script discards bodies). Within ~2 minutes `elastiflix:requests:rate5m` becomes
non-zero when you re-run the 5.2 query.

⚠️ Without `API=`, the script targets localhost and does nothing for the cluster — a silent
no-op that looks like "traffic didn't reach Prometheus".

### 5.5 The dashboard renders

```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80 &
open http://localhost:3000   # or just browse
```

**Expected:** log in as `admin` with:

```bash
kubectl -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Under Dashboards → General you should find the Elastiflix SLO dashboard with populated panels.
⚠️ The secret name and the Grafana service name both come from the Helm release name
(`monitoring`). If your release differs, find them with
`kubectl -n monitoring get svc,secret | grep grafana`.

### 5.6 The offline validator still agrees

```bash
python3 -m venv /tmp/obs && /tmp/obs/bin/pip install --quiet PyYAML promql-parser
/tmp/obs/bin/python scripts/validate-observability.py
```

**Expected:** `Validated 37 Kubernetes YAML files: 16 Prometheus rules (6 alerts, 10 recording rules), 1 ServiceMonitor(s), 1 dashboard(s) with 9 PromQL panel queries.`

---

## Phase 6 — Backup and disaster recovery

⚠️ **The snapshot client speaks to Elasticsearch over HTTPS with a CA and an API key**
(`ES_URL`, `ES_API_KEY_FILE`, `ES_CA_FILE` are all required). The in-cluster demo ES has
`xpack.security` **disabled**, so this exact path cannot run against it as written. Two honest
options:

**Option A — verify the client's logic offline (what CI does):**

```bash
bash scripts/test-elasticsearch-snapshot.sh
```

**Expected:** a series of `ok`-style lines and a final success message, exit code 0. This proves
argument handling, auth-header construction, and the "refuse to overwrite an existing index"
guard without needing a live cluster.

**Option B — prove the storage layer works in-cluster** (S3 is not reachable from Minikube without
`minio`, so use a filesystem repository):

```bash
kubectl -n elastic-stack exec statefulset/elasticsearch -- \
  curl -s -XPUT 'http://localhost:9200/_snapshot/fs_backup' \
  -H 'Content-Type: application/json' \
  -d '{"type":"fs","settings":{"location":"/usr/share/elasticsearch/data/snapshots"}}'
```

**Expected:** `{"acknowledged":true}`.

```bash
kubectl -n elastic-stack exec statefulset/elasticsearch -- \
  curl -s -XPUT 'http://localhost:9200/_snapshot/fs_backup/snap-1?wait_for_completion=true'
```

**Expected:** JSON containing `"accepted":true` and, once complete, `"state":"SUCCESS"`.

```bash
kubectl -n elastic-stack exec statefulset/elasticsearch -- \
  curl -s 'http://localhost:9200/_snapshot/fs_backup/_all'
```

**Expected:** `"snapshots":[{"snapshot":"snap-1",...,"state":"SUCCESS"...}]`

✅ Pass: a snapshot reaches `SUCCESS` and is listed. This is the real DR mechanism; only the
transport differs from production (filesystem here, S3 on EKS).

Then test the restore guard, which is the part that protects you:

```bash
kubectl -n elastic-stack exec statefulset/elasticsearch -- \
  curl -s -XPOST 'http://localhost:9200/_snapshot/fs_backup/snap-1/_restore' \
  -H 'Content-Type: application/json' -d '{"indices":"elastiflix-movies"}'
```

**Expected:** an error mentioning `cannot restore index [elastiflix-movies] because an open index with same name already exists`. That refusal is the designed behaviour — the script and the docs both say a restore targets a new index only.

---

## Phase 7 — FinOps

No cluster involvement; this is Terraform + AWS Budgets. The code can be reviewed without an
account, the delivery needs one.

```bash
cd terraform/finops
terraform init -backend=false
terraform validate && echo "finops: valid"
grep -n "budget_type\|limit_amount\|notification" *.tf | head -20
```

**Expected:** `finops: valid`, and a `COST` budget with a limit plus subscriber blocks.

✅ Pass: config validates and defines a budget with at least one notification. Actual delivery
(`aws budgets describe-budget`) requires the EKS step in §8.

---

## 8. Migration to EKS

Run only after Phase 3.1 passes. **This creates billable AWS resources.**

```bash
cd terraform
cp environments/dev.tfvars.example dev.tfvars        # gitignored; never commit
terraform init -backend-config=environments/dev.backend.hcl.example
terraform apply -var-file=dev.tfvars
terraform output
```

**Expected:** these seven outputs (`terraform output` names only):
`bastion_ssm_command`, `configure_kubectl`, `eks_cluster_name`, `cluster_endpoint_public_access_cidrs`,
`alb_controller_role_arn`, `eso_role_arn`, `ebs_csi_role_arn`.

⚠️ There is **no** `cluster_endpoint` or `cluster_name` output — the names are `eks_cluster_name`
and the endpoint comes from `configure_kubectl`. An earlier draft of this runbook named outputs
that do not exist.
The EKS API is **private by default** — you reach it through the SSM bastion, not your laptop.
That is why the next steps belong in a bastion session.

Then, in the bastion:

```bash
ansible-playbook ansible/playbook.yml
```

**Expected:** five task changes: Helm repos added, Argo CD installed, ESO installed, ALB SA
created, ALB SA annotated, ALB controller installed.

⚠️ **Known gap (audit finding A3):** the playbook pins **no chart versions** and hard-codes
`elastiflix-eks` / `elastiflix-alb-role`. It works only if you kept Terraform's default
`cluster_name = "elastiflix"`. If you changed it, edit those two literals first or the ALB
controller will have no valid IRSA role.

Then verify the EKS-specific paths:

```bash
# EKS audit logging is on by default in the module (audit, api, authenticator).
# Take the name from Terraform rather than repeating the literal that A3 warns about:
CLUSTER=$(terraform -chdir=terraform output -raw eks_cluster_name)
aws eks describe-cluster --name "$CLUSTER" \
  --query 'cluster.logging.clusterLogging[?enabled==`true`].types' --output json

# Secrets come from AWS Secrets Manager via ESO, not from local Secrets
kubectl -n external-secrets get pods
kubectl get clustersecretstore aws-secretsmanager

# The ALB ingress (kubernetes/aws/) is NOT deployed by any Application - audit finding A2.
# If you apply it, add a host: and consider scheme: internal first.
kubectl get ingress -A
```

**Expected:** the log types list contains `audit`; ESO pods `Running`; the ClusterSecretStore
exists. `kubectl get ingress -A` will show **no ALB ingress** unless you applied
`kubernetes/aws/ingress-aws.yaml` by hand — that directory is referenced by nothing.

---

## 9. Scorecard — fill this in as you go

| Phase | Check | Minikube | EKS |
| --- | --- | --- | --- |
| 1 | Only `devsecops.yml` is an entry point | ☐ | n/a |
| 1 | Checkov gate 656/0/30, exit 0 | ☐ | n/a |
| 1 | Gate exits 1 on an unreasoned suppression | ☐ | n/a |
| 1 | ⚠️ image-tag mismatch observed, then overridden locally | ☐ | n/a |
| 2 | PSA rejects a privileged pod in `elastiflix` | ☐ | ☐ |
| 2 | `elastic-stack` warns but admits | ☐ | ☐ |
| 2 | Root FS is `EROFS`, `/tmp` writable | ☐ | ☐ |
| 2 | `CapEff` is all zeros, uid 1000 | ☐ | ☐ |
| 2 | Calico present; blocked path times out | ☐ | (AWS VPC CNI — see note) |
| 2 | Allowed paths (redis, ES) reachable | ☐ | ☐ |
| 2 | 6 NetworkPolicies, 2 HPAs with real %, 2 PDBs | ☐ | ☐ |
| 3 | `fmt -check` clean, `validate` succeeds | ☐ | ☐ |
| 3 | ALB policy is not full-access | ☐ | ☐ |
| 4 | All 5 Applications `Synced`/`Healthy` | ☐ | ☐ |
| 4 | Manual scale reverts to 2 (selfHeal proven) | ☐ | ☐ |
| 4 | Ladder 10/25/50/100 with 3 analyses | ☐ | ☐ |
| 4 | Broken image aborts canary, stable keeps serving | ☐ | ☐ |
| 5 | `up{job="…backend…"} == 1` | ☐ | ☐ |
| 5 | `elastiflix:error_ratio:rate5m` returns a number | ☐ | ☐ |
| 5 | 6 alerts + 10 recording rules loaded | ☐ | ☐ |
| 5 | SLO dashboard renders with data | ☐ | ☐ |
| 6 | Offline client test passes | ☐ | n/a |
| 6 | Snapshot reaches `SUCCESS` | ☐ | ☐ |
| 6 | Restore into an existing index is refused | ☐ | ☐ |
| 7 | FinOps config validates, budget defined | ☐ | ☐ |
| — | EKS audit logs enabled | n/a | ☐ |
| — | ESO + ClusterSecretStore present | n/a | ☐ |

**AWS CNI note:** on EKS the default VPC CNI **does** enforce NetworkPolicy in recent versions,
but the install is not guaranteed — run the same 2.4 blocked-path test there before trusting it.

---

## 10. If something fails, check these first

| Symptom | Most likely cause | Check |
| --- | --- | --- |
| `ImagePullBackOff` | §0.1 tag mismatch | `kubectl -n elastiflix describe pod … \| grep Image:` |
| Every NetworkPolicy seems ignored | CNI is not Calico | `kubectl -n kube-system get pods -l k8s-app=calico-node` |
| HPA shows `<unknown>` | metrics-server absent | `minikube addons list \| grep metrics` |
| Canary aborts immediately | Prometheus has no data (fails closed) | §5.1, then §5.4 |
| Canary analysis error `no such host` | `monitoring` namespace or Prometheus service name differs | `kubectl -n monitoring get svc \| grep prometheus` |
| Argo CD reverts your edits | `selfHeal: true` + targets `main` | §0.2 |
| `host not found` in browser | `/etc/hosts` or `minikube tunnel` | §0.4 |
| Grafana 404 | wrong service name for your chart version | `kubectl -n monitoring get svc` |

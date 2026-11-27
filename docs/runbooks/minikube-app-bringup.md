# Bring up the full application on Minikube — commands, expected output, and the fixes

**Companion to** `phase-validation-minikube-to-eks.md` (that one proves the *security controls*;
this one proves the *product*: can a user search for a movie?).

Read §0 first. There are four things in this repo that will each stop the app from serving
results, and **all four are already known and diagnosed** — §1–§4 of this document are the exact
symptom you will see, why it happens, and the one-line fix. Walk them in order and you will get to
a working search box without guessing.

---

## 0. The four known blockers, in the order you will hit them

| # | Symptom you will see | Cause (verified in the tree) | Fix |
| --- | --- | --- | --- |
| **B1** | Both app pods `ImagePullBackOff` | Manifests pin tag `30703b0`; `bootstrap.sh` builds `$(git rev-parse HEAD)` | **Fixed in `bootstrap.sh` step 9** — it now renders a local-tagged overlay and sets the Application to manual sync. §2 is the manual equivalent |
| **B2** | Backend up, every search returns 0 results; `_cat/indices` has no `elastiflix-movies` | Logstash init container downloads the catalogue from **`raw.githubusercontent.com/.../main/`** at pod start, which a NetworkPolicy or a flaky network can block | **Improved** — the URL is now a `CATALOGUE_URL` env var and a failed download exits with an explanatory error instead of silently indexing nothing. §3 is still the fix path |
| **B3** | Page loads, every `/api/search` returns **502** | `frontend/nginx.conf` hardcoded `resolver 127.0.0.11` — **Docker's** embedded DNS, not Kubernetes' | **Fixed in `frontend/nginx.conf`** — the directive is gone, so nginx uses the pod resolver. §4 remains only for images built before this change |
| **B4** | Rule evaluation shows no `elastiflix:*` series | Same tag mismatch applies to the backend `ServiceMonitor`? No — see §5; this one only appears if you skipped B2 | §5 |

B2 and B3 are the interesting ones: **the pods are green while the application is broken.** That is
exactly the class of failure the phase runbook cannot catch, which is why this document exists.

---

## 1. Preflight — fail fast before a 10-minute install

```bash
minikube version && kubectl version --client && helm version --short && docker version --format '{{.Server.Version}}'
```

**Expected:** four versions print. If `docker` says `Cannot connect to the Docker daemon`, start
Docker Desktop first — `minikube start` will fail confusingly otherwise.

```bash
docker info --format '{{.MemTotal}}' | awk '{print $1/1024/1024/1024 " GiB to Docker"}'
```

**Expected:** ≥ 9 GiB. `bootstrap.sh` asks Minikube for 7.5 GB **in addition** to Docker's own
overhead; a 16 GB machine is comfortable, 8 GB will thrash.

```bash
git rev-parse --short HEAD && grep -rn "image: an619" kubernetes/application/*/deployment.yaml | sed 's/.*image: //'
```

**Expected on this branch** — note the mismatch, that is B1:

```
bf90d4f
an619/elastiflix-backend:30703b0142e155085ba428b208d97fe54c089562
an619/elastiflix-frontend:30703b0142e155085ba428b208d97fe54c089562
```

---

## 2. Bootstrap the cluster (≈10 minutes, mostly download)

```bash
./bootstrap.sh 2>&1 | tee /tmp/bootstrap.log
```

**Expected, in order:**

```
🚀 1. Starting Minikube...
🐳 2. Building and loading local images...
📦 3. Installing Argo CD v3.6.3...
⏳ 4. Waiting for Argo CD to be ready...
deployment.apps/argocd-server condition met
🔧 5. Configuring Argo CD...
🚀 6. Installing Argo Rollouts v1.10.2...
🦅 7. Installing Falco (runtime security)...
🔐 7b. Installing SealedSecrets controller v0.27.3...
🔑 7c. Creating local Secrets for Minikube (no ESO / AWS on this cluster)...
🔄 8. Deploying Argo CD project and Applications (GitOps)...
✅ Bootstrap complete. Argo CD 3.6.3, Rollouts v1.10.2, Falco 9.2.2.
🔑 Argo CD: http://argocd.local | user: admin
   initial password: <32 hex chars>
```

**Save that password now** — it is generated per-bootstrap:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

### 2.1 Watch what happens next — this is where B1 appears

Argo CD immediately starts syncing `main`, whose manifests carry the `30703b0` tag. Your local
daemon has the `bf90d4f`-tagged images instead.

```bash
kubectl -n elastiflix get pods -w
```

**Expected within ~60s:**

```
NAME                        READY   STATUS             RESTARTS   AGE
backend-6d9f...             0/1     ImagePullBackOff   0          45s
frontend-7c8b...            0/1     ImagePullBackOff   0          45s
```

❌ **That is B1.** Confirm the diagnosis rather than assuming it:

```bash
kubectl -n elastiflix describe pod -l app=backend | grep -A3 "Events:"
```

**Expected:**

```
Events:
  Type     Reason     Age   From               Message
  ----     ------     ----  ----               -------
  Normal   Pulling    30s   kubelet            Pulling image "an619/elastiflix-backend:30703b..."
  Warning  Failed     28s   kubelet            Failed to pull image "...:30703b...": ... not found
```

### 2.2 Fix B1 — point the manifests at the images you actually built

This is a **local-only** edit. Do not commit it.

```bash
TAG=$(git rev-parse HEAD)
cp kubernetes/application/backend/deployment.yaml  /tmp/backend.yaml.bak
cp kubernetes/application/frontend/deployment.yaml /tmp/frontend.yaml.bak
sed -i "s|an619/elastiflix-backend:.*|an619/elastiflix-backend:${TAG}|"   kubernetes/application/backend/deployment.yaml
sed -i "s|an619/elastiflix-frontend:.*|an619/elastiflix-frontend:${TAG}|"  kubernetes/application/frontend/deployment.yaml
kubectl apply -f kubernetes/application/
```

**Expected:**

```
deployment.apps/backend configured
rollout.argoproj.io/frontend configured
```

⚠️ Argo CD has `selfHeal: true` and targets `main`, so it will revert this edit on its next
reconcile (default 3 minutes). Either disable auto-sync for the length of your test:

```bash
kubectl -n argocd patch application elastiflix --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

…or accept re-applying after each revert. Disabling is cleaner for a test run.

```bash
kubectl -n elastiflix rollout status deployment/backend --timeout=180s
kubectl -n elastiflix rollout status rollout/frontend --timeout=180s
```

**Expected:**

```
deployment "backend" successfully rolled out
rollout "frontend" successfully rolled out
```

---

## 3. B2 — the catalogue never loads (the subtle one)

At this point pods are `Running`, the UI loads, and **every search returns nothing**. Do not debug
the frontend; check the data first.

### 3.1 Confirm the index is missing

```bash
kubectl -n elastic-stack exec statefulset/elasticsearch -- curl -s 'http://localhost:9200/_cat/indices?v'
```

**Expected (broken):**

```
health status index uuid pri rep docs.count ...
```

…and **no `elastiflix-movies` row**. There may be a `logs-*` row if Filebeat is shipping.

### 3.2 Confirm why

```bash
kubectl -n elastic-stack logs logstash-0 -c prepare-data 2>&1 | tail -5
```

**Expected (broken):**

```
Downloading movies.json.gz...
wget: can't connect to remote host (140.82.x.x): Connection timed out
```

and the real Logstash container:

```bash
kubectl -n elastic-stack logs logstash-0 -c logstash 2>&1 | grep -i "movies\|error" | head -5
```

**Expected:** `[ERROR][logstash.javapipeline] ... pipeline has terminated` or simply nothing about
movies, because `/data/movies.ndjson` does not exist.

### 3.3 Why it happens

`kubernetes/elastic-stack/network-policy.yaml` gives Logstash egress to
`elasticsearch:9200` and to **443 on non-RFC1918 addresses only**:

```yaml
- to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16]
  ports: [{ protocol: TCP, port: 443 }]
```

The rule *does* permit 443 to public addresses, and the namespace has an `allow-dns-egress`
policy — so in principle this should work. In practice two things break it, and they look
identical from the pod, so test both before concluding:

```bash
# (a) can it resolve?
kubectl -n elastic-stack exec statefulset/elasticsearch -- nslookup raw.githubusercontent.com 2>&1 | tail -3
# (b) can it reach it?
kubectl -n elastic-stack run nettest --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -T5 -qO- https://raw.githubusercontent.com/An619/Elastiflix/main/data-loader/movies/movies.json.gz 2>&1 | head -2
```

- If (a) fails → the **DNS egress** rule is the problem.
- If (a) passes and (b) times out → the **443 egress** rule is the problem.

### 3.4 Fix — load the catalogue from your local checkout instead of the internet

This is strictly better than punching a hole in the policy: the file is already in your repo
(8.0 MB, verified to exist on `main`), so no egress is needed at all.

```bash
# 1. make the ndjson from the repo copy
python3 - <<'PY'
import gzip, json
movies = json.load(gzip.open("data-loader/movies/movies.json.gz", "rt", encoding="utf-8"))
with open("/tmp/movies.ndjson", "w", encoding="utf-8") as f:
    for m in movies:
        f.write(json.dumps(m, ensure_ascii=False) + "\n")
print(f"{len(movies)} movies -> /tmp/movies.ndjson")
PY
```

**Expected:** `6959 movies -> /tmp/movies.ndjson` (the count is in the repo's own pipeline comment).

```bash
# 2. copy it onto the Logstash PVC
POD=$(kubectl -n elastic-stack get pod -l app=logstash -o jsonpath='{.items[0].metadata.name}')
kubectl -n elastic-stack cp /tmp/movies.ndjson "$POD:/data/movies.ndjson" -c logstash
```

**Expected:** `tar: Removing leading / from member names` (harmless), then no error.

```bash
# 3. restart the pipeline so the file input picks it up
kubectl -n elastic-stack rollout restart deployment/logstash
kubectl -n elastic-stack rollout status deployment/logstash --timeout=300s
```

**Expected:** `deployment "logstash" successfully rolled out`.

```bash
# 4. wait for ingestion, then confirm
sleep 60
kubectl -n elastic-stack exec statefulset/elasticsearch -- curl -s 'http://localhost:9200/_cat/indices?v&h=index,docs.count'
```

**Expected:**

```
index               docs.count
elastiflix-movies   6959
logs-...            ...
```

✅ **B2 fixed** when `elastiflix-movies` shows a nonzero `docs.count`.

⚠️ Note: `kubectl cp` into a container running as uid 1000 works, but if `/data` is not writable
you will see `Permission denied`. In that case use the init container's own approach with a
reachable URL, or `kubectl -n elastic-stack exec` a `python3` one-liner reading from stdin.

---

## 4. B3 — the UI loads, searches return 502

With the index populated, the frontend still cannot proxy to the backend.

### 4.1 See it

```bash
kubectl -n elastiflix get ingress app-ingress
```

**Expected:**

```
NAME          CLASS   HOSTS                                  ADDRESS        PORTS   AGE
app-ingress   nginx   elastiflix.local,api.elastiflix.local  192.168.49.2   80      ...
```

⚠️ `ADDRESS` may be empty until `minikube tunnel` runs. Start it in a second terminal **as
Administrator** (Windows) or with `sudo` (Linux):

```bash
minikube tunnel
```

The ingress is host-based, so `elastiflix.local` has to resolve to the cluster before a browser can
use it. Add the hosts once (Linux / macOS / WSL):

```bash
echo "$(minikube ip) elastiflix.local api.elastiflix.local kibana.local grafana.local argocd.local" | sudo tee -a /etc/hosts
```

On Windows the file is `C:\Windows\System32\drivers\etc\hosts` and needs an Administrator
editor. `verify-deployment.sh` reports `elastiflix.local resolves` as **SKIP** when the entry is
missing, which is why a verdict with skips is weaker than one without.

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://elastiflix.local/api/search \
  -H 'Content-Type: application/json' \
  -d '{"state":{"searchTerm":"matrix","current":1},"queryConfig":{"resultsPerPage":3}}'
```

**Expected (broken):** `502`

### 4.2 Confirm the cause

```bash
kubectl -n elastiflix logs deploy/frontend --tail=20 | grep -i "resolv\|connect\|upstream" | head -5
```

**Expected (broken):**

```
[error] 31#31: *5 connect() failed (111: Connection refused) while connecting to upstream,
  client: ..., server: _, request: "POST /api/search HTTP/1.1",
  upstream: "http://127.0.0.11:17700/api/search"
```

Note the upstream address: **`127.0.0.11`**. That is Docker Desktop's internal DNS server. In
Kubernetes the pod resolver is `10.96.0.10`, so the directive points nginx at an address that does
not exist in the cluster. The file is `frontend/nginx.conf:13`:

```nginx
location /api/ {
    resolver 127.0.0.11 valid=30s;      # ← Docker-only
    proxy_pass http://backend:17700/api/;
```

### 4.3 Fix — for testing, correct the resolver in a local-only image patch

Two options; pick by how much you want to invest.

**Option A (fastest, no rebuild): let nginx use the pod's own resolver.**
Kubernetes writes `/etc/resolv.conf` in every pod with the correct nameserver. Removing the
`resolver` line makes nginx resolve `backend` once at startup via the system resolver, which is
correct for a non-changing Service:

```bash
kubectl -n elastiflix exec deploy/frontend -- sh -c 'sed -i "s|resolver 127.0.0.11 valid=30s;|resolver $(awk "/^nameserver/{print \$2; exit}" /etc/resolv.conf) valid=30s;|" /etc/nginx/conf.d/default.conf && nginx -s reload && echo reloaded'
```

**Expected:** `reloaded`, immediately followed by:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://elastiflix.local/api/search \
  -H 'Content-Type: application/json' -d '{"state":{"searchTerm":"matrix","current":1},"queryConfig":{"resultsPerPage":3}}'
```

**Expected:** `200`

⚠️ This edit is lost on pod restart. For a durable fix, patch the ConfigMap the image ships, or
rebuild — that is the **actual product bug** and it belongs in `frontend/nginx.conf`, not in a
cluster. See §7.

**Option B (durable, requires rebuild):** change the line in `frontend/nginx.conf` to
`resolver kube-dns.kube-system.svc.cluster.local valid=30s;`, rebuild, reload into Minikube. This is
the change I would commit — but it is a product change and needs review, so it is **not** applied
in this branch.

---

## 5. Prove the application actually works

> Starting from a fresh clone rather than debugging a broken one? `docs/runbooks/getting-started-local.md`
> is the condensed path from clone to verified deployment; this document is the diagnostic version.

### 5.0 One command instead of all of the below

```bash
./scripts/verify-deployment.sh
```

43 checks across ten groups: cluster/tooling, workloads, catalogue ingestion, API behaviour,
frontend proxy, ingress/DNS, metrics and SLO plumbing, live security controls, GitOps state, and a
smoke test. Each line is `PASS`, `FAIL` or `SKIP` with the evidence that produced it.

```
Result: 40 passed, 0 failed, 3 skipped (of 43)
Deployment is WORKING — 3 check(s) skipped, see above.
```

Exit code is `0` only when nothing failed, so it is usable in a pipeline. Flags:
`--verbose` (show each command's output), `--json` (machine-readable; stdout is a single JSON
document), `--quick` (skip the slow index checks).

**`SKIP` is not a pass.** A skipped check could not be evaluated here — no `minikube tunnel`, for
example — and the summary says how many were skipped so a "WORKING" verdict with 20 skips is
visibly weaker than one with none.

The sections below are the manual equivalent, kept because when a check fails you will want to run
its command by hand and see the full output.

### 5.1 The backend answers directly

```bash
kubectl -n elastiflix port-forward svc/backend 17700:17700 &
curl -s http://localhost:17700/healthz; echo
curl -s http://localhost:17700/ | head -c 40; echo
```

**Expected:**

```
OK
Hello from the backend!
```

### 5.2 A real search returns real movies

```bash
curl -s -X POST http://localhost:17700/api/search \
  -H 'Content-Type: application/json' \
  -d '{"state":{"searchTerm":"matrix","current":1},"queryConfig":{"resultsPerPage":3}}' \
  | python3 -m json.tool | head -40
```

**Expected:** a JSON object with `results` and `totalResults` where

- `totalResults` is ≥ 1 — the catalogue has **6,959** documents and `matrix` matches **6 titles**
  (`The Matrix Revisited`, `The Matrix Resurrections`, `The Animatrix`, `The Matrix Revolutions`, …),
- those titles appear in the `results` array. The source titles do **not** include a plain
  "The Matrix", so do not treat its absence as a failure.

❌ If `totalResults` is `0`, you are at B2 (§3) — the index exists but is empty, or the query is
hitting a different index. Confirm with:

```bash
kubectl -n elastiflix exec deploy/backend -- wget -qO- 'http://elasticsearch.elastic-stack.svc.cluster.local:9200/elastiflix-movies/_count'
```

**Expected:** `{"count":6959,...}`

### 5.3 All four search modes respond

```bash
for mode in search rerank/search semantic/search hybrid/search; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:17700/api/$mode" \
    -H 'Content-Type: application/json' \
    -d '{"state":{"searchTerm":"batman","current":1},"queryConfig":{"resultsPerPage":2}}')
  echo "$mode -> $code"
done
```

**Expected:**

```
search -> 200
rerank/search -> 200
semantic/search -> 200
hybrid/search -> 200
```

⚠️ `semantic` and `hybrid` need the ELSER/E5 inference pipelines. On a single-node demo ES without
a trained model deployed, these can return **200 with empty results** or a `400` naming the missing
pipeline. That is a data-loader concern (`data-loader/config/inference_*.json`), not a
misconfiguration. Record which you get — do not assume a 200 means semantic search works.

### 5.4 The UI itself

```bash
curl -s http://elastiflix.local/ | grep -o '<title>[^<]*</title>'
```

**Expected:** `<title>Elastiflix</title>` (or the app's title).

Then in a browser: `http://elastiflix.local` → type `matrix` → results appear. That is the
end-to-end product test, and it exercises B1–B3 simultaneously.

### 5.5 Metrics are flowing (feeds Phase 5 and the canary)

```bash
kubectl -n elastiflix exec deploy/backend -- wget -qO- http://localhost:17700/metrics | head -12
```

**Expected:** text exposition starting `# HELP elastiflix_http_responses_total`, and after a few
searches a `elastiflix_http_responses_total{route="/api/search",status_class="2xx",...} N` line.

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
sleep 3
curl -s 'http://localhost:9090/api/v1/query?query=elastiflix:requests:rate5m' | python3 -m json.tool | head -20
```

**Expected:** one series with a value > 0 once you have searched. If `result` is `[]`, see §5 of
the phase runbook (ServiceMonitor selector / port name / NetworkPolicy).

---

## 6. Truth table — what each state means

| UI | `_count` | `/api/search` | Meaning |
| --- | --- | --- | --- |
| loads | missing index | 200, 0 results | **B2** — catalogue never ingested |
| loads | 6959 | 502 | **B3** — nginx resolver |
| blank / 502 | 6959 | 200 | frontend build or ingress problem, not backend |
| loads | 6959 | 200 with results | **working** |
| error page | — | connection refused | pods not running → **B1** |

---

## 7. What I would fix in the repo (needs your approval)

These are product defects, not test-harness problems. I have **not** changed them.

1. **`frontend/nginx.conf:13`** — `resolver 127.0.0.11` is Docker-only. Correct value for
   Kubernetes is `kube-dns.kube-system.svc.cluster.local`, or drop the directive and let nginx use
   the pod resolver. **This is the single highest-value one-line fix in this document**; until it
   lands, only Option A above makes the UI work in-cluster.
2. **Logstash init container** downloads the catalogue from `raw.githubusercontent.com`. Either
   ship the ndjson in an image/ConfigMap, or add an explicit egress rule. Downloading 8 MB from
   `main` at every pod start is also non-reproducible: the data can change under you.
3. **`bootstrap.sh` tag mismatch (B1)** — it builds `$(git rev-parse HEAD)` while the manifests
   reference the promoted tag. For local testing it should rewrite the tag in the applied
   manifests, or accept a `--image-tag` argument.

Items 1 and 2 are small, testable changes. Say the word and I will implement them on this branch
with tests; item 1 in particular turns "UI loads but nothing works" into "it just works".

---

## 8. Tear down

```bash
mv /tmp/backend.yaml.bak  kubernetes/application/backend/deployment.yaml
mv /tmp/frontend.yaml.bak kubernetes/application/frontend/deployment.yaml
git status --short            # expect: clean
minikube delete
```

**Expected:** `git status` prints nothing; `minikube delete` removes the cluster.

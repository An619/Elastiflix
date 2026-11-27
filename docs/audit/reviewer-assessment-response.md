# Response to reviewer assessment

**Reviewer priorities received:** 2026-11-27 · **Branch:** `arena/04e9752b-elastiflix` @ `bf90d4f`

Each of your seven findings below, with what the evidence now shows. Two of your items changed my
position — I was wrong on one and understated another.

| Your finding | Your priority | Verdict | Correction to my earlier reporting |
| --- | --- | --- | --- |
| Main branch checks may not be enforced | **Critical** | **Confirmed — `main` is unprotected** | My report said "unverified"; it is now verified, and the answer is worse |
| Unused `kubernetes/aws/` needs investigation | High | **Confirmed, and more broken than reported** | I said "no `host:`"; there are three more defects |
| Ansible cluster name hard-coded | High | **Confirmed** | No change |
| Secret scanner exclusions | High | **I was probably wrong** | I said the allowlist "buys little"; it is likely load-bearing |
| Documentation didn't match pipeline | High | Fixed (`fd3940b`) | No change |
| Empty commit to retrigger | Medium | **Isolated dropped event, not concurrency** | Now measured |
| No files moved | Low | Held | No change |

---

## 1. Critical — `main` is not protected

```
$ gh api repos/An619/Elastiflix/branches/main --jq '{name, protected}'
{"name":"main","protected":false}

$ gh api repos/An619/Elastiflix/rulesets
[]

$ gh api repos/An619/Elastiflix/rules/branches/main
[]
```

Three independent endpoints, one conclusion: **there is no protection, no ruleset, no required
check, and no required review on `main`.**

The consequence is concrete. This PR reports `mergeStateStatus: CLEAN` and
`reviewDecision: ""` — it is mergeable right now by anyone with write access, with or without the
eleven checks that just passed. Every gate in `devsecops.yml` is a **notification**, not a
control. The pipeline prevents nothing; it only tells you what you merged.

That reorders the value of this branch. Roughly half of what we shipped is enforcement that
isn't enforced:

| Control | Actually enforced today? |
| --- | --- |
| Test suite, Checkov, Trivy, Gitleaks, Sonar | No — advisory |
| `sonar-qube` gate (the one that failed 4 times) | No — advisory |
| The 30 reasoned suppressions | No — advisory |
| Image publish restricted to `main` | Yes — `docker-push` is `if`-gated inside the workflow |
| No CI write access to the repo | Yes — `permissions: contents: read` |

**Fix (repository settings, ~3 minutes, needs admin):**

Settings → Branches → Add branch protection rule for `main`:

- [x] Require a pull request before merging
- [x] Require status checks to pass — add these exact contexts:
      `code-tests / test`, `secret-scanning / gitleaks`, `dependency-checks / npm-audit`,
      `dependency-checks / python-audit`, `code-quality / hadolint`,
      `docker-checks / checkov-iac-scan`, `docker-checks / trivy-filesystem-scan`,
      `docker-checks / trivy-image-scan (backend)`, `docker-checks / trivy-image-scan (frontend)`,
      `sonar-qube / sonar`, `SonarCloud Code Analysis`
- [x] Require branches to be up to date before merging
- [ ] Require approvals — optional for a solo repo, but it is the only thing that stops a
      self-merge
- [x] Do not allow bypassing the above settings

Two notes from testing this branch:

- `SonarCloud Code Analysis` is an **external** check posted by the Sonar app, not a workflow job.
  It can be selected as required, but it is also the check that skipped on forked PRs — if you
  require it, fork PRs will block forever. Either accept that (fine for a private repo) or leave
  that one unrequired.
- `docker-push` must **not** be required: it is skipped on PRs by design and a required-and-skipped
  check blocks merging.

---

## 2. High — `kubernetes/aws/` is worse than "unused"

My earlier finding said the ALB Ingress has no `host:` and an internet-facing scheme. That was
incomplete. There are three further defects, all read out of the files:

### 2a. The ESO ServiceAccount is never annotated with its IRSA role

`kubernetes/aws/eso.yaml` authenticates through a ServiceAccount:

```yaml
auth:
  jwt:
    serviceAccountRef:
      name: external-secrets
      namespace: external-secrets
```

Terraform creates the role, scoped to exactly that ServiceAccount:

```
terraform/eks.tf:17:  namespace_service_accounts = ["external-secrets:external-secrets"]
```

and exports its ARN as `eso_role_arn`. **Nothing ever annotates the ServiceAccount with it.**
`grep -rn "role-arn"` finds exactly one hit — the ALB controller's, in `ansible/playbook.yml`.
The ALB role is annotated from a literal ARN while the exported `alb_controller_role_arn` output
goes unused.

So the store is fabricating credentials from the node instance role, which is precisely the
"static credentials" weakness I claimed Phase 4 fixed with IRSA. On EKS this path would fail
unless the node role happens to have Secrets Manager read — a permissions error at best, a
privilege leak at worst.

### 2b. The ExternalSecrets target Secrets that already exist

`eso.yaml` declares `ExternalSecret` resources named `redis-secret` and `rabbitmq-secret` in
`infra`, with `creationPolicy: Owner`. Those same Secret names are already created by
`bootstrap.sh` (Minikube) and by `kubernetes/infra/*-sealedsecret.yaml` (sealed-secrets path).

Three mechanisms claim ownership of one Secret name. On EKS, ESO and the sealed-secrets controller
would fight over it — the ESO one setting `creationPolicy: Owner` means ESO will overwrite, and
deleting the ExternalSecret would delete the Secret out from under the pods.

### 2c. The Secrets Manager secrets are assumed, never created

The policy grants `secretsmanager:GetSecretValue` on `arn:aws:secretsmanager:...:secret:elastiflix/*`,
but no Terraform resource creates `elastiflix/redis` or `elastiflix/rabbitmq`. They must be created
by hand, and nothing in the repo says so.

### Recommendation

This directory is not "activate as-is" material — it is three fixes away from correct:

1. annotate the ESO ServiceAccount with `eso_role_arn` (an Ansible task next to the ALB one);
2. choose **one** secret-delivery mechanism for EKS. Sealed secrets and IRSA+Secrets Manager are
   both present; running both is the bug. On AWS, IRSA+ESO is the right answer and the sealed
   secrets should be dropped from the EKS path;
3. add a `host:` and start with `scheme: internal`, or the ALB answers on its public DNS name for
   any Host header.

I have not changed these files: each fix has a runtime consequence and #2 is an architecture
decision, not a cleanup.

---

## 3. High — Ansible bootstrap (finding A3), unchanged

```
$ grep -n "version" ansible/playbook.yml
(no output — no chart is version-pinned)
$ grep -n "elastiflix-eks" ansible/playbook.yml
42:        --set clusterName=elastiflix-eks
```

Plus the same IRSA annotation by literal ARN:

```
34: eks.amazonaws.com/role-arn=arn:aws:iam::{{ lookup('env','AWS_ACCOUNT_ID') }}:role/elastiflix-alb-role
```

`terraform/outputs.tf` already exports `alb_controller_role_arn` and `eks_cluster_name` for exactly
this purpose. The fix is to consume those outputs instead of restating them, and to pin the three
charts — `bootstrap.sh` pins Argo CD `v3.6.3`, Rollouts `v1.10.2`, Sealed Secrets `v0.27.3`, Falco
`9.2.2`; the EKS path pins nothing.

---

## 4. High — secret scanner exclusions: correction

**I was probably wrong, and here is the measurement.**

Earlier I wrote that "the `SealedSecret` kind is not scannable secret material, so the allowlist
buys little" and recommended deleting it. Two things say otherwise.

The blobs are high-entropy ciphertext, not structured data:

| File | Key | Size | Shannon entropy |
| --- | --- | ---: | ---: |
| `redis-sealedsecret.yaml` | `redis-password` | 551 B | 7.61 bits/byte |
| `rabbitmq-sealedsecret.yaml` | `rabbitmq-password` | 552 B | 7.58 bits/byte |

(8.0 is indistinguishable from random; 4.0 is prose.)

A generic high-entropy rule cannot tell that from a real secret. Running a second scanner over the
same two files — `detect-secrets`, which implements the same *class* of heuristic:

```
kubernetes/infra/redis-sealedsecret.yaml
  type=Base64 High Entropy String  line=10
  type=Secret Keyword              line=10
```

It fires twice per file, on the `encryptedData:` line — once for the entropy, once because the key
name contains `password`. Gitleaks' own generic rules are close analogues. So the allowlist is
very likely **load-bearing**, and deleting it would turn the pipeline red on every run.

**What I could not determine:** which gitleaks rule actually fires. Gitleaks release binaries are
blocked from this sandbox (same TLS failure that blocks kubeconform and actionlint), so this is a
measured claim about an analogous scanner, not the exact one.

**Recommended change — narrow, don't delete:**

Replace the two path entries with a regex scoped to the ciphertext, so the file stays scannable for
anything else:

```toml
title = "Gitleaks Config"

[allowlist]
description = "SealedSecret ciphertext is inert; everything else in these files is still scanned"
# Allowlist the matched value, not the whole file: a plaintext Secret added to
# the same file later is still reported.
regexTarget = "match"
regexes = [
  '''redis-password: [A-Za-z0-9+/=]{500,}''',
  '''rabbitmq-password: [A-Za-z0-9+/=]{500,}''',
]
```

This has to be verified in one CI run before it replaces the path allowlist — the regex is written
against the file contents, not against gitleaks' match semantics, which I could not test here.

**And the residual risk I originally flagged is real**, just not the one the allowlist creates: a
path allowlist hides the *whole file*, so a commit that swaps a `SealedSecret` for a plaintext
`Secret` in the same file would pass. A regex allowlist closes that. A compensating check is
cheaper still — fail if any file under `kubernetes/` declares `kind: Secret` with non-empty
`data`/`stringData`.

I first wrote that check as a one-line `grep -A3`. **It missed a planted plaintext Secret** —
`-A3` stops before `stringData:` in a normal manifest. A YAML-aware version is correct, and was
verified against both the real tree (clean) and a tree with a planted `Secret` (caught):

```python
import yaml, pathlib, sys
bad = []
for p in pathlib.Path("kubernetes").rglob("*.yaml"):
    for d in yaml.safe_load_all(p.read_text()):
        if isinstance(d, dict) and d.get("kind") == "Secret" and (d.get("data") or d.get("stringData")):
            bad.append(f"{p}: {d['metadata'].get('name')}")
for b in bad:
    print(f"plaintext Secret committed: {b}", file=sys.stderr)
sys.exit(1 if bad else 0)
```

---

## 5. Medium — the empty commit: measured, and it was not concurrency

Your instinct to investigate was right. Here is the measurement.

Normal latency between commit and run creation is **6–7 seconds**:

| Commit | Committed | Run created | Delta |
| --- | --- | --- | --- |
| `ca2506d` | 06:55:41 | 06:55:48 | 7 s |
| `cdcb266` | 06:47:44 | 06:47:50 | 6 s |
| `fd3940b` | 07:14:05 | — | **never** |
| `3c5c33b` | 07:20:49 | 07:20:55 | 6 s |

So `fd3940b` was a single dropped event, not a slow or throttled pipeline. Rate limiting is
excluded: 30 commits across two days, at most 4 runs in one minute, far below any threshold, and
the run *after* the retrigger started in 6 seconds.

I also considered concurrency as a cause and it does not fit. `devsecops.yml` sets:

```yaml
concurrency:
    group: devsecops-${{ github.ref }}
    cancel-in-progress: false
```

`cancel-in-progress: false` means a queued run is never cancelled, and grouping is per-ref so a
different branch cannot block this one. No run was running at 07:14 either — the previous one
started 06:58 and takes ~4 minutes. Net: **one dropped `synchronize` event out of 30 pushes (≈3 %),
whose only remedy is a new push.** The empty commit is the correct workaround; it is recorded as
such rather than hidden.

Note this interacts with finding 1: with no branch protection, a dropped event means a commit can
sit at the head of a PR with **no checks reported at all** and still show "mergeable". That is the
real hazard, and branch protection is what closes it — required checks cannot be satisfied by
absence.

---

## 6. Action plan in your priority order

| # | Item | Who | Effort | Blocking? |
| --- | --- | --- | --- | --- |
| 1 | Enable branch protection on `main` | You (admin settings) | 3 min | **Yes — do first** |
| 2 | Narrow the gitleaks allowlist to a regex, verify in one CI run | Me | ~30 min | No |
| 3 | Annotate ESO SA with `eso_role_arn`; pick one secret mechanism; add ALB `host:` | Me | ~1 h | Before EKS |
| 4 | Pin Ansible charts, consume `terraform output` instead of literals | Me | ~30 min | Before EKS |
| 5 | Add the `kind: Secret` compensation check | Me | 15 min | No |

Items 2–5 are all in-repo and verifiable by CI. Item 1 cannot be done from here and is worth more
than 2–5 combined.

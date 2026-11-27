# How this work was developed

This document records how the changes on this branch were produced, so that a
reader — a reviewer, an interviewer, or me in six months — can see what was
tested and what was taken on trust rather than having to infer it from the diff.

## In short

The changes were developed in a pair-programming arrangement with an AI assistant
(Arena.ai's agent mode). The assistant proposed and wrote most of the code and
documentation. **I ran everything against a real environment, and every defect
below was found from output I produced, not from reading the code.** Where the
assistant was wrong, it is recorded too, because the corrections are the part
that shows the work was verified rather than accepted.

`Co-authored-by:` trailers in the commit messages record the same fact.

## What was actually run, and where

| | |
|---|---|
| Docker Compose stack (`./start.sh`) | Run on a Windows 11 machine, Docker Desktop, Git Bash |
| Elasticsearch, Kibana, Logstash, Filebeat, backend, frontend | All started and exercised |
| Catalogue indexing | 6959 movies, verified with `_count` and an aggregation |
| Search API | Verified by `curl` and in the browser |
| Kibana dashboards | Verified by querying saved objects by name |
| CI pipeline | GitHub Actions, green on every push |
| **Minikube / Kubernetes** | **Not run.** The cluster manifests are unverified by execution so far |

That last row matters. Everything under `kubernetes/` has been validated by CI
(kubeconform, Checkov, the observability validator) but has never been applied to
a live cluster by me. `scripts/verify-deployment.sh` was tested only against a
stubbed `kubectl`. Treat that path as asserted, not demonstrated.

## Defects I found by running it

Each of these was in code that looked correct and passed CI.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | `./start.sh` died with **exit code 49** and no message | `python3` on Windows is the Microsoft Store alias — a shim that prints "Python was not found" and exits 9009. It resolves, so nothing catches it. | Probe `python3`, `python`, `py -3`; use the first that runs. Fail with instructions if none do. |
| 2 | Dashboards step printed `Binary file (standard input) matches` | A `\| grep -v` pipe over a script that printed nothing. `grep` read empty input and exited 0, so `\|\| true` hid any failure. | Status output to stderr; no pipe; a non-zero exit now warns. |
| 3 | `elastiflix-logs` index stayed at **0 documents** while every pod was healthy | Docker's log driver was `local`, which writes a **binary** format. Filebeat's `container` parser expects Docker's JSON envelope, finds nothing to unwrap, and ships zero events — with no error. | Pin `driver: json-file` with bounded rotation on backend and frontend. |
| 4 | Search Overview latency panel showed `0.00` for searches that took time | Cache hits logged `duration_ms: 0` deliberately, so hits could be told from misses in Kibana. | Log the real elapsed time; `cache_hit` already distinguishes them. |
| 5 | `_cat/indices` reported **60596** documents for a 6959-movie catalogue | Nested-mapped fields (`keywords`, `belongs_to_collection`) are stored as hidden Lucene documents and counted by `_cat/indices` but not by `hits.total`. 6959 + 51865 + 1772 = 60596. | Not a bug — both numbers are correct for different questions. Documented so it is not "fixed" by reindexing a healthy index. |
| 6 | A dashboard check reported success regardless | `_find?type=dashboard` returns 115 Metricbeat dashboards, so it cannot distinguish "ours loaded" from "ours did not". | Query by name (`search=Elastiflix`) and expect exactly three titles. |

The pattern across 1–4 and 6 is the same: **the failure returned "found nothing"
and was read as "fine."** That is the specific hazard in this stack, and it is
why `scripts/verify-deployment.sh` treats `SKIP` as distinct from `PASS` and
refuses to count one as the other.

## Where the assistant was wrong

Recorded deliberately. An account of this work that lists only successes would
not be a credible account.

- Claimed `Binary file (standard input) matches` meant the dashboards had
  **not** loaded. They had. Corrected in the runbook after I checked Kibana.
- Predicted an autodiscover `contains` condition was the Filebeat fault. The
  syntax was correct all along; the fault was one layer below, in the log driver.
- Gave a verification command that returned a duplicate match and another that
  was mangled by Git Bash path conversion. Both were caught by their own output.
- Predicted `generate-traffic.sh 5` would produce 85 documents. It is 90
  filtered, 150 total.

## Working method from here

My rule for the remaining phases: **the assistant diagnoses, I execute and
report output.** Nothing is claimed to work because it looks right; it is claimed
to work because a command produced evidence. Where a check cannot be run, it is
labelled unverified rather than assumed.

## If you are reviewing this

The useful question is not "was a tool used" — for most of this work, it was. It
is whether the result was verified. The table above is the answer, and the
runbooks under `docs/runbooks/` contain the commands and their expected output so
each claim can be re-checked independently.

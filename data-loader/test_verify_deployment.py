"""Tests for scripts/verify-deployment.sh.

The verifier is a security and correctness gate: it decides whether a deployment
"works". A verifier that always says PASS is worse than none, so these tests
drive it against a stubbed kubectl and assert both directions of every verdict:
it must report success for a healthy cluster and failure for a broken one.

`kubectl` is replaced by a generated shell stub, so no cluster is required.
The stub answers the exact invocations the script makes; if the script changes
its command shape, the stub stops matching and the tests fail loudly rather than
silently passing.
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "verify-deployment.sh"

# A stub kubectl. FAKE_MODE selects healthy vs broken behaviour. Each branch
# mirrors one command the verifier issues.
KUBECTL_STUB = r"""#!/usr/bin/env bash
mode="${FAKE_MODE:-healthy}"
args="$*"

case "$args" in
  "cluster-info") exit 0 ;;
  "config current-context") echo "fake-context"; exit 0 ;;
esac

[[ "$args" == *"get namespace"* ]] && exit 0
[[ "$args" == *"get deployment argocd-server"* ]] && exit 0
[[ "$args" == *"get deployment argo-rollouts"* ]] && exit 0
[[ "$args" == *"k8s-app=calico-node"* ]] && { echo "pod/calico-node-abc"; exit 0; }

if [[ "$args" == *"--field-selector=status.phase=Running -o name"* ]]; then
  if [ "$mode" = "broken" ] && [[ "$args" == *"app=logstash"* ]]; then exit 0; fi
  echo "pod/x"; exit 0
fi

if [[ "$args" == *"get endpoints backend"* ]]; then
  [ "$mode" = "broken" ] && exit 0
  echo "10.1.2.3"; exit 0
fi
[[ "$args" == *"get endpoints frontend"* ]] && { echo "10.1.2.4"; exit 0; }

if [[ "$args" == *"localhost:9200/_cluster/health"* ]]; then
  [ "$mode" = "broken" ] && { echo '{}'; exit 0; }
  echo '{"status":"green"}'; exit 0
fi
if [[ "$args" == *"localhost:9200/elastiflix-movies/_count"* ]]; then
  if [ "$mode" = "broken" ]; then echo '{"count":0}'; else echo '{"count":6959}'; fi
  exit 0
fi
[[ "$args" == *"_source=user_score"* ]] && { echo '"user_score"'; exit 0; }

[[ "$args" == *"localhost:17700/healthz"* ]] && { echo "OK"; exit 0; }
if [[ "$args" == *"localhost:17700/api/search"* ]]; then
  if [ "$mode" = "broken" ]; then echo '{"totalResults":0,"results":[]}'
  else echo '{"totalResults":6,"results":[{"title":{"raw":"The Matrix Revolutions"}},{"title":{"raw":"The Animatrix"}}]}'; fi
  exit 0
fi
if [[ "$args" == *"localhost:17700/api/"* ]]; then
  [ "$mode" = "broken" ] && { echo "  HTTP/1.1 500 Oops"; exit 0; }
  echo "  HTTP/1.1 200 OK"; exit 0
fi
[[ "$args" == *"localhost:17700/metrics"* ]] && { echo "# HELP elastiflix_http_responses_total"; exit 0; }

if [[ "$args" == *"localhost:8080/api/search"* ]]; then
  if [ "$mode" = "broken" ]; then echo "  HTTP/1.1 502 Bad Gateway"; else echo "  HTTP/1.1 200 OK"; fi
  exit 0
fi
[[ "$args" == *"localhost:8080/"* ]] && { echo "<!DOCTYPE html><html><body><div></div></body></html>"; exit 0; }

[[ "$args" == *"get ingress app-ingress"* ]] && { echo "192.168.49.2"; exit 0; }

if [[ "$args" == *"get --raw"*"up%7Bjob"* ]]; then
  if [ "$mode" = "broken" ]; then echo '{"data":{"result":[]}}'
  else echo '{"data":{"result":[{"value":[1,"1"]}]}}'; fi
  exit 0
fi
if [[ "$args" == *"get --raw"*"elastiflix%3Arequests"* ]]; then
  if [ "$mode" = "broken" ]; then echo '{"data":{"result":[]}}'
  else echo '{"data":{"result":[{"value":[1,"0.42"]}]}}'; fi
  exit 0
fi

if [[ "$args" == *"dry-run=server"* ]]; then
  [ "$mode" = "broken" ] && { echo 'pod/verify-psa created'; exit 0; }
  echo 'Error from server (Forbidden): violates PodSecurity "restricted:latest"'; exit 1
fi

if [[ "$args" == *"/usr/local/bin/x"* ]]; then
  [ "$mode" = "broken" ] && { echo "0"; exit 0; }
  echo "1"; exit 0
fi
if [[ "$args" == *"CapEff"* ]]; then
  if [ "$mode" = "broken" ]; then echo "CapEff:	0000000000200000"; else echo "CapEff:	0000000000000000"; fi
  exit 0
fi
if [[ "$args" == *"kibana.elastic-stack"* ]]; then
  [ "$mode" = "broken" ] && { echo "0"; exit 0; }
  echo "1"; exit 0
fi

if [[ "$args" == *"get application"* ]]; then
  case "$args" in
    *".spec.syncPolicy.automated"*) echo ""; exit 0 ;;
    *".status.sync.status"*)
      if [ "$mode" = "broken" ]; then echo "OutOfSync"; else echo "Synced"; fi; exit 0 ;;
    *".status.health.status"*)
      if [ "$mode" = "broken" ]; then echo "Progressing"; else echo "Healthy"; fi; exit 0 ;;
  esac
  echo "Synced"; exit 0
fi

[[ "$args" == *"metadata.name}"* ]] && { echo "pod-123"; exit 0; }
[[ "$args" == *"get pods -l app=frontend -o name"* ]] && { echo "pod/frontend-abc"; exit 0; }

exit 0
"""


class VerifyDeploymentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not SCRIPT.exists():
            raise unittest.SkipTest("verify-deployment.sh not present")

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.tmp)]))
        stub = self.tmp / "kubectl"
        stub.write_text(KUBECTL_STUB)
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
        self.env = dict(os.environ, PATH=f"{self.tmp}:{os.environ['PATH']}")

    def run_script(self, mode, *args):
        env = dict(self.env, FAKE_MODE=mode)
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            capture_output=True, text=True, env=env, timeout=120,
        )

    # --- the two directions that matter -------------------------------------

    def test_healthy_deployment_exits_zero(self):
        result = self.run_script("healthy")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Deployment is WORKING", result.stdout)
        self.assertNotIn("FAIL", result.stdout)

    def test_broken_deployment_exits_nonzero(self):
        result = self.run_script("broken")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("NOT fully working", result.stdout)

    # --- specific verdicts, so a check cannot silently invert ---------------

    def test_broken_catalogue_is_reported(self):
        out = self.run_script("broken").stdout
        self.assertIn("catalogue document count", out)
        self.assertIn("0 < 6959", out)

    def test_broken_proxy_502_has_actionable_evidence(self):
        out = self.run_script("broken").stdout
        self.assertIn("nginx cannot resolve backend", out)

    def test_networkpolicy_success_is_a_failure(self):
        """If the blocked path SUCCEEDS, that is a failure, not a pass."""
        out = self.run_script("broken").stdout
        self.assertIn("policy not enforced", out)

    def test_privileged_pod_being_admitted_is_a_failure(self):
        out = self.run_script("broken").stdout
        self.assertIn("Pod Security Admission rejects a privileged pod", out)
        self.assertIn("pod/verify-psa created", out)

    def test_capabilities_present_is_a_failure(self):
        out = self.run_script("broken").stdout
        self.assertIn("0000000000200000", out)

    # --- machine-readable output -------------------------------------------

    def test_json_mode_emits_only_json(self):
        result = self.run_script("broken", "--json")
        payload = json.loads(result.stdout)  # must not need filtering
        self.assertEqual(payload["total"], payload["passed"] + payload["failed"] + payload["skipped"])
        self.assertGreater(payload["failed"], 0)
        self.assertTrue(any(c["status"] == "FAIL" for c in payload["checks"]))

    def test_json_mode_keeps_exit_code(self):
        self.assertEqual(self.run_script("broken", "--json").returncode, 1)
        self.assertEqual(self.run_script("healthy", "--json").returncode, 0)

    def test_quick_skips_the_slow_index_checks(self):
        out = self.run_script("healthy", "--quick").stdout
        self.assertIn("SKIP", out)
        self.assertIn("--quick", out)

    # --- guards ------------------------------------------------------------

    def test_unknown_argument_is_usage_error(self):
        self.assertEqual(self.run_script("healthy", "--nonsense").returncode, 2)

    def test_help_mentions_exit_codes(self):
        out = self.run_script("healthy", "--help").stdout
        self.assertIn("Exit codes", out)

    def test_skips_are_never_counted_as_passes(self):
        """A SKIP must not inflate the pass count - that is the whole point."""
        payload = json.loads(self.run_script("healthy", "--json").stdout)
        statuses = [c["status"] for c in payload["checks"]]
        self.assertEqual(statuses.count("PASS"), payload["passed"])
        self.assertEqual(statuses.count("SKIP"), payload["skipped"])


if __name__ == "__main__":
    unittest.main()

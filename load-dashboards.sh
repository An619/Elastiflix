#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Load the three prebuilt Elastiflix dashboards into Kibana.
#
#      ./load-dashboards.sh
#
#  ./start.sh already does this. Run it by hand to restore the dashboards
#  after you have been editing them, or if a live build goes sideways.
#
#  WHY NOT `POST /api/saved_objects/_import`: that endpoint runs the full
#  saved-object migration chain over whatever you hand it, and hand-written
#  objects with no version stamp fail it ("Cannot read properties of
#  undefined (reading 'currentIndexPatternId')"). The per-object create API
#  stamps the current version itself, so it just works.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
KB="${KB:-http://localhost:5601}"
SRC="elk/kibana/dashboards.ndjson"

[[ -f "$SRC" ]] || { echo "ERROR: $SRC not found" >&2; exit 1; }

# --- A real Python interpreter ---------------------------------------------
# `python3` is not a reliable name on Windows: the Microsoft Store installs a
# stub at that path which prints "Python was not found ..." and exits 9009. It
# sits on PATH ahead of a real install, so a bare `python3` call fails in a way
# that looks like the script is broken - under `set -e` the script dies with
# exit 49 and no explanation. Probe each candidate and keep the first that runs.
#
# `py -3` is the Windows Python Launcher, installed with the standard
# interpreter, and the Store stub does not shadow it.
PYTHON=""
for candidate in "python3" "python" "py -3"; do
  # shellcheck disable=SC2086 # $candidate is a deliberate word list ("py -3")
  if $candidate -c 'import sys' >/dev/null 2>&1; then PYTHON="$candidate"; break; fi
done
if [[ -z "$PYTHON" ]]; then
  echo "ERROR: no working Python interpreter found (tried: python3, python, py -3)." >&2
  echo "       On Windows, 'python3' is usually the Microsoft Store stub, which is" >&2
  echo "       not Python. Fix it either way:" >&2
  echo "         - install from https://www.python.org/downloads/ and tick" >&2
  echo "           \"Add python.exe to PATH\"; or" >&2
  echo "         - Settings > Apps > Advanced app settings > App execution aliases," >&2
  echo "           and turn off the python3/python entries." >&2
  exit 1
fi

$PYTHON - "$KB" "$SRC" <<'PY'
import json, sys, urllib.request, urllib.error
kb, src = sys.argv[1], sys.argv[2]
ok = fail = 0
for line in open(src):
    o = json.loads(line)
    body = json.dumps({"attributes": o["attributes"], "references": o["references"]}).encode()
    req = urllib.request.Request(
        f"{kb}/api/saved_objects/{o['type']}/{o['id']}?overwrite=true",
        data=body, method="POST",
        headers={"kbn-xsrf": "true", "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req); ok += 1
        if o["type"] == "dashboard":
            print(f"    {o['attributes']['title']}")
    except urllib.error.HTTPError as e:
        fail += 1
        print(f"    FAILED {o['type']}/{o['id']}: {e.code} {e.read()[:200].decode()}", file=sys.stderr)
print(f"==> {ok} saved objects loaded" + (f", {fail} FAILED" if fail else ""))
sys.exit(1 if fail else 0)
PY

echo "==> Kibana -> Dashboards"

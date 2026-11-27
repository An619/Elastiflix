#!/usr/bin/env python3
"""Fail CI when a Kubernetes Checkov scan has unsuppressed findings.

Checkov's own exit code is only as good as its flags: `--soft-fail` never
fails, and `--quiet` hides the detail. This script reads the JSON report and
makes three things explicit and enforceable:

1. no unsuppressed failed check may remain;
2. no YAML/parse error may be ignored;
3. every suppression must carry a written reason on the resource.

Usage: check-checkov-report.py /path/to/results_json.json
Exit code 0 only when all three conditions hold.
"""
from __future__ import annotations

import json
import sys
from collections import Counter, defaultdict
from pathlib import Path


def load_report(path: Path) -> dict:
    if not path.is_file():
        raise SystemExit(f"Checkov report not found: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    report = load_report(Path(argv[1]))
    summary = report.get("summary", {})
    results = report.get("results", {})
    failed = results.get("failed_checks", []) or []
    skipped = results.get("skipped_checks", []) or []

    lines = ["## Kubernetes Checkov gate", ""]
    lines.append(
        "| Passed | Failed | Suppressed | Parse errors |"
        "\n| ---: | ---: | ---: | ---: |"
        f"\n| {summary.get('passed', 0)} | {summary.get('failed', len(failed))} | "
        f"{summary.get('skipped', len(skipped))} | {summary.get('parsing_errors', 0)} |"
    )

    if skipped:
        by_check: dict[str, list[str]] = defaultdict(list)
        for item in skipped:
            reason = (item.get("suppress_comment") or "").strip()
            by_check[item.get("check_id", "unknown")].append(
                f"{item.get('resource', '?')}: {reason or 'NO REASON GIVEN'}"
            )
        lines += ["", "<details><summary>Suppressed checks and reasons</summary>", ""]
        for check_id in sorted(by_check):
            lines.append(f"- `{check_id}`")
            lines += [f"  - {entry}" for entry in sorted(by_check[check_id])]
        lines += ["", "</details>"]

    print("\n".join(lines))

    problems: list[str] = []
    if failed:
        counts = Counter(item.get("check_id", "unknown") for item in failed)
        detail = ", ".join(f"{check}×{count}" for check, count in sorted(counts.items()))
        problems.append(f"{len(failed)} unsuppressed failing check(s): {detail}")
    if summary.get("parsing_errors", 0):
        problems.append(f"{summary['parsing_errors']} manifest parse error(s)")
    unreasoned = [
        item for item in skipped if not (item.get("suppress_comment") or "").strip()
    ]
    if unreasoned:
        names = ", ".join(sorted({item.get("check_id", "unknown") for item in unreasoned}))
        problems.append(f"{len(unreasoned)} suppression(s) without a reason: {names}")

    if problems:
        print("", file=sys.stderr)
        for problem in problems:
            print(f"Checkov gate failed: {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

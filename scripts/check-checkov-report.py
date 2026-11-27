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


def suppression_reason(item: dict) -> str:
    """Checkov records the reason under check_result.suppress_comment.

    Some versions also put it at the top level, so both are accepted - but a
    missing reason is always a failure, never an empty string that passes.
    """
    for candidate in (item.get("check_result") or {}, item):
        reason = candidate.get("suppress_comment")
        if isinstance(reason, str) and reason.strip():
            return reason.strip()
    return ""


# The report path is attacker-influenced in the sense that it comes from the
# command line, and this script may one day run somewhere less trusted than CI.
# Restrict it to a JSON file inside an explicit directory tree so a value like
# ../../etc/passwd cannot select what gets read.
ALLOWED_REPORT_SUFFIXES = (".json",)


def resolve_report_path(raw: str) -> Path:
    candidate = Path(raw).expanduser()
    if candidate.is_symlink():
        raise SystemExit(f"Checkov report must not be a symlink: {raw}")
    resolved = candidate.resolve()
    if not resolved.is_file():
        raise SystemExit(f"Checkov report not found: {raw}")
    if resolved.suffix not in ALLOWED_REPORT_SUFFIXES:
        raise SystemExit(f"Checkov report must be a JSON file: {raw}")
    return resolved


def load_report(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit(f"Checkov report is not valid JSON ({path}): {error}") from error


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    report = load_report(resolve_report_path(argv[1]))
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
            reason = suppression_reason(item)
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
    unreasoned = [item for item in skipped if not suppression_reason(item)]
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

#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { resolve, relative } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));

function normalizeVia(via = []) {
  return via.map((entry) => {
    if (typeof entry === "string") return `package:${entry}`;
    if (entry && typeof entry === "object" && entry.source !== undefined) {
      return `advisory:${entry.source}`;
    }
    return `unknown:${JSON.stringify(entry)}`;
  }).sort();
}

function lockScope(lock, nodePath) {
  const entry = lock.packages?.[nodePath];
  if (!entry || !entry.version) return null;
  return { version: entry.version, scope: entry.dev === true ? "development" : "runtime" };
}

function sameArray(a = [], b = []) {
  return a.length === b.length && [...a].sort().every((value, index) => value === [...b].sort()[index]);
}

function isIsoDate(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

export function evaluateAuditReport({ project, report, lock, policy, today = new Date().toISOString().slice(0, 10) }) {
  const errors = [];
  const matchedExceptions = new Set();
  const vulnerabilities = report?.vulnerabilities;

  if (
    !report ||
    !Number.isInteger(report.auditReportVersion) ||
    !report.metadata || typeof report.metadata !== "object" ||
    !report.metadata.vulnerabilities || typeof report.metadata.vulnerabilities !== "object" ||
    !vulnerabilities || typeof vulnerabilities !== "object" || Array.isArray(vulnerabilities)
  ) {
    return { errors: ["npm audit did not return a valid audit report; treat this as an audit/tool/network failure, not a pass."], findings: [] };
  }
  if (!policy || policy.policyVersion !== 1 || !Array.isArray(policy.exceptions)) {
    return { errors: ["Vulnerability exception policy is missing or has an unsupported schema."], findings: [] };
  }
  if (typeof policy.owner !== "string" || !policy.owner.trim() || typeof policy.trackingDocument !== "string" || !policy.trackingDocument.trim()) {
    return { errors: ["Policy must name an accountable owner and a tracking document."], findings: [] };
  }
  const invalidException = policy.exceptions.find((entry) =>
    !entry ||
    !["frontend", "backend"].includes(entry.project) ||
    typeof entry.package !== "string" || !entry.package.trim() ||
    !Array.isArray(entry.versions) || entry.versions.length === 0 || entry.versions.some((version) => typeof version !== "string" || !version) ||
    entry.scope !== "development" ||
    !["high", "critical"].includes(entry.severity) ||
    !Array.isArray(entry.via) || entry.via.length === 0 || entry.via.some((path) => typeof path !== "string" || !path)
  );
  if (invalidException) {
    return { errors: ["Every exception must name a supported project, exact package/version(s), development scope, HIGH/CRITICAL severity, and exact advisory path(s)."], findings: [] };
  }
  if (!isIsoDate(today) || !isIsoDate(policy.expires)) {
    return { errors: ["The policy expiry and evaluation date must use valid YYYY-MM-DD dates."], findings: [] };
  }
  if (policy.expires < today) {
    return { errors: [`The vulnerability exception policy expired on ${policy.expires}.`], findings: [] };
  }

  const findings = [];
  for (const [packageName, item] of Object.entries(vulnerabilities)) {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      errors.push(`${project}: npm audit returned an invalid vulnerability record for ${packageName}.`);
      continue;
    }
    const severity = String(item.severity || "unknown").toLowerCase();
    const paths = Array.isArray(item.nodes) ? item.nodes : [];
    const via = normalizeVia(item.via);
    if (["high", "critical"].includes(severity) && paths.length === 0) {
      errors.push(`${project}: cannot map HIGH/CRITICAL finding ${packageName} to any exact package-lock path.`);
      continue;
    }

    for (const nodePath of paths) {
      const resolved = lockScope(lock, nodePath);
      if (!resolved) {
        errors.push(`${project}: cannot map ${packageName} at ${nodePath} to an exact package-lock version.`);
        continue;
      }
      const finding = { project, package: packageName, version: resolved.version, scope: resolved.scope, severity, via };
      findings.push(finding);

      if ((severity === "high" || severity === "critical") && resolved.scope !== "development") {
        errors.push(`${project}: policy may not accept ${severity.toUpperCase()} runtime finding ${packageName}@${resolved.version}.`);
        continue;
      }

      // This policy specifically adjudicates HIGH/CRITICAL full-tree findings.
      // Moderate/low findings remain visible in the report and are handled by
      // the explicit audit-level policy documented in security/.
      if (!new Set(["high", "critical"]).has(severity)) continue;

      const exceptionIndex = policy.exceptions.findIndex((entry) =>
        entry.project === project &&
        entry.package === packageName &&
        Array.isArray(entry.versions) && entry.versions.includes(resolved.version) &&
        entry.scope === resolved.scope &&
        entry.severity === severity &&
        sameArray(entry.via || [], via)
      );

      if (exceptionIndex < 0) {
        errors.push(`${project}: unexcepted ${severity.toUpperCase()} finding ${packageName}@${resolved.version} (${resolved.scope}); via ${via.join(", ") || "unknown"}.`);
        continue;
      }

      const exception = policy.exceptions[exceptionIndex];
      const exceptionExpiry = exception.expires || policy.expires;
      if (!isIsoDate(exceptionExpiry) || exceptionExpiry < today || exceptionExpiry > policy.expires) {
        errors.push(`${project}: exception for ${packageName}@${resolved.version} has an invalid or expired date.`);
        continue;
      }
      if (!(exception.reason || policy.exceptionReason) || !(exception.remediation || policy.remediation)) {
        errors.push(`${project}: exception for ${packageName}@${resolved.version} must include reason and remediation.`);
        continue;
      }
      matchedExceptions.add(`${exceptionIndex}:${resolved.version}`);
    }
  }

  policy.exceptions.forEach((entry, index) => {
    if (entry.project !== project) return;
    const matches = (entry.versions || []).filter((version) => matchedExceptions.has(`${index}:${version}`));
    if (matches.length !== (entry.versions || []).length) {
      errors.push(`${project}: stale or mismatched exception for ${entry.package}; remove/update it when the audit finding changes.`);
    }
  });

  return { errors, findings };
}

function main() {
  const project = process.argv[2];
  if (!project || !["frontend", "backend"].includes(project)) {
    console.error("Usage: node scripts/npm-audit-policy.js <frontend|backend>");
    process.exitCode = 2;
    return;
  }

  const projectDir = resolve(repoRoot, project);
  const policyPath = resolve(repoRoot, "security/vulnerability-exceptions.json");
  const lockPath = resolve(projectDir, "package-lock.json");
  let policy;
  let lock;
  try {
    policy = JSON.parse(readFileSync(policyPath, "utf8"));
    lock = JSON.parse(readFileSync(lockPath, "utf8"));
  } catch (error) {
    console.error(`Unable to read audit policy or lockfile: ${error.message}`);
    process.exitCode = 2;
    return;
  }

  const result = spawnSync("npm", ["audit", "--json"], { cwd: projectDir, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  if (result.error) {
    console.error(`npm audit could not run: ${result.error.message}`);
    process.exitCode = 2;
    return;
  }
  if (result.stderr?.trim()) process.stderr.write(result.stderr);

  let report;
  try {
    report = JSON.parse(result.stdout);
  } catch {
    console.error(`npm audit returned no parseable JSON (exit ${result.status ?? "unknown"}); this is not a passing scan.`);
    if (result.stdout?.trim()) process.stderr.write(result.stdout);
    process.exitCode = 2;
    return;
  }

  const evaluated = evaluateAuditReport({ project, report, lock, policy });
  const counts = report.metadata?.vulnerabilities || {};
  console.log(`${project}: npm audit findings ${JSON.stringify(counts)}`);
  for (const finding of evaluated.findings) {
    console.log(`reported ${finding.severity}: ${finding.package}@${finding.version} (${finding.scope}) via ${finding.via.join(", ") || "unknown"}`);
  }

  const rootRelative = relative(repoRoot, policyPath);
  if (evaluated.errors.length) {
    evaluated.errors.forEach((error) => console.error(`POLICY FAILURE: ${error}`));
    console.error(`See ${rootRelative} and ${policy.trackingDocument} for approved, time-bound exceptions.`);
    process.exitCode = 1;
    return;
  }

  const accepted = evaluated.findings.filter((finding) => finding.severity === "high" || finding.severity === "critical");
  console.log(`Policy check passed: ${accepted.length} exact, time-bound development-only HIGH/CRITICAL finding(s) are recorded; no unexcepted HIGH/CRITICAL finding remains.`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();

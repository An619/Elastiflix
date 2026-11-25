import test from "node:test";
import assert from "node:assert/strict";
import { evaluateAuditReport } from "../npm-audit-policy.js";

const today = "2026-11-24";
const policyBase = {
  policyVersion: 1,
  owner: "@example",
  expires: "2027-02-22",
  trackingDocument: "security/accepted-risks/example.md",
  exceptionReason: "documented test exception",
  remediation: "upgrade dependency",
  exceptions: [
    {
      project: "frontend",
      package: "old-build-lib",
      versions: ["1.2.3"],
      scope: "development",
      severity: "high",
      via: ["advisory:1234"],
    },
  ],
};
const lock = {
  packages: {
    "node_modules/old-build-lib": { version: "1.2.3", dev: true },
  },
};
const report = {
  auditReportVersion: 2,
  metadata: { vulnerabilities: { high: 1, moderate: 0, critical: 0 } },
  vulnerabilities: {
    "old-build-lib": {
      severity: "high",
      nodes: ["node_modules/old-build-lib"],
      via: [{ source: 1234, severity: "high" }],
    },
  },
};

test("accepts an exact, unexpired, development-only exception", () => {
  const result = evaluateAuditReport({ project: "frontend", report, lock, policy: policyBase, today });
  assert.deepEqual(result.errors, []);
  assert.equal(result.findings.length, 1);
  assert.equal(result.findings[0].scope, "development");
});

test("fails a newly introduced high-severity package", () => {
  const changed = structuredClone(report);
  changed.vulnerabilities["new-lib"] = {
    severity: "high",
    nodes: ["node_modules/new-lib"],
    via: [{ source: 5678, severity: "high" }],
  };
  const extendedLock = structuredClone(lock);
  extendedLock.packages["node_modules/new-lib"] = { version: "4.5.6", dev: true };
  const result = evaluateAuditReport({ project: "frontend", report: changed, lock: extendedLock, policy: policyBase, today });
  assert.ok(result.errors.some((message) => message.includes("unexcepted HIGH")));
});

test("rejects an exception whose advisory path changes", () => {
  const changed = structuredClone(report);
  changed.vulnerabilities["old-build-lib"].via = [{ source: 1234, severity: "high" }, { source: 4321, severity: "high" }];
  const result = evaluateAuditReport({ project: "frontend", report: changed, lock, policy: policyBase, today });
  assert.ok(result.errors.some((message) => message.includes("unexcepted HIGH")));
});

test("never accepts a development exception for a runtime dependency", () => {
  const runtimeLock = { packages: { "node_modules/old-build-lib": { version: "1.2.3", dev: false } } };
  const result = evaluateAuditReport({ project: "frontend", report, lock: runtimeLock, policy: policyBase, today });
  assert.ok(result.errors.some((message) => message.includes("may not accept HIGH runtime")));
});

test("fails when an exception is expired", () => {
  const expired = { ...policyBase, expires: "2026-11-23" };
  const result = evaluateAuditReport({ project: "frontend", report, lock, policy: expired, today });
  assert.ok(result.errors.some((message) => message.includes("policy expired")));
});

test("fails closed on an exception missing exact scope or path fields", () => {
  const malformed = {
    ...policyBase,
    exceptions: [{ ...policyBase.exceptions[0], scope: "any", via: [] }],
  };
  const result = evaluateAuditReport({ project: "frontend", report, lock, policy: malformed, today });
  assert.ok(result.errors.some((message) => message.includes("exact package/version(s)")));
});

test("fails closed on invalid policy and exception dates", () => {
  const invalidPolicyDate = { ...policyBase, expires: "2027-02-30" };
  const policyResult = evaluateAuditReport({ project: "frontend", report, lock, policy: invalidPolicyDate, today });
  assert.ok(policyResult.errors.some((message) => message.includes("valid YYYY-MM-DD")));

  const invalidExceptionDate = {
    ...policyBase,
    exceptions: [{ ...policyBase.exceptions[0], expires: "tomorrow" }],
  };
  const exceptionResult = evaluateAuditReport({ project: "frontend", report, lock, policy: invalidExceptionDate, today });
  assert.ok(exceptionResult.errors.some((message) => message.includes("invalid or expired date")));
});

test("fails when a recorded exception no longer matches an audit finding", () => {
  const clean = { auditReportVersion: 2, metadata: { vulnerabilities: {} }, vulnerabilities: {} };
  const result = evaluateAuditReport({ project: "frontend", report: clean, lock, policy: policyBase, today });
  assert.ok(result.errors.some((message) => message.includes("stale or mismatched exception")));
});

test("fails closed on an invalid audit report", () => {
  const result = evaluateAuditReport({ project: "frontend", report: { error: { code: "ECONNRESET" } }, lock, policy: policyBase, today });
  assert.ok(result.errors.some((message) => message.includes("not a pass")));
});

test("fails closed when a high finding has no exact lockfile path", () => {
  const missingPath = structuredClone(report);
  missingPath.vulnerabilities["old-build-lib"].nodes = [];
  const result = evaluateAuditReport({ project: "frontend", report: missingPath, lock, policy: policyBase, today });
  assert.ok(result.errors.some((message) => message.includes("exact package-lock path")));
});

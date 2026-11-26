import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { evaluateAuditReport, runAuditPolicy } from "../npm-audit-policy.js";

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

function makeFixture() {
  const rootDir = mkdtempSync(join(tmpdir(), "npm-audit-policy-"));
  mkdirSync(join(rootDir, "frontend"), { recursive: true });
  mkdirSync(join(rootDir, "security"), { recursive: true });
  writeFileSync(join(rootDir, "frontend", "package-lock.json"), JSON.stringify(lock));
  writeFileSync(join(rootDir, "security", "vulnerability-exceptions.json"), JSON.stringify(policyBase));
  return rootDir;
}

function makeLogger() {
  const messages = [];
  return { messages, log: (message) => messages.push(message), error: (message) => messages.push(message) };
}

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

test("CLI policy runner rejects unsupported projects and missing npm CLI paths", () => {
  const logger = makeLogger();
  assert.equal(runAuditPolicy("other", { logger }), 2);
  const rootDir = makeFixture();
  try {
    assert.equal(runAuditPolicy("frontend", { rootDir, npmExecPath: "", logger }), 2);
  } finally {
    rmSync(rootDir, { recursive: true, force: true });
  }
  assert.ok(logger.messages.some((message) => message.includes("npm exec")));
});

test("CLI policy runner fails closed when policy files are unreadable", () => {
  const rootDir = mkdtempSync(join(tmpdir(), "npm-audit-policy-missing-"));
  const logger = makeLogger();
  try {
    assert.equal(runAuditPolicy("frontend", { rootDir, npmExecPath: "/trusted/npm-cli.js", logger }), 2);
  } finally {
    rmSync(rootDir, { recursive: true, force: true });
  }
  assert.ok(logger.messages.some((message) => message.includes("Unable to read")));
});

test("CLI policy runner fails closed when npm cannot be launched", () => {
  const rootDir = makeFixture();
  const logger = makeLogger();
  try {
    const exitCode = runAuditPolicy("frontend", {
      rootDir,
      npmExecPath: "/trusted/npm-cli.js",
      spawn: () => ({ error: new Error("spawn failed") }),
      logger,
    });
    assert.equal(exitCode, 2);
  } finally {
    rmSync(rootDir, { recursive: true, force: true });
  }
  assert.ok(logger.messages.some((message) => message.includes("spawn failed")));
});

test("CLI policy runner rejects npm output that is not JSON", () => {
  const rootDir = makeFixture();
  const logger = makeLogger();
  try {
    const exitCode = runAuditPolicy("frontend", {
      rootDir,
      npmExecPath: "/trusted/npm-cli.js",
      spawn: () => ({ status: 1, stdout: "not-json", stderr: "audit unavailable" }),
      logger,
    });
    assert.equal(exitCode, 2);
  } finally {
    rmSync(rootDir, { recursive: true, force: true });
  }
  assert.ok(logger.messages.some((message) => message.includes("not a passing scan")));
  assert.ok(logger.messages.some((message) => message.includes("audit unavailable")));
});

test("CLI policy runner invokes npm by explicit CLI path and accepts a matching exception", () => {
  const rootDir = makeFixture();
  const logger = makeLogger();
  let invocation;
  try {
    const exitCode = runAuditPolicy("frontend", {
      rootDir,
      npmExecPath: "/trusted/npm-cli.js",
      spawn: (...args) => {
        invocation = args;
        return { status: 1, stdout: JSON.stringify(report), stderr: "" };
      },
      logger,
    });
    assert.equal(exitCode, 0);
  } finally {
    rmSync(rootDir, { recursive: true, force: true });
  }
  assert.equal(invocation[0], process.execPath);
  assert.deepEqual(invocation[1], ["/trusted/npm-cli.js", "audit", "--json"]);
  assert.ok(logger.messages.some((message) => message.includes("Policy check passed")));
});

test("CLI policy runner fails on a high-severity finding without an exact exception", () => {
  const rootDir = makeFixture();
  const logger = makeLogger();
  const changed = structuredClone(report);
  changed.vulnerabilities["new-lib"] = {
    severity: "high",
    nodes: ["node_modules/new-lib"],
    via: [{ source: 5678, severity: "high" }],
  };
  const changedLock = structuredClone(lock);
  changedLock.packages["node_modules/new-lib"] = { version: "4.5.6", dev: true };
  writeFileSync(join(rootDir, "frontend", "package-lock.json"), JSON.stringify(changedLock));
  try {
    const exitCode = runAuditPolicy("frontend", {
      rootDir,
      npmExecPath: "/trusted/npm-cli.js",
      spawn: () => ({ status: 1, stdout: JSON.stringify(changed), stderr: "" }),
      logger,
    });
    assert.equal(exitCode, 1);
  } finally {
    rmSync(rootDir, { recursive: true, force: true });
  }
  assert.ok(logger.messages.some((message) => message.includes("POLICY FAILURE")));
});

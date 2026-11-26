# Time-bound vulnerability exception: Create React App build toolchain

- **Owner:** `@An619`
- **Review/expiry date:** 2027-02-22
- **Policy source:** [`../vulnerability-exceptions.json`](../vulnerability-exceptions.json)
- **Evidence captured:** 2026-11-24, `npm audit --json` against the checked-in `frontend/package-lock.json`

## Accepted risk and scope

The frontend lockfile currently resolves `react-scripts@5.0.1` and its development-only transitive build/test toolchain to 16 high-severity npm audit findings. The affected packages and exact lockfile versions are enumerated in the exception policy. The reports identify the findings as development dependencies. The exception is limited to those exact package versions, exact dependency paths, and the `frontend` project; a changed version, dependency path, or newly reported finding fails the policy check.

The production dependency audit remains a separate blocking gate at HIGH severity. It currently reports three moderate findings in the Elastic EUI / PrismJS / Refractor dependency chain; those remain visible in CI output and are not covered by this high-severity exception. The exception does **not** mean the build toolchain is safe: a compromised build dependency could affect generated frontend assets.

## Rationale and compensating controls

The current Create React App 5 toolchain does not offer a compatible non-major `react-scripts` update that resolves the full set. Blindly applying overrides or replacing the build toolchain during this CI-hardening change risks breaking the existing frontend. Production images contain the compiled frontend assets in the unprivileged NGINX runtime stage; they do not copy the Node build dependency tree.

Controls while the exception is active:

- Keep the exact-version policy check in CI; new, changed, production-scope, or expired findings fail the workflow.
- Run the production-only audit as a blocking gate.
- Keep image publication restricted to a successful `main` push after required checks.
- Do not expose repository secrets to forked pull requests through the Sonar job.
- Remove the exception as soon as the build toolchain migration/remediation is validated.

## Exit criteria

Before 2027-02-22, replace or upgrade the frontend build toolchain in a separately reviewed change, run frontend unit tests and production build, regenerate the lockfile, and confirm the full frontend audit has no unexcepted HIGH/CRITICAL findings. If that cannot be completed, review and renew this exception explicitly before expiry; CI intentionally fails once it expires.

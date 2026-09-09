# Security implementation rules

Distills OWASP Top 10:2025, ASVS 5.0.0 (levels 1-2), the OWASP Cheat Sheet Series, and language-specific dependency scanners. Applies across every language in this playbook.

## The core rules
1. Validate all input at trust boundaries with allowlists, syntactic then semantic. Never trust client-supplied data.
2. Never build commands or queries by string concatenation from untrusted input. Parameterize (SQL) or allowlist (shell/OS commands).
3. Never hardcode secrets. Env vars or a vault (`op://` refs or equivalent); pre-commit secret scanning.
4. Hash passwords with bcrypt or argon2. Never roll your own auth.
5. Run the language's dependency-CVE scanner before shipping: `cargo audit`/`cargo deny` (Rust), Bandit plus `pip-audit` (Python, not the nonexistent `pip audit`; `uv audit` shipped June 2026 as a faster alternative but is still preview/unstable and lockfile-only, don't rely on it yet), `pnpm audit` (TypeScript/Node), ShellCheck (Bash, for injection-class issues).
6. Error handling never leaks stack traces or secrets to logs or output.
7. Least privilege by default: scoped CORS (no wildcard in prod), scoped tokens over root or service-account credentials.
8. Supply-chain provenance is not optional: signed CI builds, pinned lockfiles, never `curl | bash`. OWASP ranks Software Supply Chain Failures #3 (A03:2025), up from a subset of #6 in 2021.
9. Close default-misconfiguration gaps before shipping: no default/sample credentials, no verbose framework error pages in prod, no open cloud storage buckets, security headers set (OWASP A02:2025, #2 risk).
10. Emit security-relevant logs, not just error logs: auth failures, access-control denials, and input-validation rejections need to exist and reach an alerting path, not just a log file nobody reads (OWASP A09:2025).
11. **The allowlist itself takes no untrusted input.** Rule 1 says validate input with an allowlist; this is the failure one level up, where the allowlist is partly supplied by the thing it defends against, and rule 1 does not catch it because the validation looks correct. Where policy must vary per tenant, job or caller, untrusted input may SELECT among values the operator reviewed, never supply one. Two corollaries, both learned the expensive way: when a guard over an attacker-influenced surface fails twice, make the SURFACE smaller rather than the check stricter (shrinking converges, guarding does not), and a wildcard is not a scope (`tenant-*` reads as "this tenant" and means "any tenant"). Worked case: seven HIGH findings across eight review passes, all in one feature, closed only by deleting the input rather than validating it harder (`ops-toolkit tools/hermes/docs/decisions/0031-security-allowlists-take-no-untrusted-input.md`).

## Reference depth
For a specific vulnerability class, read the matching OWASP Cheat Sheet (cheatsheetseries.owasp.org) rather than re-deriving the rule. Target ASVS 5.0.0 level 1 for anything personal-scale, level 2 once real user data or business logic is involved.

## Sources
- [OWASP Top 10:2025](https://owasp.org/Top10/2025/)
- [OWASP Application Security Verification Standard 5.0.0](https://owasp.org/www-project-application-security-verification-standard/)
- [OWASP Cheat Sheet Series index](https://cheatsheetseries.owasp.org/index.html)
- [PyPA pip-audit](https://github.com/pypa/pip-audit)
- [Astral: vulnerability and malware checks in uv (`uv audit`)](https://astral.sh/blog/uv-audit)

Verified: 2026-08-03; rule 11 added 2026-09-09.

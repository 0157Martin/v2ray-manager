# Validation status

## 6.0.0 architecture cleanup — 2026-10-06

- Removed themed page downloads and their menu, mutation and recovery branches; generic placeholder
  creation, write failure and existing-content preservation remain covered.
- Link and native client JSON tests cover one shared entry-port policy for managed Caddy WebSocket,
  direct WebSocket, explicit CDN override and TLS-XHTTP.
- A regression test rejects a false managed-route match when the requested path and backend occur in
  different Caddy matchers.
- Ubuntu 24.04 CI passed ShellCheck, unit/bootstrap/editing/recovery/hardening tests and the complete
  latest-stable Xray configuration matrix: [run 37419583252](https://github.com/0157Martin/v2ray-manager/actions/runs/37419583252).
- Existing website preservation is established by sandboxed filesystem tests. Live Caddy reload,
  public DNS/CDN behavior and production client interoperability still require deployment validation.

## 5.7.3 renewal-conflict scope fix — 2026-10-05

- Regression coverage verifies that a standalone Certbot renewal configuration blocks a stopped/new
  Caddy activation but does not block route synchronization when Caddy is already active.
- `v2ray doctor` continues to report the underlying renewal conflict for an active deployment.

## 5.7.2 audit fixes — 2026-10-05

Host: Windows / Git Bash; ShellCheck; Xray 26.3.27 Windows amd64.

- Bash syntax/layout, ShellCheck, unit/bootstrap/editing/recovery tests are covered by the local verification script.
- New `tests/hardening.sh` exercises the real mutation child-process boundary with sandboxed paths and mocked service operations: WARP failure, certificate copy/preflight failure, TERM interruption, Caddy migration failure, unrelated-node drift and standalone renewal conflict.
- New `tests/private-routing.py` ran real Xray: loopback IPv4, IPv4-mapped IPv6, localhost and a domain mapped to a private IP were blocked. A separate exact-port positive control reached the same local HTTP server.
- All 12 server/client profiles, link-field comparisons, combined inbounds and WARP routing were accepted by the real core. The REALITY handshake/traffic portion was explicitly skipped with `CONFIGURATION_ONLY=1`; the independent private-routing traffic test still ran.
- Real flock concurrency and inherited-lock tests are present in `hardening.sh` and wired into Ubuntu CI, but explicitly skipped on Windows. They are not claimed as locally passed. Linux ownership/systemd and live ACME issuance/renewal were not exercised here.

Reproduce against a selected core release with `XRAY_TEST_TAG=v26.3.27 bash tests/xray-config.sh`.
The default still resolves the latest stable release. `XRAY_TEST_ARCHIVE` optionally reuses a downloaded
ZIP and its adjacent `.dgst`; the same SHA-256 verification is always applied. CI uses the full REALITY
traffic test by default. This validation does not establish production Caddy/CDN/client interoperability.

## Earlier validation record

Host: Windows, Git Bash, ShellCheck 0.11.0, Xray 26.3.27 (Windows amd64).

Passed:

- ShellCheck and per-file Bash syntax checks.
- Unit checks, including canonical UUIDs, real TLS certificate/key/hostname checks,
  system-CA rejection of an untrusted self-signed certificate, and real X25519 key pairs.
- Recovery/export regression scenarios, including stale primary state, disabled primary
  nodes, placeholder addresses, IPv6 URI formatting, config mismatch and node-state isolation;
  certificate renewal success, invalid material, config/restart rollback, stopped-service
  preservation, webroot arguments, client JSON selection, disabled-node rejection and multiple
  user credentials on one inbound.
- Bootstrap revision selection and invalid-download rejection.
- Real Xray config validation for all 12 server profiles, all 12 native client configurations,
  multiple users on one inbound and a combined multi-inbound configuration.
- Decoding all 12 exported link formats and comparing their fields with both server and
  native client configuration, including Vision flow and absence of server secrets in clients.

Not passed / not established:

- The new full loopback REALITY traffic test did not pass on this host: Xray reported connection
  refusal when dialing the local TLS target. Independent Python/OpenSSL TLS probes succeeded.
  The cause is not established. The final configuration-only run explicitly skipped the traffic
  portion; it must not be reported as a successful end-to-end test.
- Linux systemd, Linux file ownership, automatic certificate issuance/renewal and deployment
  on a real server are outside the Windows local test. GitHub Actions runs the portable test suite
  and full loopback Xray traffic check on Ubuntu 24.04 for every push.
- These results do not diagnose a particular user's client latency failure, cloud firewall,
  NAT mapping or protocol support. Server/client diagnostics are still needed for that incident.

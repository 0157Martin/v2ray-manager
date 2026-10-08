# Validation status

## 6.5.0 staged feature validation — 2026-10-08

Local host: Windows / Git Bash; ShellCheck 0.11.0; jq 1.8.2; Xray 26.3.27 and Caddy 2.11.7
(Windows amd64). Release archives were checked against their published SHA-256 digests.

- All 13 generated server and client configurations passed the real Xray parser. Each profile carried
  a controlled HTTP request over loopback. REALITY covered RAW, gRPC and XHTTP; ordinary TLS covered
  RAW, WebSocket and gRPC; XHTTP traversed a real generated Caddy route in `auto`, `packet-up` and
  `stream-up` modes.
- Hysteria2 used a UDP listener with TLS/QUIC, carried the controlled request with valid authentication,
  and rejected an invalid credential. This establishes same-version Xray interoperability on the local
  host, not public-network reachability or compatibility with every third-party Hysteria2 client.
- JSON state parsing rejects command substitution and unknown fields without executing file contents.
  Declarative planning is read-only; apply/no-op, XHTTP mode persistence, redacted JSON diagnostics and
  Prometheus text output have regression coverage.
- `tools/build.sh --check` verifies that the deployable `v2ray.sh` exactly matches the ordered `src/`
  modules. The complete Ubuntu, ARM64, Debian and baseline/latest Xray matrix passed in
  [GitHub Actions run 37705794635](https://github.com/0157Martin/v2ray-manager/actions/runs/37705794635).

Still not established locally: Debian/Ubuntu systemd and ownership behavior, native Linux flock and
symlink checks, public UDP/TCP ingress, ACME issuance, cloud firewall rules, CDN behavior, and live
upgrade of a production host.

## 6.4.0 reliability candidate — 2026-10-07

Local host: Windows / Git Bash; ShellCheck 0.11.0; jq 1.8.2; real Xray 26.3.27
(Windows amd64). Native jq used a local MSYS argument adapter to preserve JSON string arguments
while translating file paths; that host-only adapter is not part of the Linux release.

- Layout/Bash syntax and ShellCheck passed.
- Unit, bootstrap, editing, recovery and hardening suites passed. Recovery additionally covers
  explicit core rollback after a successful update, including matching GeoData.
- Reliability regression coverage includes release pin format, version arguments, read-only checks,
  offline component reuse, checksum rejection without replacement, older candidate schema rejection,
  paired rollback, failed migration, preserved service states, persistent journal recovery, corrupted
  snapshot rejection, and higher schema versions in disabled nodes.
- All four locked component files were downloaded from their exact commits, matched the embedded
  SHA-256 digests and passed `bash -n`. Their live package installation was not executed.
- The real Xray accepted all 12 server/client profiles, combined inbounds, multi-user credentials and
  WARP routing. All 12 exported links matched the generated configurations.
- The full REALITY RAW loopback client/server test passed and carried a real HTTP request;
  `CONFIGURATION_ONLY` was not enabled. This supersedes the older Windows traffic-test limitation
  recorded below for this local run only.
- Real Xray private-target tests blocked loopback IPv4, mapped IPv4, localhost and a private-resolving
  domain; an exact-port positive control reached the local target.
- Workflow YAML was parsed locally. Ubuntu 22.04/24.04, Ubuntu 24.04 ARM64, Debian 12/13 containers
  and baseline/latest core jobs are configured, but the modified GitHub workflow has not been run.

Not established locally: real Linux systemd/ownership behavior, flock concurrency/inheritance and
native symlink snapshot checks (explicitly skipped under MSYS), ACME issuance/renewal, public ingress,
Caddy/CDN interoperability, Hysteria 2, or live deployment on Debian/Ubuntu. Regression service and
failure-injection tests use temporary paths and mocks. An interrupted journal is simulated; no claim
is made about power-loss durability or recovery from damaged storage.

Reproduce on Linux with ShellCheck/jq/OpenSSL installed:

```bash
bash tools/verify-layout.sh
shellcheck install.sh v2ray.sh config/defaults.sh tools/*.sh tests/*.sh
bash tests/unit.sh
bash tests/bootstrap.sh
bash tests/editing.sh
bash tests/recovery.sh
bash tests/hardening.sh
bash tests/reliability.sh
XRAY_TEST_TAG=v26.3.27 bash tests/xray-config.sh
```

## 6.0.1 optional page deployment — 2026-10-06

- Recovery tests cover explicit built-in page replacement, invalid template rejection, failed remote
  download and preservation of the existing website.
- Optional Portfolio/Resume deployment remains outside the default setup path and publishes only
  after manifest and per-file digest validation.
- Ubuntu 24.04 CI passed the complete verification and Xray configuration matrix:
  [run 37421175187](https://github.com/0157Martin/v2ray-manager/actions/runs/37421175187).

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

# Validation status

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

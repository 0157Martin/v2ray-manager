# Local validation: 4.3.0

Host: Windows, Git Bash, ShellCheck 0.11.0, Xray 26.3.27 (Windows amd64).

Passed:

- ShellCheck and per-file Bash syntax checks.
- Unit checks, including canonical UUIDs, real TLS certificate/key/hostname checks,
  system-CA rejection of an untrusted self-signed certificate, and real X25519 key pairs.
- 29 recovery/export regression scenarios, including stale primary state, disabled primary
  nodes, placeholder addresses, IPv6 URI formatting, config mismatch and node-state isolation;
  certificate renewal success, invalid material, config/restart rollback, stopped-service
  preservation, webroot arguments, client JSON selection and disabled-node rejection.
- Bootstrap revision selection and invalid-download rejection.
- Real Xray config validation for all 12 server profiles, all 12 native client configurations
  and a combined multi-inbound configuration.
- Decoding all 12 exported link formats and comparing their fields with both server and
  native client configuration, including Vision flow and absence of server secrets in clients.

Not passed / not established:

- The new full loopback REALITY traffic test did not pass on this host: Xray reported connection
  refusal when dialing the local TLS target. Independent Python/OpenSSL TLS probes succeeded.
  The cause is not established. The final configuration-only run explicitly skipped the traffic
  portion; it must not be reported as a successful end-to-end test.
- Linux systemd, Linux file ownership, automatic certificate issuance/renewal and deployment
  on a real server have not been exercised locally. The CI workflow runs the full test on Ubuntu,
  but these local changes have not been pushed, so there is no CI result for this revision yet.
- These results do not diagnose a particular user's client latency failure, cloud firewall,
  NAT mapping or protocol support. Server/client diagnostics are still needed for that incident.

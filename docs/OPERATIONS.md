# Operations

## Routine checks

Run `v2ray doctor` after installation, configuration changes, operating-system upgrades, or
firewall changes. Use `v2ray status` for the full systemd state and `v2ray log` for recent logs.
Resolved production cases and their evidence-based recovery steps are recorded in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Backup and recovery

`v2ray backup` creates a root-readable archive in `/var/backups/v2ray-manager`. The manager keeps
the ten newest archives. Unique filenames prevent two backups in one second from overwriting each
other. `v2ray restore` validates using the archived certificates, restores shared and per-domain
certificate files and node state, then restarts the service and observes it for five seconds.

## Credential rotation

`v2ray rotate [node-id]` replaces the selected inbound's REALITY X25519 key pair and Short ID.
The sole enabled inbound is selected automatically; with multiple enabled inbounds, omitting
the ID prompts for one. Existing client profiles for that inbound stop working immediately,
so distribute the new link from `v2ray link node-id` through an appropriate secure channel.
`v2ray change [node-id]` uses the same selection rules. Both commands read the current node
registry, preserving user removals and other changes made since installation.

Batch editing restores the pre-edit node registry, certificates and config on input, validation
or restart failure, including interruption. After a restart attempt, rollback also restarts the
restored configuration. A failed rollback reports the retained backup for manual recovery.

## Updating

- `v2ray update` stages the project's pinned Xray baseline and GeoData, verifies the release digest, and
  validates the existing config before replacing installed files. It restores the previous core
  and GeoData on copy or restart/health-check failure. A stopped service remains stopped. If rollback
  fails, the transaction directory is retained and printed for manual recovery. The service unit
  is preserved during core-only updates.
- `v2ray upgrade` (with `v2ray update.sh` retained as an alias) resolves the repository's current
  commit and downloads that immutable revision. After replacement, the new manager migrates its
  state schema, rebuilds the Xray configuration, and compares connection-relevant fields with the
  pre-update configuration. Unexpected changes restore both configuration and the previous manager.
  Set `V2M_MANAGER_REF` to a full 40-character commit SHA to pin a specific revision. The bootstrapper
  uses the same policy. Syntax and identity checks supplement HTTPS; they are not signature checks.
- `v2ray update.core --version v26.3.27` selects a release explicitly; `--latest` opts into the latest
  upstream release. Add `--check` for a read-only version query. Default installations and updates use
  `RECOMMENDED_XRAY_VERSION`; `V2M_XRAY_VERSION` overrides the default. `v2ray rollback.core` restores
  the previous core and matching GeoData only after validating the current configuration.
- `v2ray rollback.sh` restores the paired manager/data snapshot, including Caddy configuration,
  the Xray service unit, component scripts and previous Xray/Caddy active states. It removes changes
  made after that snapshot. It does not restore system packages, web content, the core, or external
  WARP backend state. Legacy script-only backups are rejected by automated rollback.
- `v2ray recover` restores an interrupted manager transaction recorded by `manager.pending`.
  If the installed command cannot run, use the exact `recovery.sh` path printed by the failure.
  Snapshots include SHA-256 manifests; corruption fails closed. Transaction generations are retained
  separately from the ten rotating configuration archives; monitor disk space and never remove a
  generation referenced by a pending or rollback pointer.

Only mutating operations trigger schema migration, after acquiring the lock. Read-only commands do
not migrate state. Higher schema versions in either enabled or disabled nodes are rejected.
See [RELIABILITY.md](RELIABILITY.md) for dependency pinning and recovery boundaries.

Health checks require the same active PID and restart count for five seconds. They detect immediate
crashes but do not prove remote connectivity, firewall reachability, or long-term stability.
Re-running installation retains the installed core; use the dedicated update command to upgrade it.
Core and manager updates are separate so operators can control changes independently.

For a manual core recovery after an automatic rollback failure, use the printed `previous` directory:
it contains `xray`, `geoip.dat`, and `geosite.dat`. Stop the service, restore these to
`/usr/local/bin/xray-core` (0755) and `/usr/local/share/xray/` (0644), then run a configuration check
and start the service. Do not remove that directory until recovery succeeds.

## TLS certificates

Explicit `V2M_CERT_FILE` and `V2M_KEY_FILE` take precedence. Otherwise, the manager looks for a valid
matching certificate before using Certbot's standalone HTTP challenge. Set `V2M_SERVER_NAME` to a
domain you control; its DNS must point to this server and public TCP 80 must be reachable.
Standalone mode requires port 80 to be free. A domain already managed by this project's Caddy site automatically uses its verified webroot. For another existing web server set `V2M_ACME_WEBROOT`
to its absolute document-root path and allow HTTP access to `.well-known/acme-challenge/`.
The manager does not stop an existing web server. Automatic issuance accepts Let's Encrypt's terms;
`V2M_ACME_EMAIL` optionally supplies the account email. Certbot renewals use a deploy hook to copy
certificates into `/etc/xray/tls/<domain>/` after checking dates, hostname, key and CA chain.
Config/restart failure restores the old pair and retains a backup; stopped services stay stopped.
For acme.sh, use `--install-cert` to stable deployment paths before explicit import; the manager
does not discover its internal working files. External certificates require their own renewal
deployment arrangement; only Certbot gets an automatic deploy hook here.

UUIDs are generated automatically unless explicitly supplied, then checked for the canonical
8-4-4-4-12 hexadecimal format. Before export, the manager checks the active inbound against
`config.json`, verifies REALITY public/private key correspondence or TLS validity dates, hostname
and private-key correspondence, and refuses placeholder addresses. Automatically discovered TLS
certificates must pass system CA chain verification; explicit private-CA certificates remain
supported with a warning that clients must trust that CA.

## Export and connectivity tests

`tests/xray-config.sh` validates all profiles and parses every generated share link back into
parameters for comparison with both server and native client configurations. `v2ray client [id]`
exports a checked native Xray client configuration with loopback SOCKS/HTTP listeners at ports
10800/10801. Store the output with `umask 077`; it contains the node credential.
Its Python helper also starts temporary
loopback Xray client/server processes and sends an HTTP request through the default REALITY link.
The TLS target and destination are local test servers; no production credentials are involved.
CI runs this full test on Ubuntu. Set `PYTHON` when the Python executable has a different path.
For hosts unable to run the local traffic test, `CONFIGURATION_ONLY=1` explicitly skips it and
prints a skip notice; the remaining checks do not establish end-to-end connectivity.
`KEEP_TEST_ARTIFACTS=1` retains test fixtures for debugging; these contain generated test keys.

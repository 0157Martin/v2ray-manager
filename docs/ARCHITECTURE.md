# Architecture

The repository intentionally keeps `v2ray.sh` as a self-contained release artifact. A server only
needs that file after installation, which avoids runtime failures caused by partially downloaded
modules. Supporting directories have separate responsibilities:

- `install.sh`: minimal network bootstrapper.
- `v2ray.sh`: installer, configuration renderer, service manager, backup and diagnostics.
- `templates/`: human-readable reference configurations.
- `tests/`: pure unit tests and an integration test against the latest stable Xray Core.
- `tools/`: repository maintenance checks.
- `config/`: defaults documented for maintainers; runtime defaults remain in the single-file artifact.

The manager owns proxy configuration, service lifecycle, certificates, Caddy routing, WARP policy,
backup and diagnostics. Default installation never fetches themed page assets. Caddy static roots are
user content: the manager creates a generic placeholder only when a root is empty and never overwrites
an existing index during upgrade or route synchronization. An explicit `caddy page` operation may
deploy an optional page from an allowlisted repository after commit pinning, manifest validation and
per-file digest verification; publication swaps the staged directory only after every check succeeds.

`v2ray-manager` is the trunk controller for the project family. WARP transport implementations are
branch projects (independent repositories, not Git branches) named `warp-wireguard-manager` and
`warp-masque-manager`. The trunk selects, downloads, verifies, invokes, switches and rolls back a branch through the common
`install/status/test/start/stop/diagnose/repair/uninstall/version` command contract. Each backend must
bind a loopback SOCKS5 listener (default `127.0.0.1:40000`) and must verify real traffic with a
Cloudflare trace response containing `warp=on`; a process, registration or listener alone is not a
successful installation. Each branch also retains its own installer, verifier, uninstaller and
standalone runtime. Backend state is independent from Xray policy state, so a failed switch can restart
the previous backend without rewriting inbound definitions.

Caddy operations follow the same trunk/branch model. `caddy-manager` owns package installation,
site rendering, Caddy validation, service repair and software removal, and exposes
`install/verify/static/reverse/xray/page/status/log/repair/uninstall/version`. The trunk downloads and
validates the branch command, supplies the Xray node directory for multi-path route rendering, and
keeps Caddy files and service state inside the main mutation snapshot. The branch can also be installed
and operated on a server without Xray; uninstalling the package preserves sites, certificates and web data.

Client-facing ports are derived by one policy function. TLS-XHTTP uses Caddy 443; TLS WebSocket
profiles use 443 only when the managed site contains the matching domain, path and Xray backend.
Otherwise their actual listener port is exported. Server renderers, links, native client JSON and
diagnostics must not independently reimplement this decision.

Configuration changes follow this sequence:

1. Start a fresh mutation process and acquire the shared flock before reading mutable state.
2. Snapshot the complete configuration directory, Caddy main/site files, unit file and running states.
3. Stage certificate/key pairs and render a candidate configuration.
4. Validate it with the installed Xray Core.
5. Publish JSON through a same-directory rename with restrictive ownership and permissions.
6. Restart the service and synchronize any migration-dependent Caddy routes.
7. Restore the snapshot and original running states on failure or INT/TERM. Retain the snapshot if recovery fails.

Interactive menus invoke the same fresh-process boundary as CLI commands, preventing an enclosing
`|| true` from suppressing Bash errexit inside a mutation. Idle menus do not hold the lock. The
manager-update/migration subprocess inherits FD 9; its descriptor path is checked before reusing
the lock. The snapshot transaction covers managed configuration, not apt packages, ACME accounts,
WARP registrations or arbitrary external effects. SIGKILL and power loss cannot execute EXIT traps.

Routing defaults deny loopback, private, link-local, multicast and selected address-translation
ranges before selecting direct/WARP. IPOnDemand includes resolved domain destinations in the
policy. This is an application routing boundary, not a replacement for operating-system isolation
or separately protecting management endpoints. No private-network access whitelist is exposed yet.

Migration compares per-tag canonical connection fields. Only VLESS TLS-XHTTP's server-side TLS
removal and loopback binding are normalized; authentication, ports, paths and other inbounds remain
strictly compared. A Caddy synchronization failure is fatal. Standalone Certbot renewal configurations
must be migrated before Caddy can take port 80.

Core downloads follow Xray's stable GitHub Release endpoint. Both the archive and its `.dgst`
file are downloaded, and the SHA-256 digest is verified before extraction.

Core updates use a separate staging directory and validate the existing configuration with the
candidate binary and candidate GeoData. The current binary and data are copied before replacement;
an EXIT trap restores them if replacement or the five-second service health check fails. Each file
replacement uses a same-directory rename. The set of three files is not globally atomic, so the
transaction backup covers partial replacement. Failed rollback material is retained for recovery.
Core-only updates preserve the unit file and a deliberately stopped service remains stopped.

Manager updates resolve a Git commit before download, validate syntax and project markers, save
the installed manager, and replace it through a same-directory rename. The bootstrapper uses the
same revision selection policy. These checks rely on GitHub over HTTPS and do not verify a separate
release signature.

Configuration recovery validates against staged archived TLS files before writing live files.
Both legacy shared certificates and per-domain certificate directories are supported. Backup
filenames are unique; retention and newest-backup selection use modification time.

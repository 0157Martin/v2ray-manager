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

Configuration changes follow this sequence:

1. Back up the current configuration and manager state.
2. Render a new configuration to a temporary file.
3. Validate it with the installed Xray Core.
4. Install it atomically with restrictive ownership and permissions.
5. Restart the service.
6. Restore the backup automatically if restart fails.

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

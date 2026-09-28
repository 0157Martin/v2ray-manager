# Operations

## Routine checks

Run `v2ray doctor` after installation, configuration changes, operating-system upgrades, or
firewall changes. Use `v2ray status` for the full systemd state and `v2ray log` for recent logs.

## Backup and recovery

`v2ray backup` creates a root-readable archive in `/var/backups/v2ray-manager`. The manager keeps
the ten newest archives. `v2ray restore` validates and restores the newest archive, then restarts
the service.

## Credential rotation

`v2ray rotate` replaces the REALITY X25519 key pair and Short ID. Existing client profiles stop
working immediately, so distribute the new link from `v2ray link` through an appropriate secure
channel.

## Updating

- `v2ray update` downloads and verifies the latest stable Xray Core, validates the existing config,
  and restarts the service.
- `v2ray update.sh` updates the manager from this repository and syntax-checks it before install.

Core and manager updates are separate so operators can control changes independently.

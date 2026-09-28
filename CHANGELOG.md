# Changelog

## 4.0.0

- Replaced the single-inbound model with a multi-inbound registry under `/etc/xray/nodes`.
- Added independent add, modify, enable, disable, delete, list, and link-output operations.
- Existing installations migrate automatically to a `primary` inbound.
- All active inbounds are merged into one validated Xray configuration with transactional backup and rollback.

## 3.1.0

- Expanded the selector to eleven modern and legacy-compatible protocol profiles.
- Added concise characteristics and deployment requirements directly to the protocol menu.

## 3.0.0

- Added five selectable VLESS profiles across REALITY/TLS and RAW/XHTTP/gRPC/WebSocket transports.
- Added profile-aware configuration rendering, share links, menus, certificate import, backup, and restore.
- Validate every generated profile against the latest stable Xray Core in CI.
- Added VLESS-gRPC-TLS, Trojan-REALITY-RAW, Trojan-WebSocket-TLS, and legacy VMess TCP/WS/gRPC profiles with in-menu guidance.

## 2.2.0

- Added an occupied-port preflight check that never stops an unrelated service.
- Added `V2M_ADDRESS` for servers whose reachable address differs from their detected outbound IP.
- Added the classic `v2ray change` submenu and a bilingual, field-oriented connection display.
- Added timestamped installation stages while retaining the modern VLESS REALITY stack.
- Preserve a pre-existing `/usr/local/bin/v2ray` manager and restore it on uninstall.

## 2.1.0

- Added automatic configuration backup and rollback on failed service restarts.
- Added manual `backup` and `restore` commands with ten-backup retention.
- Added `doctor` diagnostics for the core, configuration, service, DNS and listening port.
- Added non-interactive installation through `V2M_*` environment variables.
- Added unit tests and live configuration validation against the latest stable Xray Core.
- Added architecture, operations and security documentation.

## 2.0.0

- Replaced the legacy VMess/TCP default with Xray Core, VLESS, REALITY and XTLS Vision.
- Added release archive SHA-256 verification.
- Added REALITY credential rotation and hardened systemd service settings.
- Added migration handling for installations created by the 1.x series.

## 1.1.0

- Added the `v2ray` management command and one-line installation bootstrapper.

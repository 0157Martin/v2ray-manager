#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../v2ray.sh
source "$repo_dir/v2ray.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

valid_port 1 || fail "port 1 should be valid"
valid_port 65535 || fail "port 65535 should be valid"
! valid_port 0 || fail "port 0 should be invalid"
! valid_port 65536 || fail "port 65536 should be invalid"
valid_server_name www.microsoft.com || fail "normal hostname should be valid"
! valid_server_name localhost || fail "single-label hostname should be invalid"
! valid_server_name 'bad..example.com' || fail "hostname with empty label should be invalid"

parse_reality_credentials $'PrivateKey: private-new\nPassword (PublicKey): public-new\nHash32: unused'
[[ $PRIVATE_KEY == private-new ]] || fail "new private-key output was not parsed"
[[ $PUBLIC_KEY == public-new ]] || fail "new password output was not parsed"

parse_reality_credentials $'Private key: private-old\nPublic key: public-old'
[[ $PRIVATE_KEY == private-old ]] || fail "legacy private-key output was not parsed"
[[ $PUBLIC_KEY == public-old ]] || fail "legacy public-key output was not parsed"

PORT=443
UUID=11111111-1111-4111-8111-111111111111
SERVER_NAME=www.microsoft.com
PRIVATE_KEY=test-private-key
SHORT_ID=0123456789abcdef
temporary=$(mktemp)
trap 'rm -f "$temporary"' EXIT
render_config "$temporary"
jq -e '.inbounds[0].protocol == "vless"' "$temporary" >/dev/null || fail "protocol mismatch"
jq -e '.inbounds[0].streamSettings.security == "reality"' "$temporary" >/dev/null || fail "security mismatch"
jq -e '.inbounds[0].settings.clients[0].flow == "xtls-rprx-vision"' "$temporary" >/dev/null || fail "flow mismatch"

printf '%s\n' 'Unit tests passed.'

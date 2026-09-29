#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../v2ray.sh
# shellcheck disable=SC1091
source "$repo_dir/v2ray.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

valid_port 1 || fail "port 1 should be valid"
valid_port 65535 || fail "port 65535 should be valid"
! valid_port 0 || fail "port 0 should be invalid"
! valid_port 65536 || fail "port 65536 should be invalid"
valid_uuid 11111111-1111-4111-8111-111111111111 || fail 'valid UUID rejected'
! valid_uuid ------------------------------------ || fail '36 hyphens accepted as UUID'
! valid_uuid 111111111111111111111111111111111111 || fail 'UUID without required separators accepted'
valid_server_name www.microsoft.com || fail "normal hostname should be valid"
! valid_server_name localhost || fail "single-label hostname should be invalid"
! valid_server_name 'bad..example.com' || fail "hostname with empty label should be invalid"

export ADDRESS=23.95.15.200
[[ $(server_address) == 23.95.15.200 ]] || fail "explicit server address should override public-IP detection"

unset PORT V2M_PORT
export V2M_NONINTERACTIVE=1 PROFILE=vless-reality-raw
export UUID=11111111-1111-4111-8111-111111111111
export SERVER_NAME=www.microsoft.com REMARK=default-port-test
export PRIVATE_KEY=test-private PUBLIC_KEY=test-public SHORT_ID=0123456789abcdef
# Called indirectly by ask_server_values.
# shellcheck disable=SC2329
find_free_port() {
  [[ $1 == 443 ]] || fail "automatic installation did not start at port 443"
  printf '443'
}
ask_server_values
[[ $PORT == 443 ]] || fail "automatic installation did not select port 443"
unset V2M_NONINTERACTIVE

parse_reality_credentials $'PrivateKey: private-new\nPassword (PublicKey): public-new\nHash32: unused'
[[ $PRIVATE_KEY == private-new ]] || fail "new private-key output was not parsed"
[[ $PUBLIC_KEY == public-new ]] || fail "new password output was not parsed"

parse_reality_credentials $'Private key: private-old\nPublic key: public-old'
[[ $PRIVATE_KEY == private-old ]] || fail "legacy private-key output was not parsed"
[[ $PUBLIC_KEY == public-old ]] || fail "legacy public-key output was not parsed"
parse_reality_credentials $'PrivateKey: private-new\r\nPassword (PublicKey): public-new\r\n'
[[ $PRIVATE_KEY == private-new && $PUBLIC_KEY == public-new ]] || fail 'CRLF contaminated REALITY credentials'

export PORT=443
export UUID=11111111-1111-4111-8111-111111111111
export SERVER_NAME=www.microsoft.com
PRIVATE_KEY=test-private-key
export SHORT_ID=0123456789abcdef
export PROFILE=vless-reality-raw
export PATH_VALUE=
temporary=$(mktemp)
trap 'rm -f "$temporary"' EXIT
render_config "$temporary"
jq -e '.inbounds[0].protocol == "vless"' "$temporary" >/dev/null || fail "protocol mismatch"
jq -e '.inbounds[0].streamSettings.security == "reality"' "$temporary" >/dev/null || fail "security mismatch"
jq -e '.inbounds[0].settings.clients[0].flow == "xtls-rprx-vision"' "$temporary" >/dev/null || fail "flow mismatch"

PROFILE=vless-reality-xhttp
PATH_VALUE=/test-path
render_config "$temporary"
jq -e '.inbounds[0].streamSettings.network == "xhttp"' "$temporary" >/dev/null || fail "xhttp network mismatch"
jq -e '.inbounds[0].streamSettings.xhttpSettings.path == "/test-path"' "$temporary" >/dev/null || fail "xhttp path mismatch"

printf '%s\n' 'Unit tests passed.'

# Exercise the existing certificate discovery validation with real certificate/key pairs.
tls_test_dir=$(mktemp -d)
trap 'rm -f "$temporary"; rm -rf -- "$tls_test_dir"' EXIT
MSYS2_ARG_CONV_EXCL='/CN=' openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=example.com' -keyout "$tls_test_dir/key.pem" -out "$tls_test_dir/cert.pem" >/dev/null 2>&1
SERVER_NAME=example.com
tls_pair_valid "$tls_test_dir/cert.pem" "$tls_test_dir/key.pem" || fail 'matching certificate rejected'
! tls_chain_valid "$tls_test_dir/cert.pem" || fail 'untrusted self-signed certificate accepted by system CA check'
SERVER_NAME=wrong.example.com
! tls_pair_valid "$tls_test_dir/cert.pem" "$tls_test_dir/key.pem" || fail 'wrong hostname accepted'
SERVER_NAME=example.com
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tls_test_dir/wrong.key" >/dev/null 2>&1
! tls_pair_valid "$tls_test_dir/cert.pem" "$tls_test_dir/wrong.key" || fail 'wrong private key accepted'
printf '%s\n' 'TLS certificate tests passed.'

openssl genpkey -algorithm X25519 -out "$tls_test_dir/reality.pem" >/dev/null 2>&1
PRIVATE_KEY=$(openssl pkey -in "$tls_test_dir/reality.pem" -outform DER | tail -c 32 | base64 -w 0 | tr '/+' '_-' | tr -d '=')
PUBLIC_KEY=$(openssl pkey -in "$tls_test_dir/reality.pem" -pubout -outform DER | tail -c 32 | base64 -w 0 | tr '/+' '_-' | tr -d '=')
SHORT_ID=0123456789abcdef
reality_pair_valid || fail 'matching REALITY key pair rejected'
saved_public=$PUBLIC_KEY
PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
! reality_pair_valid || fail 'mismatched REALITY public key accepted'
PUBLIC_KEY=$saved_public
SHORT_ID=123
! reality_pair_valid || fail 'odd-length Short ID accepted'
printf '%s\n' 'REALITY credential tests passed.'

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
valid_route_target 1.1.1.1 || fail 'IPv4 route target rejected'
valid_route_target 2001:4860:4860::8888 || fail 'IPv6 route target rejected'
valid_route_target client.example.com || fail 'hostname route target rejected'
! valid_route_target 'https://example.com' || fail 'URL accepted as route target'
! valid_route_target 'example.com;id' || fail 'shell metacharacter accepted as route target'

export ADDRESS=edge.example.com
[[ $(server_address) == edge.example.com ]] || fail "explicit server domain should be used for exports"

unset PORT V2M_PORT
export V2M_NONINTERACTIVE=1 PROFILE=vless-reality-raw
export UUID=11111111-1111-4111-8111-111111111111
export SERVER_NAME=www.microsoft.com REMARK=default-port-test
export PRIVATE_KEY=test-private PUBLIC_KEY=test-public SHORT_ID=0123456789abcdef
# Called indirectly by ask_server_values.
# shellcheck disable=SC2329
find_free_port() {
  case "$1" in
    443) printf '443' ;;
    24443) printf '24443' ;;
    *) fail "unexpected automatic port search start: $1" ;;
  esac
}
ask_server_values
[[ $PORT == 443 ]] || fail "automatic installation did not select port 443"
unset PORT
export V2M_PROFILE=vless-tls-ws V2M_SERVER_NAME=cdn.example.com V2M_ADDRESS=cdn.example.com V2M_PATH=/cdn
ask_server_values
[[ $PORT == 24443 ]] || fail "HTTP/CDN installation did not reserve public port 443 for Caddy"
unset V2M_PROFILE V2M_SERVER_NAME V2M_ADDRESS V2M_PATH
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

export EXTRA_UUIDS=22222222-2222-4222-8222-222222222222,33333333-3333-4333-8333-333333333333
render_config "$temporary"
jq -e '.inbounds[0].settings.clients | length == 3 and .[1].id == "22222222-2222-4222-8222-222222222222"' "$temporary" >/dev/null || fail 'multiple inbound users did not render'
export EXTRA_UUIDS=''

PROFILE=vless-reality-xhttp
PATH_VALUE=/test-path
[[ $(profile_group) == reality ]] || fail 'REALITY protocol group mismatch'
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

PROFILE=vless-tls-ws
[[ $(profile_group) == http-tls ]] || fail 'TLS HTTP protocol group mismatch'
PORT=24443
PATH_VALUE=/cdn-test
ADDRESS=example.com
REMARK=cdn-export-test
export TLS_CERT_PATH_OVERRIDE="$tls_test_dir/cert.pem"
export TLS_KEY_PATH_OVERRIDE="$tls_test_dir/key.pem"
render_config "$temporary"
cdn_link=$(show_connection_loaded "$temporary" edge.cdn.example.com)
[[ $cdn_link == *'vless://11111111-1111-4111-8111-111111111111@edge.cdn.example.com:443?'* ]] || fail 'CDN export did not use override domain and port 443'
[[ $cdn_link == *'sni=example.com'* && $cdn_link == *'host=example.com'* ]] || fail 'CDN export did not preserve domain SNI and Host'
export EXTRA_UUIDS=22222222-2222-4222-8222-222222222222,33333333-3333-4333-8333-333333333333
render_config "$temporary"
multi_links=$(show_connection_loaded "$temporary" edge.cdn.example.com)
[[ $(grep -c 'vless://' <<<"$multi_links") == 3 ]] || fail 'multi-user inbound did not export three links'
[[ $multi_links == *'cdn-export-test-1'* && $multi_links == *'cdn-export-test-3'* ]] || fail 'sub-link remarks were not numbered'
export EXTRA_UUIDS=''
printf '%s\n' 'CDN address export test passed.'

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

# The network call itself is mocked; this verifies command selection without
# consuming traffic or installing packages on the test host.
# shellcheck disable=SC2329
speedtest-cli() { printf '%s\n' 'mock-speedtest-ok'; }
speedtest_output=$(run_speedtest)
[[ $speedtest_output == *mock-speedtest-ok* ]] || fail 'speedtest-cli was not invoked'
printf '%s\n' 'Speedtest command-selection test passed.'

# Route commands are mocked to verify argument handling without network traffic
# or package installation on the test host.
install_route_tools() { :; }
getent() { :; }
ping() { printf '%s\n' "mock-ping:$*"; }
mtr() { printf '%s\n' "mock-mtr:$*"; }
route_output=$(route_latency_test client.example.com)
[[ $route_output == *'mock-ping:-c 5 -W 2 client.example.com'* ]] || fail 'route latency ping arguments mismatch'
[[ $route_output == *'mock-mtr:--report --report-wide --show-ips --report-cycles 10 client.example.com'* ]] || fail 'MTR did not use ten report cycles'
printf '%s\n' 'Route and latency command test passed.'

caddy_static=$(mktemp)
caddy_reverse=$(mktemp)
caddy_xray=$(mktemp)
render_caddy_site static example.com '' "$caddy_static" || fail 'static Caddy site did not render'
grep -Fq 'root * /var/www/v2ray-manager/example.com' "$caddy_static" || fail 'static Caddy root mismatch'
render_caddy_site reverse proxy.example.com 127.0.0.1:8080 "$caddy_reverse" || fail 'reverse Caddy site did not render'
grep -Fq 'reverse_proxy 127.0.0.1:8080' "$caddy_reverse" || fail 'Caddy upstream mismatch'
valid_caddy_upstream '[::1]:3000' || fail 'IPv6 loopback upstream rejected'
! valid_caddy_upstream '0.0.0.0:8080' || fail 'non-loopback upstream accepted'
! valid_caddy_upstream '127.0.0.1:70000' || fail 'invalid upstream port accepted'
! render_caddy_site static localhost '' "$caddy_static" || fail 'invalid Caddy domain accepted'
render_caddy_site xray cdn.example.com 127.0.0.1:24443 "$caddy_xray" /a1b2c3 || fail 'Xray Caddy route did not render'
grep -Fq '@xray path /a1b2c3 /a1b2c3/*' "$caddy_xray" || fail 'Xray Caddy path matcher mismatch'
grep -Fq 'tls_server_name cdn.example.com' "$caddy_xray" || fail 'Xray upstream SNI mismatch'
! render_caddy_site xray cdn.example.com 127.0.0.1:24443 "$caddy_xray" '/bad path' || fail 'invalid transport path accepted'
valid_transport_path /a1b2c3 || fail 'valid transport path rejected'
! valid_transport_path //bad || fail 'double-slash transport path accepted'
rm -f -- "$caddy_static" "$caddy_reverse" "$caddy_xray"
printf '%s\n' 'Caddy configuration tests passed.'

warp_domains=$(normalize_warp_domains 'netflix.com, domain:openai.com,geosite:netflix')
[[ $warp_domains == 'domain:netflix.com,domain:openai.com,geosite:netflix' ]] || fail 'WARP domain normalization mismatch'
if (normalize_warp_domains 'https://invalid.example/path' >/dev/null 2>&1); then fail 'invalid WARP domain rule accepted'; fi
printf '%s\n' 'WARP policy tests passed.'

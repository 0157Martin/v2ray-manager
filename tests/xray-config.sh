#!/usr/bin/env bash
# Validates the generated server configuration against the latest stable Xray.
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../v2ray.sh
# shellcheck disable=SC1091
source "$repo_dir/v2ray.sh"

temporary_dir=$(mktemp -d)
trap 'if [[ ${KEEP_TEST_ARTIFACTS:-0} == 1 ]]; then printf "Test fixtures: %s\n" "$temporary_dir"; else rm -rf "$temporary_dir"; fi' EXIT
api_headers=(-H 'Accept: application/vnd.github+json')
if [[ -n ${GITHUB_TOKEN:-} ]]; then
  api_headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

tag=$(curl --fail --silent --show-error --location "${api_headers[@]}" \
  https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name')
[[ -n "$tag" && "$tag" != null ]]
case "$(uname -s)" in
  MINGW*|MSYS*)
    asset=Xray-windows-64.zip
    core_name=xray.exe
    # Native Windows Xray needs native paths inside the generated JSON.
    temporary_dir=$(cygpath -m "$temporary_dir")
    ;;
  Linux*) asset=Xray-linux-64.zip; core_name=xray ;;
  *) printf 'Unsupported test host: %s\n' "$(uname -s)" >&2; exit 1 ;;
esac
url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset}"
curl --fail --silent --show-error --location --retry 3 -o "$temporary_dir/xray.zip" "$url"
curl --fail --silent --show-error --location --retry 3 -o "$temporary_dir/xray.zip.dgst" "${url}.dgst"
expected=$(awk -F '= ' '/256=/ {gsub(/\r/, "", $2); print $2; exit}' "$temporary_dir/xray.zip.dgst")
actual=$(sha256sum "$temporary_dir/xray.zip" | awk '{print $1}')
[[ -n "$expected" && "${expected,,}" == "$actual" ]]
unzip -q "$temporary_dir/xray.zip" -d "$temporary_dir/core"

core_binary="$temporary_dir/core/$core_name"
printf '%s\n' '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}]}' > "$temporary_dir/empty.json"
XRAY_LOCATION_ASSET="$temporary_dir/core" "$core_binary" run -test -config "$temporary_dir/empty.json"
parse_reality_credentials "$("$core_binary" x25519)"
export PORT=443
export UUID
UUID=$("$core_binary" uuid)
export SERVER_NAME=example.com
export ADDRESS=node.test.example
export REMARK='test node & 中文'
export SHORT_ID=0123456789abcdef
MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=example.com' \
  -keyout "$temporary_dir/key.pem" -out "$temporary_dir/cert.pem" >/dev/null 2>&1
export TLS_CERT_PATH_OVERRIDE="$temporary_dir/cert.pem"
export TLS_KEY_PATH_OVERRIDE="$temporary_dir/key.pem"

for PROFILE in vless-reality-raw vless-reality-xhttp vless-reality-grpc vless-tls-raw vless-tls-xhttp vless-tls-ws vless-tls-grpc trojan-reality-raw vmess-tcp vmess-tls-ws vmess-tls-grpc trojan-tls-ws; do
  export PROFILE
  case "$PROFILE" in
    *xhttp*|*ws) export PATH_VALUE=/test-path ;;
    *grpc) export PATH_VALUE=grpc-test ;;
    *) export PATH_VALUE= ;;
  esac
  render_config "$temporary_dir/config.json"
  XRAY_LOCATION_ASSET="$temporary_dir/core" "$core_binary" run -test -config "$temporary_dir/config.json"
  cp "$temporary_dir/config.json" "$temporary_dir/$PROFILE.json"
  show_connection_loaded "$temporary_dir/config.json" > "$temporary_dir/$PROFILE.link"
  render_client_config > "$temporary_dir/$PROFILE.client.json"
  XRAY_LOCATION_ASSET="$temporary_dir/core" "$core_binary" run -test -config "$temporary_dir/$PROFILE.client.json"
done

# Keep one real-core check for multiple credentials on the same inbound.
export PROFILE=vless-reality-raw
export PORT=25443
export PATH_VALUE=
export UUID
UUID=$($core_binary uuid)
export EXTRA_UUIDS
EXTRA_UUIDS="$($core_binary uuid),$($core_binary uuid)"
render_config "$temporary_dir/multi-user.json"
jq -e '.inbounds[0].settings.clients | length == 3' "$temporary_dir/multi-user.json" >/dev/null
XRAY_LOCATION_ASSET="$temporary_dir/core" "$core_binary" run -test -config "$temporary_dir/multi-user.json"
export EXTRA_UUIDS=

roundtrip_args=()
if [[ ${CONFIGURATION_ONLY:-0} == 1 ]]; then roundtrip_args+=(--configuration-only); fi
"${PYTHON:-python3}" "$repo_dir/tests/link-roundtrip.py" "$temporary_dir" "$core_binary" "${roundtrip_args[@]}"

# Validate that independently generated inbounds can run together in one Xray process.
multi_files=()
index=0
for PROFILE in vless-reality-raw vless-reality-xhttp trojan-reality-raw; do
  export PROFILE
  export PORT=$((24443 + index))
  export UUID
  UUID=$("$core_binary" uuid)
  export SHORT_ID
  SHORT_ID=$(printf '%016x' "$((index + 1))")
  if [[ $PROFILE == vless-reality-xhttp ]]; then
    export PATH_VALUE=/multi-test
  else
    export PATH_VALUE=
  fi
  render_config "$temporary_dir/multi-$index.json"
  jq --arg tag "multi-$index" '.inbounds[0].tag=$tag' "$temporary_dir/multi-$index.json" > "$temporary_dir/tagged-$index.json"
  mv "$temporary_dir/tagged-$index.json" "$temporary_dir/multi-$index.json"
  multi_files+=("$temporary_dir/multi-$index.json")
  ((index+=1))
done
jq -s '{log:{loglevel:"warning"},inbounds:map(.inbounds[0]),outbounds:.[0].outbounds}' "${multi_files[@]}" > "$temporary_dir/multi.json"
XRAY_LOCATION_ASSET="$temporary_dir/core" "$core_binary" run -test -config "$temporary_dir/multi.json"

# WARP routing is shared by every inbound and must remain valid in selective and all-traffic modes.
cp "$temporary_dir/multi.json" "$temporary_dir/warp-selective.json"
inject_warp_config "$temporary_dir/warp-selective.json" selective 'geosite:netflix,domain:openai.com' UseIPv6
jq -e '.outbounds[] | select(.tag == "warp" and .protocol == "socks")' "$temporary_dir/warp-selective.json" >/dev/null
jq -e '.outbounds[] | select(.tag == "warp") | .targetStrategy == "UseIPv6"' "$temporary_dir/warp-selective.json" >/dev/null
jq -e '.routing.rules[] | select(.outboundTag == "warp") | .domain == ["geosite:netflix","domain:openai.com"]' "$temporary_dir/warp-selective.json" >/dev/null
XRAY_LOCATION_ASSET="$temporary_dir/core" "$core_binary" run -test -config "$temporary_dir/warp-selective.json"
cp "$temporary_dir/multi.json" "$temporary_dir/warp-all.json"
inject_warp_config "$temporary_dir/warp-all.json" all
jq -e '.routing.rules[] | select(.outboundTag == "warp") | .network == "tcp"' "$temporary_dir/warp-all.json" >/dev/null
XRAY_LOCATION_ASSET="$temporary_dir/core" "$core_binary" run -test -config "$temporary_dir/warp-all.json"

printf 'Xray %s accepted the empty state, all protocol profiles, combined inbounds, and shared WARP routing.\n' "$tag"

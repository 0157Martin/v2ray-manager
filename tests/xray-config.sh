#!/usr/bin/env bash
# Validates the generated server configuration against the latest stable Xray.
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../v2ray.sh
# shellcheck disable=SC1091
source "$repo_dir/v2ray.sh"

temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT
api_headers=(-H 'Accept: application/vnd.github+json')
if [[ -n ${GITHUB_TOKEN:-} ]]; then
  api_headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

tag=$(curl --fail --silent --show-error --location "${api_headers[@]}" \
  https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name')
[[ -n "$tag" && "$tag" != null ]]
url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-64.zip"
curl --fail --silent --show-error --location --retry 3 -o "$temporary_dir/xray.zip" "$url"
curl --fail --silent --show-error --location --retry 3 -o "$temporary_dir/xray.zip.dgst" "${url}.dgst"
expected=$(awk -F '= ' '/256=/ {print $2; exit}' "$temporary_dir/xray.zip.dgst")
actual=$(sha256sum "$temporary_dir/xray.zip" | awk '{print $1}')
[[ -n "$expected" && "${expected,,}" == "$actual" ]]
unzip -q "$temporary_dir/xray.zip" -d "$temporary_dir/core"

parse_reality_credentials "$("$temporary_dir/core/xray" x25519)"
export PORT=443
export UUID
UUID=$("$temporary_dir/core/xray" uuid)
export SERVER_NAME=www.microsoft.com
export SHORT_ID=0123456789abcdef
render_config "$temporary_dir/config.json"
XRAY_LOCATION_ASSET="$temporary_dir/core" "$temporary_dir/core/xray" run -test -config "$temporary_dir/config.json"

printf 'Xray %s accepted the generated VLESS REALITY configuration.\n' "$tag"

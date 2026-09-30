#!/usr/bin/env bash
# Minimal bootstrapper for v2ray-manager.
# Author: 0157Martin (https://github.com/0157Martin)
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

temporary=$(mktemp)
trap 'rm -f "$temporary"' EXIT

download() {
  if command -v curl >/dev/null 2>&1; then
    curl --fail --show-error --location --retry 3 --connect-timeout 15 --max-time 120 "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget --timeout=30 --tries=3 -qO- "$1"
  else
    printf '%s\n' '需要 curl 或 wget 才能下载安装脚本。' >&2
    return 1
  fi
}

# Resolve once, then fetch an immutable revision. No jq dependency at bootstrap.
revision=${V2M_MANAGER_REF:-}
if [[ -z $revision ]]; then
  download 'https://api.github.com/repos/0157Martin/v2ray-manager/commits/main' > "$temporary"
  revision=$(sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' "$temporary" | head -n 1)
fi
[[ $revision =~ ^[0-9a-f]{40}$ ]] || { printf '%s\n' '无法取得有效提交；可设置 V2M_MANAGER_REF 为完整提交 SHA 后重试。' >&2; exit 1; }
download "https://raw.githubusercontent.com/0157Martin/v2ray-manager/$revision/v2ray.sh" > "$temporary"
bash -n "$temporary"
grep -qx 'readonly APP_NAME="v2ray-manager"' "$temporary"
grep -Eq '^readonly MANAGER_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$temporary"

if [[ ${V2M_NONINTERACTIVE:-0} == 1 ]]; then
  V2M_NONINTERACTIVE=1 bash "$temporary" install
else
  bash "$temporary" install
fi

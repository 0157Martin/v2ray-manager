#!/usr/bin/env bash
# Minimal bootstrapper for v2ray-manager.
# Author: 0157Martin (https://github.com/0157Martin)
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

readonly MANAGER_URL="https://raw.githubusercontent.com/0157Martin/v2ray-manager/main/v2ray.sh"
temporary=$(mktemp)
trap 'rm -f "$temporary"' EXIT

if command -v curl >/dev/null 2>&1; then
  curl --fail --show-error --location --retry 3 --output "$temporary" "$MANAGER_URL"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$temporary" "$MANAGER_URL"
else
  printf '%s\n' '需要 curl 或 wget 才能下载安装脚本。' >&2
  exit 1
fi

bash "$temporary" bootstrap

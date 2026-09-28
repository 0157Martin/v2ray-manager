#!/usr/bin/env bash
# Minimal bootstrapper for v2ray-manager.
# Author: 0157Martin (https://github.com/0157Martin)
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

# Pin the downloaded manager to a verified revision so a stale main-branch CDN cache
# cannot pair a new installer with an older manager implementation.
readonly MANAGER_URL="https://raw.githubusercontent.com/0157Martin/v2ray-manager/47e82407787f2e2adf524ce0657a065cf90e049a/v2ray.sh"
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

V2M_NONINTERACTIVE=1 bash "$temporary" install

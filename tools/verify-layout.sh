#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
required=(install.sh v2ray.sh README.md LICENSE NOTICE config/defaults.sh templates/vmess-tcp.json.tmpl)

for path in "${required[@]}"; do
  [[ -f "$root_dir/$path" ]] || { printf 'missing: %s\n' "$path" >&2; exit 1; }
done

bash -n "$root_dir/install.sh" "$root_dir/v2ray.sh" "$root_dir/config/defaults.sh"
printf '%s\n' 'Repository layout and Bash syntax checks passed.'

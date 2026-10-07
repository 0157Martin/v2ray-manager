#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
required=(install.sh v2ray.sh README.md LICENSE config/defaults.sh templates/vless-reality.json.tmpl tests/unit.sh tests/xray-config.sh tools/build.sh src/00-runtime.sh)

for path in "${required[@]}"; do
  [[ -f "$root_dir/$path" ]] || { printf 'missing: %s\n' "$path" >&2; exit 1; }
done
bash "$root_dir/tools/build.sh" --check

for path in "$root_dir/install.sh" "$root_dir/v2ray.sh" "$root_dir/config/"*.sh \
  "$root_dir/tools/"*.sh "$root_dir/tests/"*.sh; do
  bash -n "$path"
done
# The literal variable reference is the contract being checked in source.
# shellcheck disable=SC2016
grep -Fq 'env V2M_NODES_DIR=' "$root_dir/v2ray.sh" || {
  printf '%s\n' 'Caddy branch environment must be passed through env.' >&2
  exit 1
}
if grep -Eq '^[[:space:]]+V2M_NODES_DIR=.*CADDY_CONFIG=' "$root_dir/v2ray.sh"; then
  printf '%s\n' 'Caddy branch call reassigns readonly variables in the current shell.' >&2
  exit 1
fi
printf '%s\n' 'Repository layout and Bash syntax checks passed.'

#!/usr/bin/env bash
# Build the deployable single-file manager from ordered source modules.
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
check=0
if [[ ${1:-} == --check ]]; then
  check=1
  output=$root_dir/v2ray.sh
else
  output=${1:-$root_dir/v2ray.sh}
fi
temporary=$(mktemp "${output}.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT

cat "$root_dir"/src/*.sh > "$temporary"
chmod 755 "$temporary"

if (( check )); then
  cmp "$temporary" "$root_dir/v2ray.sh" || {
    printf '%s\n' 'v2ray.sh is stale; run bash tools/build.sh.' >&2
    exit 1
  }
  exit 0
fi

mv -f -- "$temporary" "$output"
trap - EXIT

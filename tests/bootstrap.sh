#!/usr/bin/env bash
# Exercise the real bootstrapper without network or installation side effects.
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT
export sandbox
mkdir "$sandbox/bin"
cat > "$sandbox/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -eu
url=${!#}
printf '%s\n' "$url" >> "$sandbox/requests"
if [[ $url == */commits/main ]]; then
  printf '  "sha": "1111111111111111111111111111111111111111",\n'
elif [[ ${INVALID_SCRIPT:-0} == 1 ]]; then
  printf '<html>error</html>\n'
else
  cat <<'MANAGER'
#!/usr/bin/env bash
readonly APP_NAME="v2ray-manager"
readonly MANAGER_VERSION="4.2.0"
printf '%s %s\n' "${V2M_NONINTERACTIVE:-0}" "$1" > "$sandbox/executed"
MANAGER
fi
CURL
chmod +x "$sandbox/bin/curl"
export PATH="$sandbox/bin:$PATH"
unset V2M_MANAGER_REF
if bash "$repo_dir/install.sh" >/dev/null 2>&1; then
  printf 'Non-terminal bootstrap silently selected a default protocol.\n' >&2; exit 1
fi
[[ ! -e $sandbox/executed ]]
V2M_NONINTERACTIVE=1 bash "$repo_dir/install.sh"
[[ $(cat "$sandbox/executed") == '1 install' ]]
grep -q '/1111111111111111111111111111111111111111/v2ray.sh$' "$sandbox/requests"
rm "$sandbox/executed" "$sandbox/requests"
V2M_NONINTERACTIVE=1 V2M_MANAGER_REF=2222222222222222222222222222222222222222 bash "$repo_dir/install.sh"
[[ $(wc -l < "$sandbox/requests") == 1 ]]
grep -q '/2222222222222222222222222222222222222222/v2ray.sh$' "$sandbox/requests"
rm "$sandbox/executed"
if V2M_NONINTERACTIVE=1 INVALID_SCRIPT=1 bash "$repo_dir/install.sh" >/dev/null 2>&1; then
  printf 'Invalid downloaded script was accepted.\n' >&2; exit 1
fi
[[ ! -e $sandbox/executed ]]
if V2M_NONINTERACTIVE=1 V2M_MANAGER_REF=main bash "$repo_dir/install.sh" >/dev/null 2>&1; then
  printf 'Mutable revision was accepted.\n' >&2; exit 1
fi
printf 'Bootstrap tests passed.\n'

#!/usr/bin/env bash
# Push site configs to running routers with the standard `nixos-rebuild --target-host`.
#
#   ./deploy.sh                    switch every site in sites/
#   ./deploy.sh switch site-a      just one
#   ./deploy.sh test site-a site-b apply live, but a reboot returns to the previous generation
#   ./deploy.sh dry-activate       show what would restart, change nothing
#
# Each router builds its own system (--build-host = the router), so this Mac only evaluates.
# Site names are SSH host names: DNS or your ssh config in a real fleet, lab/ssh_config in the lab.
set -euo pipefail
cd "$(dirname "$0")"

action=${1:-switch}
[ $# -gt 0 ] && shift
if [ $# -gt 0 ]; then
  sites=("$@")
else
  sites=()
  for f in sites/*.nix; do s=${f##*/}; sites+=("${s%.nix}"); done
fi

# nixos-rebuild comes from this flake's dev shell (pinned nixpkgs) if it isn't on PATH.
if ! command -v nixos-rebuild >/dev/null; then
  exec nix --extra-experimental-features 'nix-command flakes' develop --command "$0" "$action" "${sites[@]}"
fi

export NIX_CONFIG="experimental-features = nix-command flakes"
# macOS caps Unix socket paths at 104 chars; nix develop's TMPDIR is too deep for SSH's ControlPath.
export TMPDIR=/tmp
[ -f lab/ssh_config ] && export NIX_SSHOPTS="-F $PWD/lab/ssh_config ${NIX_SSHOPTS:-}"

pids=()
for s in "${sites[@]}"; do
  (
    start=$SECONDS
    nixos-rebuild "$action" --flake ".#$s" --target-host "root@$s" --build-host "root@$s" 2>&1 | sed -u "s/^/[$s] /"
    echo "[$s] $action done in $((SECONDS - start))s"
  ) &
  pids+=($!)
done

fail=0
for i in "${!pids[@]}"; do
  wait "${pids[$i]}" || { echo "[${sites[$i]}] FAILED"; fail=1; }
done
exit $fail

#!/usr/bin/env bash
# Regenerates token-vault/ from a run of examples/token-vault on a fresh Anvil (PORT, default 8545).
# The records are forge's and the journals sprue's; never edit them by hand.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$root/map/test/token-vault
port=${PORT:-8545}
work=$(mktemp -d)
anvil=
trap '[ -n "$anvil" ] && kill "$anvil"; rm -rf "$work"' EXIT
cp -r "$root/examples/token-vault/." "$work"
mkdir -p "$work/lib/sprue"
ln -s "$root/bin" "$work/lib/sprue/bin"
ln -s "$root/src" "$work/lib/sprue/src"
ln -s "$root/lib/forge-std" "$work/lib/forge-std"
sed -i.bak "s#127.0.0.1:8545#127.0.0.1:$port#" "$work/foundry.toml"
git -C "$work" init -q
anvil --port "$port" --silent >/dev/null 2>&1 &
anvil=$!
until cast chain-id --rpc-url "http://127.0.0.1:$port" >/dev/null 2>&1; do sleep 0.2; done
(cd "$work" && DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 node lib/sprue/bin/sprue.mjs run local vault.check >/dev/null)
rm -rf "$out"
(cd "$work" && find broadcast -name '*.json' -not -path '*/dry-run/*' | while read -r f; do
  mkdir -p "$out/$(dirname "$f")"
  cp "$f" "$out/$f"
done)
mkdir -p "$out/deployments/local"
cp "$work"/deployments/local/{network,token,vault}.json "$out/deployments/local/"

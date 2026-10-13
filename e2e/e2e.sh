#!/usr/bin/env bash
# The executor (bin/graph.sh) against real Anvil nodes, on the toy project in ./toy.
# Needs anvil, forge, cast, jq; the attended scenario also python3 and setsid.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/..
PORT=${PORT:-9350}
FORGE_STD=${FORGE_STD:-$ROOT/lib/forge-std}
RPC=http://127.0.0.1:$PORT LIVE=http://127.0.0.1:$((PORT + 1)) GETH=http://127.0.0.1:$((PORT + 2))
KEYSTORE_PW=pw
PIDS=

die() { echo "FAIL $*" >&2; exit 1; }
# The toy project is copied here, so a run never touches the checkout.
W=$(mktemp -d)
cleanup() {
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  [ -n "${E2E_KEEP:-}" ] && echo "kept $W" >&2 || rm -rf "$W"
}
trap cleanup EXIT

node() { # node <port> <chain id>
  anvil --port "$1" --chain-id "$2" --silent >/dev/null 2>&1 & PIDS="$PIDS $!"
  for _ in $(seq 1 100); do cast chain-id --rpc-url "http://127.0.0.1:$1" >/dev/null 2>&1 && return; sleep 0.1; done
  die "no anvil at port $1"
}

setup() {
  cp -R "$HERE/toy/." "$W/"
  mkdir -p "$W/lib/sprue"
  cp -R "$ROOT/src" "$ROOT/bin" "$W/lib/sprue/"
  ln -s "$FORGE_STD" "$W/lib/forge-std"
  cp "$HERE/pty.py" "$W/../$(basename "$W").pty.py"
  PTY=$W/../$(basename "$W").pty.py
  cd "$W"
  # A command of its own, so that `setsid` and the pseudo-terminal can run it.
  mkdir -p bin; printf '#!/bin/sh\nexec sh %s/lib/sprue/bin/graph.sh "$@"\n' "$W" >bin/G; chmod +x bin/G
  export PATH=$W/bin:$PATH
  forge build -q >"$W/build.log" 2>&1 || { cat "$W/build.log" >&2; die "the toy project does not build"; }
  git init -q; git config user.email t@t; git config user.name t
  sh lib/sprue/bin/graph.sh json >script/deploy/graph.generated.json
  echo toy >README.md
  git add -A; git commit -qm toy
  node "$PORT" 31337; node $((PORT + 1)) 1; node $((PORT + 2)) 412346
  SNAP=$(cast rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')
  OPS=$(cast rpc eth_accounts --rpc-url "$RPC" | jq -r '.[0]')
  export R=$RPC DEPLOYER=$OPS
}

exits() { local rc=0; "${@:2}" >/dev/null 2>>"$W/log" || rc=$?; [ "$rc" = "$1" ] || die "${*:2} exited $rc, not $1"; }
# refused <text> <command...>: exits 2 and says <text>.
refused() {
  local want=$1 out rc=0; shift
  out=$("$@" 2>&1 </dev/null) || rc=$?
  [ "$rc" = 2 ] || die "$* exited $rc, not 2: $out"
  grep -q "$want" <<<"$out" || die "$* refused for another reason: $out"
}
tty() { PTY_ANSWER=$1 PTY_PASSWORD=$KEYSTORE_PW python3 -I "$PTY" "${@:2}"; }
nonce() { cast nonce "$OPS" --rpc-url "${1:-$RPC}"; }
now() { cast block latest -f timestamp --rpc-url "${1:-$RPC}"; }
all_done() { ! grep -Eqv '^# (done|chain) ' <<<"$2" || die "$1 left a node not done: $2"; }
# network <name> <chain id> [openAt]: a fresh network of one chain.
network() {
  rm -rf "deployments/$1"; mkdir -p "deployments/$1"
  echo "{\"chains\":{\"l2\":{\"id\":$2}}}" >"deployments/$1/network.json"
  echo "{\"openAt\":${3:-0}}" >"deployments/$1/vault.input.json"
}
fresh() { # fresh <rpc>: the seeded chain and no records
  if [ "$1" = "$RPC" ]; then
    [ "$(cast rpc evm_revert "$SNAP" --rpc-url "$RPC")" = true ] || die "evm_revert"
    SNAP=$(cast rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')
    cast rpc evm_setAutomine true --rpc-url "$RPC" >/dev/null
  fi
  rm -rf broadcast cache
}

# The refusals that precede any chain: each is exit 2 with its own text, and nothing is sent.
scenario_refuses() {
  local gs=$W/lib/sprue/bin/graph.sh d p
  d=$(mktemp -d)
  exits 0 G --help
  exits 2 G list extra
  (cd "$d" && refused "no sprue.json" sh "$gs" list)
  mkdir "$d/p"; echo '{"paths":{},"chains":{},"x":1}' >"$d/p/sprue.json"
  (cd "$d/p" && refused "exactly paths and chains" sh "$gs" list)
  p='"paths":{"graph":"g.s.sol","units":"u","deployments":"d","rehearsal":"d/fork"}'
  echo "{$p,\"chains\":[]}" >"$d/p/sprue.json"
  (cd "$d/p" && refused "exactly paths and chains" sh "$gs" list)
  echo "{${p/d\/fork/d\/Fork},\"chains\":{}}" >"$d/p/sprue.json"
  (cd "$d/p" && refused "paths.rehearsal is not" sh "$gs" list)
  # Only the prefix itself is ignored, not <prefix>-*.
  git init -q "$d/p"; echo "d/fork/" >"$d/p/.gitignore"
  echo "{$p,\"chains\":{}}" >"$d/p/sprue.json"
  (cd "$d/p" && refused "git does not ignore" sh "$gs" list)
  rm -rf "$d"

  network refuse 31337
  refused "not a plain name" env R="$RPC" G plan Bad_name vault.check
  refused "set R" env -u R G plan refuse vault.check
  local n=deployments/refuse/network.json
  echo '[]' >$n; refused "not a plain lower-case name" env R="$RPC" G run refuse vault.check
  echo '{"chains":{"L2":{"id":31337}}}' >$n; refused "not a plain lower-case name" env R="$RPC" G run refuse vault.check
  echo '{"chains":{"other":{"id":31337}}}' >$n; refused "has no chain l2" env R="$RPC" G run refuse vault.check
  echo '{"chains":{"l2":{"id":31337,"rpc":"a b"}}}' >$n; refused "rpc alias is not a plain name" env R="$RPC" G run refuse vault.check
  echo '{"chains":{"l2":{"id":1}}}' >$n; refused "is chain 31337, network.json says 1" env R="$RPC" G run refuse vault.check
  echo "ok  usage and configuration errors exit 2 before any chain is touched"
}

# A rerun of a finished target mines no block and changes no nonce or journal. The first run reaches
# the date, which lies in the future, by setting Anvil's clock itself.
scenario_rerun() {
  fresh "$RPC"; network rerun 31337 "$(($(now) + 1000))"
  local fp out
  fp() { echo "$(cast block-number --rpc-url "$RPC") $(nonce) $(cat deployments/rerun/*.json | shasum)"; }
  G run rerun vault.check >/dev/null 2>>log || die "rerun: the first run failed"
  [ "$(now)" -ge "$(jq .openAt deployments/rerun/vault.input.json)" ] || die "rerun: the date was not reached"
  before=$(fp); out=$(G run rerun vault.check 2>>log)
  [ "$(fp)" = "$before" ] || die "a finished rerun changed state"
  all_done rerun "$out"
  echo "ok  rerun a finished target changes no block, nonce or journal"
}

# Exit 4 before a date. With --wait, in any position, the run waits for it. Exit 2 for --wait on Anvil,
# an unknown target and an unknown network.
scenario_wait() {
  fresh "$GETH"; network wait 412346 "$(($(now "$GETH") + 3600))"
  mkdir -p stub
  # The node is Anvil, but the stub makes it report itself as Geth, so graph.sh cannot set its clock.
  printf '#!/bin/sh\nif [ "$1 $2" = "rpc web3_clientVersion" ]; then echo \\"Geth/stub\\"; exit; fi\nexec %s "$@"\n' "$(command -v cast)" >stub/cast
  chmod +x stub/cast
  export OLD_PATH=$PATH
  R=$GETH PATH="$PWD/stub:$PATH" exits 4 G run wait vault.check
  [ -n "$(jq -r '.vault // empty' deployments/wait/vault.json)" ] || die "wait: the work before the date was not done"
  local at; at=$(jq .openAt deployments/wait/vault.input.json)
  (sleep 3; cast rpc evm_setNextBlockTimestamp "$at" --rpc-url "$GETH" >/dev/null; cast rpc evm_mine --rpc-url "$GETH" >/dev/null) &
  local bumper=$!
  R=$GETH PATH="$PWD/stub:$PATH" exits 0 G run wait vault.check --wait
  wait "$bumper"
  [ -n "$(jq -r '.checked // empty' deployments/wait/vault.json)" ] || die "wait: --wait did not finish the target"
  network onanvil 31337 0
  exits 2 G run --wait onanvil vault.check
  exits 2 G plan onanvil no.such.target
  R=$RPC refused "unknown network 'nosuch'" G plan nosuch vault.check
  echo "ok  wait exit 4 before a date, --wait waits for it; Anvil, an unknown target or network exit 2"
}

# A kill while a CREATE is pending. The rerun refuses. Once the CREATE lands, a rerun resumes its
# intent. An intent whose nonce was spent by another transaction is replaced.
scenario_kill() {
  local d=deployments/kill hash intent n pending
  kill_pending() {
    fresh "$RPC"; network kill 31337
    cast rpc evm_setAutomine false --rpc-url "$RPC" >/dev/null
    set -m
    G run kill token.check >log.kill 2>&1 & KILLED=$!
    for _ in $(seq 1 600); do
      n=$(cast rpc txpool_status --rpc-url "$RPC" | jq -r '.pending'); [ "$n" = 0x0 ] || break; sleep 0.1
    done
    [ "$n" != 0x0 ] || die "kill: no transaction became pending"
    hash=$(cast rpc txpool_content --rpc-url "$RPC" | jq -r '[.pending[][].hash][0]')
    for _ in $(seq 1 100); do
      [ -f $d/token.json ] && grep -Rqi "${hash#0x}" cache/DeployToken.s.sol/31337/ 2>/dev/null && break; sleep 0.1
    done
    [ -f $d/token.json ] && grep -Rqi "${hash#0x}" cache/DeployToken.s.sol/31337/ || die "kill: intent and pending hash were not recorded before the kill"
    kill -9 -- "-$KILLED"; wait "$KILLED" 2>/dev/null || true
    set +m
    intent=$(jq -r .token $d/token.json)
  }
  kill_pending
  pending=$(cat $d/token.json)
  if out=$(G run kill token.check 2>&1); then die "kill: reran over a pending CREATE"; fi
  # A kill inside forge's send window can leave an uncommitted recovery snapshot, which refuses
  # instead. Each of these reruns refuses and leaves the journal unchanged.
  grep -Eq 'refusing to risk a duplicate transaction|transaction already imported|uncommitted recovery snapshot' <<<"$out" \
    || die "kill: refused for another reason: $out"
  [ "$(cat $d/token.json)" = "$pending" ] || die "kill: the refused rerun changed the journal"
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null; cast rpc evm_setAutomine true --rpc-url "$RPC" >/dev/null
  rm -f cache/DeployToken.s.sol/31337/*.recovery.pending
  G run kill token.check >/dev/null 2>>log
  [ "$(jq -r .token $d/token.json)" = "$intent" ] || die "kill: the rerun did not resume the landed intent"

  kill_pending
  cast rpc anvil_dropTransaction "$hash" --rpc-url "$RPC" >/dev/null
  # Forge's two snapshot files may both hold the hash, so delete each one that does. Then the sender
  # spends the nonce on another transaction.
  grep -ril "${hash#0x}" cache/DeployToken.s.sol/31337 | while IFS= read -r f; do rm -f "$f"; done
  cast rpc evm_setAutomine true --rpc-url "$RPC" >/dev/null
  cast send "$OPS" --value 0 --unlocked --from "$OPS" --rpc-url "$RPC" >/dev/null
  G run kill token.check >/dev/null 2>>log
  [ "$(jq -r .token $d/token.json)" != "$intent" ] || die "kill: kept a spent-nonce intent"
  [ "$(cast code "$(jq -r .token $d/token.json)" --rpc-url "$RPC")" != 0x ] || die "kill: the replacement has no code"
  echo "ok  kill a pending CREATE is refused, resumed once landed, and replaced once its nonce is spent"
}

# On a live chain (an Anvil of chain 1) a run is attended: each refusal sends nothing, and a change while the question waits stops it.
scenario_attended() {
  command -v python3 >/dev/null && command -v setsid >/dev/null || { echo "skip attended: it needs python3 and setsid"; return; }
  local net=fork-test-live out rc n0 account=e2e
  # The keystore lives in a home of its own; the compilers are shared.
  mkdir -p "$W/home/.foundry" "$W/home/.local/share"
  [ ! -e "$HOME/.svm" ] || ln -s "$HOME/.svm" "$W/home/.svm"
  [ ! -e "$HOME/.local/share/svm" ] || ln -s "$HOME/.local/share/svm" "$W/home/.local/share/svm"
  export HOME=$W/home
  cast wallet import "$account" --mnemonic 'test test test test test test test test test test test junk' \
    --unsafe-password "$KEYSTORE_PW" >/dev/null
  network "$net" 1; network livenet 1
  git add -A; git commit -qm networks
  unset CI
  local run=(G run "$net" token.check --account "$account")
  export R=$LIVE
  refused 'no terminal' setsid -w "${run[@]}"
  CI=1 refused 'CI is set' tty no "${run[@]}"
  refused 'development node' tty no G run livenet token.check --account "$account"
  refused 'exactly one of' tty no G run "$net" token.check
  echo dirt >>README.md
  refused 'not clean' tty no "${run[@]}"
  git checkout -q README.md
  # Nothing above sent.
  n0=$(nonce "$LIVE")
  [ "$n0" = 0 ] || die "attended: a refusal sent"

  # A change while the question waits: an edit, or a record no step of the run wrote.
  PTY_HOOK="echo edited >>README.md" refused 'working tree changed' tty yes "${run[@]}"
  git checkout -q README.md
  PTY_HOOK="mkdir -p broadcast/Other.s.sol/1 && echo '{}' >broadcast/Other.s.sol/1/run-latest.json" \
    refused 'working tree changed' tty yes "${run[@]}"
  rm -rf broadcast/Other.s.sol
  [ "$(nonce "$LIVE")" = "$n0" ] || die "attended: a changed tree still sent"

  rc=0; out=$(tty no "${run[@]}" 2>&1) || rc=$?
  [ "$rc" = 6 ] || die "attended: an answer of no exited $rc, not 6"
  grep -aq 'CREATE Token' <<<"$out" || die "attended: the preview does not show the CREATE"
  [ "$(nonce "$LIVE")" = "$n0" ] || die "attended: an answer of no sent"
  # Every step is asked, the check too.
  out=$(tty yes "${run[@]}" 2>&1) || die "attended: yes failed: ${out: -600}"
  [ "$(grep -ac 'Type yes: ' <<<"$out")" = 2 ] || die "attended: the deployment and the check were not both asked"
  [ "$(nonce "$LIVE")" = $((n0 + 1)) ] || die "attended: the run did not send once"
  # A rehearsal network's journals leave the tree clean only while git ignores them, which graph.sh checks.
  exits 0 tty no "${run[@]}"
  sed -i.bak '/fork-test/d' .gitignore && rm .gitignore.bak
  git commit -qam unignore
  refused 'git does not ignore' tty no "${run[@]}"
  echo "ok  attended refusals send nothing, a change during the question stops the send, no sends nothing, yes sends once and asks every step, the rehearsal directories need the ignore line"
}

setup
cd "$W"
scenario_refuses
scenario_rerun
scenario_wait
scenario_kill
scenario_attended
echo "PASS e2e"

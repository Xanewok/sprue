#!/usr/bin/env bash
# The runner (bin/sprue.mjs) against real Anvil nodes, on the projects in examples/.
# Needs anvil, forge, cast, node, jq; the attended scenario also python3 and setsid.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/../..
PORT=${PORT:-9350}
FORGE_STD=${FORGE_STD:-$ROOT/lib/forge-std}
RPC=http://127.0.0.1:$PORT LIVE=http://127.0.0.1:$((PORT + 1)) GETH=http://127.0.0.1:$((PORT + 2))
KEYSTORE_PW=pw
PIDS=

die() { echo "FAIL $*" >&2; exit 1; }
# The example project is copied here and runs there. Only `forge test` in scenario_grammar
# runs in the checkout, as it does in CI: it writes out/, cache/ and its own deployments/fork-test-*.
W=$(mktemp -d)
cleanup() {
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  [ -n "${E2E_KEEP:-}" ] && echo "kept $W" >&2 || rm -rf "$W" "$W.bin" "$W.geth"
}
trap cleanup EXIT

start_anvil() { # start_anvil <port> <chain id>
  anvil --port "$1" --chain-id "$2" --silent >/dev/null 2>&1 & PIDS="$PIDS $!"
  for _ in $(seq 1 100); do cast chain-id --rpc-url "http://127.0.0.1:$1" >/dev/null 2>&1 && return; sleep 0.1; done
  die "no anvil at port $1"
}

setup() {
  cp -R "$ROOT/examples/token-vault/." "$W/"
  mkdir -p "$W/lib/sprue"
  cp -R "$ROOT/src" "$ROOT/bin" "$W/lib/sprue/"
  ln -s "$FORGE_STD" "$W/lib/forge-std"
  cp "$HERE/pty.py" "$W/../$(basename "$W").pty.py"
  PTY=$W/../$(basename "$W").pty.py
  cd "$W"
  # A command of its own, so that `setsid` and the pseudo-terminal can run it.
  # The attended scenario changes HOME, which a version manager's node shim cannot survive: name the binary.
  mkdir -p bin; printf '#!/bin/sh\nexec %s %s/lib/sprue/bin/sprue.mjs "$@"\n' "$(node -p process.execPath)" "$W" >bin/G; chmod +x bin/G
  export PATH=$W/bin:$PATH
  forge build -q >"$W/build.log" 2>&1 || { cat "$W/build.log" >&2; die "the example does not build"; }
  # Offline after the build that may download solc: online, each forge command looks up the network.
  export FOUNDRY_OFFLINE=true
  git init -q; git config user.email t@t; git config user.name t
  node lib/sprue/bin/sprue.mjs json | diff - script/deploy/graph.generated.json || die "graph.generated.json is stale"
  # The attended scenario sends to an Anvil posing as chain 1; those records are not evidence.
  echo 'broadcast/Deploy*/1/' >>.gitignore
  git add -A; git commit -qm example
  start_anvil "$PORT" 31337; start_anvil $((PORT + 1)) 1; start_anvil $((PORT + 2)) 412346
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
  local gs=$W/lib/sprue/bin/sprue.mjs d p
  d=$(mktemp -d)
  exits 0 G --help
  exits 2 G list extra
  (cd "$d" && refused "no sprue.json" node "$gs" list)
  (cd "$d" && exits 0 node "$gs" --help)
  mkdir -p "$d/pkg/bin"; cp "$ROOT/bin/sprue.mjs" "$d/pkg/bin/"; echo '{"version":"9.9.9","type":"module"}' >"$d/pkg/package.json"
  [ "$(node "$d/pkg/bin/sprue.mjs" --version)" = 9.9.9 ] || die "sprue --version is not package.json's"
  mkdir "$d/p"; echo '{"paths":{},"chains":{},"x":1}' >"$d/p/sprue.json"
  (cd "$d/p" && refused "exactly paths and chains" node "$gs" list)
  p='"paths":{"graph":"g.s.sol","units":"u","deployments":"d","rehearsal":"d/fork"}'
  echo "{$p,\"chains\":[]}" >"$d/p/sprue.json"
  (cd "$d/p" && refused "exactly paths and chains" node "$gs" list)
  echo "{${p/d\/fork/d\/Fork},\"chains\":{}}" >"$d/p/sprue.json"
  (cd "$d/p" && refused "paths.rehearsal is not" node "$gs" list)
  # Only the prefix itself is ignored, not <prefix>-*.
  git init -q "$d/p"; echo "d/fork/" >"$d/p/.gitignore"
  echo "{$p,\"chains\":{}}" >"$d/p/sprue.json"
  (cd "$d/p" && refused "git does not ignore" node "$gs" list)
  rm -rf "$d"

  network refuse 31337
  refused "not a plain name" env R="$RPC" G plan Bad_name vault.check
  refused "set R" env -u R G plan refuse vault.check
  local n=deployments/refuse/network.json
  echo '[]' >$n; refused "not a plain lower-case name" env R="$RPC" G run refuse vault.check
  echo '{"chains":{"L2":{"id":31337}}}' >$n; refused "not a plain lower-case name" env R="$RPC" G run refuse vault.check
  echo '{"chains":{"other":{"id":31337}}}' >$n; refused "has no chain l2" env R="$RPC" G run refuse vault.check
  echo '{"chains":{"l2":{"id":31337,"rpc":"a b"}}}' >$n; refused "rpc alias is not a plain name" env R="$RPC" G run refuse vault.check
  echo '{"chains":{"l2":{"id":31337,"rpc":"my.node"}}}' >$n; refused "rpc alias is not a plain name" env R="$RPC" G run refuse vault.check
  echo '{"chains":{"l2":{"id":31337,"rpc":"123"}}}' >$n; refused "rpc alias is not a plain name" env R="$RPC" G run refuse vault.check
  echo '{"chains":{"l2":{"id":31337,"rpc":"Node"}}}' >$n; refused "rpc alias is not a plain name" env R="$RPC" G run refuse vault.check
  echo '{"chains":{"l2":{"id":1}}}' >$n; refused "is chain 31337, network.json says 1" env R="$RPC" G run refuse vault.check
  echo "ok  usage and configuration errors exit 2 before any chain is touched"
}

# A <dir>/cast (default ./stub) that makes every Anvil report itself as Geth, so the runner cannot set
# its clock.
geth_stub() {
  local d=${1:-stub}
  mkdir -p "$d"
  printf '#!/bin/sh\nif [ "$1 $2" = "rpc web3_clientVersion" ]; then echo \\"Geth/stub\\"; exit; fi\nexec %s "$@"\n' "$(command -v cast)" >"$d/cast"
  chmod +x "$d/cast"
}

# A failed step ends with forge's last Error: line, after the output that buries it.
scenario_failure() {
  fresh "$RPC"; network pinned 31337
  echo '{"chains":{"l2":{"id":31337}},"deployer":"0x000000000000000000000000000000000000dEaD"}' >deployments/pinned/network.json
  local out rc=0
  out=$(G run pinned token.check 2>&1) || rc=$?
  [ "$rc" = 1 ] || die "failure: exited $rc, not 1: ${out: -400}"
  [ "$(tail -n 1 <<<"$out")" = "$(tail -n 2 <<<"$out" | head -n 1)" ] && [[ $(tail -n 1 <<<"$out") == Error:* ]] \
    || die "failure: forge's Error: line is not repeated at the end: $(tail -n 2 <<<"$out" | cut -c1-80)"
  # A send whose records forge would write where no unit reads them is refused, before it sends, by
  # what forge resolves: the inherited environment or foundry.toml.
  network elsewhere 31337; local n0; n0=$(nonce)
  refused 'forge config puts this line.s records in elsewhere' env FOUNDRY_BROADCAST=elsewhere G run elsewhere token.check
  mv foundry.toml foundry.toml.ok; { echo '[profile.default]'; echo 'broadcast = "elsewhere"'; tail -n +2 foundry.toml.ok; } >foundry.toml
  refused 'forge config puts this line.s records in elsewhere' G run elsewhere token.check
  mv foundry.toml.ok foundry.toml
  [ "$(nonce)" = "$n0" ] || die "failure: a send with records elsewhere sent"
  echo "ok  a failed step ends with forge's Error: line; a send whose records would go elsewhere is refused"
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

# The example's own network, as its README runs it: a lost journal is refused with a `recover` command,
# and after that command a rerun reaches done.
scenario_recover() {
  fresh "$RPC"; git clean -fdXq deployments/local
  local out cmd
  G run local vault.check >/dev/null 2>>log || die "recover: the first run failed"
  rm deployments/local/token.json
  if out=$(G run local vault.check 2>&1); then die "recover: a run went on without its journal"; fi
  cmd=$(grep -o "forge script [^ ]* --sig 'recover(string)' .*" <<<"$out" | head -1)
  [ -n "$cmd" ] || die "recover: the refusal names no recover command: $out"
  eval "$cmd" >/dev/null 2>>log || die "recover: $cmd failed"
  G run local vault.check >/dev/null 2>>log || die "recover: the rerun failed"
  all_done recover "$(G plan local vault.check 2>>log)"
  [ -n "$(jq -r '.token // empty' deployments/local/token.json)" ] || die "recover: the journal lacks the token"
  echo "ok  a lost journal is refused with its recover command, which rebuilds it, and the rerun is done"
}

# Exit 4 before a date. With --wait, in any position, the run waits for it. Exit 2 for --wait on Anvil,
# an unknown target and an unknown network.
scenario_wait() {
  fresh "$GETH"; network wait 412346 "$(($(now "$GETH") + 3600))"
  geth_stub
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

# examples/two-chain on two Anvils. A date of a step on the second chain is that chain's: the runner sets the
# second node's clock, one window at a time, and leaves the first node's alone.
scenario_two_chain() {
  local d=$W/two-chain rcv=http://127.0.0.1:$((PORT + 3)) at out zero=0x0000000000000000000000000000000000000000
  cp -R "$ROOT/examples/two-chain" "$d"; ln -s "$W/lib" "$d/lib"
  cd "$d"
  start_anvil $((PORT + 3)) 31338
  forge build -q >"$W/build.log" 2>&1 || { cat "$W/build.log" >&2; die "the two-chain example does not build"; }
  node "$W/lib/sprue/bin/sprue.mjs" json | diff - script/deploy/graph.generated.json || die "two-chain: graph.generated.json is stale"
  fresh "$RPC"
  export SOURCE_RPC=$RPC RECEIVER_RPC=$rcv
  # The receiver is the first contract of account 0 on its fresh chain: the address the input file names.
  at=$(jq .openAt deployments/local/receiver.input.json)
  forge create script/deploy/units/receiver/Receiver.sol:Receiver --rpc-url "$rcv" --unlocked --from "$OPS" --broadcast >/dev/null 2>>log
  opened() { cast call "$(jq -r .receiver deployments/local/receiver.input.json)" 'opened(uint8)(address)' "$1" --rpc-url "$rcv"; }
  [ "$(cast code "$(jq -r .receiver deployments/local/receiver.input.json)" --rpc-url "$rcv")" != 0x ] || die "two-chain: no receiver at the input's address"

  exits 0 G run local receiver.notify.2
  for w in 0 1 2; do
    [ "$(opened $w)" = "$(jq -r .checked.source deployments/local/source.json)" ] || die "two-chain: window $w is not open"
  done
  [ "$(now "$rcv")" -ge "$((at + 2 * 86400))" ] || die "two-chain: the receiver's clock did not reach the last window"
  [ "$(now)" -lt "$at" ] || die "two-chain: the source's clock was moved"
  all_done two-chain "$(G plan local receiver.notify.2 2>>log)"
  # A step that selects its own forks never reads its journal through _use, and is refused all the same.
  cp -R deployments/local deployments/fork-test-two
  out=$(forge script script/deploy/units/receiver/DeployReceiver.s.sol:DeployReceiver --sig 'notify(string,uint8)' \
    fork-test-two 0 --sender "$OPS" 2>&1) && die "two-chain: a rehearsal dry run ran without its prefix"
  grep -q 'forge would keep this run.s records in broadcast, not' <<<"$out" || die "two-chain: a dry run without the prefix: ${out: -400}"
  cd "$W"; rm -rf "$d"
  echo "ok  two-chain: the runner sets the receiver chain's clock for each window's date, and not the source's"
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
  # A rehearsal records only in a git-ignored directory, so it never sends to a real node.
  geth_stub "$W.geth"
  PATH=$W.geth:$PATH refused 'is not a development node' tty no "${run[@]}"
  # A node that does not name its client could be a development node, so it is refused too.
  mkdir -p "$W.bin"; printf '#!/bin/sh\n[ "$1 $2" != "rpc web3_clientVersion" ] || exit 1\nexec %s "$@"\n' "$(command -v cast)" >"$W.bin/cast"
  chmod +x "$W.bin/cast"
  PATH=$W.bin:$PATH refused 'cannot read the node' tty no G run livenet token.check --account "$account"
  refused 'exactly one of' tty no G run "$net" token.check
  echo dirt >>README.md
  refused 'not clean' tty no "${run[@]}"
  refused 'has a live chain' tty no G run --allow-dirty "$net" token.check --account "$account"
  git checkout -q README.md
  DEPLOYER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 refused 'not the signer' tty no "${run[@]}"
  # Nothing above sent.
  n0=$(nonce "$LIVE")
  [ "$n0" = 0 ] || die "attended: a refusal sent"

  # A change while the question waits: an edit, or a record no step of the run wrote.
  PTY_HOOK="echo edited >>README.md" refused 'working tree changed' tty yes "${run[@]}"
  git checkout -q README.md
  PTY_HOOK="mkdir -p broadcast/Other.s.sol/1 && echo '{}' >broadcast/Other.s.sol/1/run-latest.json" \
    refused 'working tree changed' tty yes "${run[@]}"
  rm -rf broadcast/Other.s.sol
  PTY_HOOK="git commit -q --allow-empty -m moved" refused 'HEAD moved' tty yes "${run[@]}"
  [ "$(nonce "$LIVE")" = "$n0" ] || die "attended: a changed tree still sent"
  PTY_HOOK="cast send --unlocked --from $OPS $OPS --rpc-url $LIVE >/dev/null" refused 'nonce moved' tty yes "${run[@]}"
  n0=$((n0 + 1))
  # A transaction of the sender still in the pool: sending now could replace it or collide with its nonce.
  cast rpc evm_setAutomine false --rpc-url "$LIVE" >/dev/null
  cast send --async --unlocked --from "$OPS" "$OPS" --rpc-url "$LIVE" >/dev/null
  refused 'pending transaction' tty no "${run[@]}"
  cast rpc evm_setAutomine true --rpc-url "$LIVE" >/dev/null; cast rpc evm_mine --rpc-url "$LIVE" >/dev/null
  n0=$((n0 + 1))

  rc=0; out=$(tty no "${run[@]}" 2>&1) || rc=$?
  [ "$rc" = 6 ] || die "attended: an answer of no exited $rc, not 6"
  grep -aq 'CREATE Token' <<<"$out" || die "attended: the preview does not show the CREATE"
  [ "$(nonce "$LIVE")" = "$n0" ] || die "attended: an answer of no sent"
  # Every step is asked, the check too.
  out=$(tty yes "${run[@]}" 2>&1) || die "attended: yes failed: ${out: -600}"
  [ "$(grep -ac 'Type yes: ' <<<"$out")" = 2 ] || die "attended: the deployment and the check were not both asked"
  [ "$(nonce "$LIVE")" = $((n0 + 1)) ] || die "attended: the run did not send once"
  # The fork keeps chain id 1, so records in broadcast/ would read as that chain's.
  # Nor in cache/, whose snapshot a live --resume would publish as the real chain's records.
  [ -z "$(ls broadcast/*/1 cache/*/1 2>/dev/null)" ] || die "attended: a rehearsal wrote records or resume data under broadcast/ or cache/"
  ls "deployments/$net/broadcast/DeployToken.s.sol/1/"*-latest.json >/dev/null || die "attended: no record under the rehearsal network"
  ls "deployments/$net/cache/DeployToken.s.sol/1/"*-latest.json >/dev/null || die "attended: no resume data under the rehearsal network"
  grep -q '"tokenTx"' "deployments/$net/token.json" || die "attended: the journal has no receipt from the rehearsal's record"
  # Forge run directly: a send or a dry run, which --resume can send too, without the prefix or half of it.
  local check=(forge script script/deploy/units/token/DeployToken.s.sol --sig 'check(string)' "$net" --rpc-url "$LIVE" --sender "$OPS")
  out=$("${check[@]}" --unlocked --broadcast 2>&1) && die "attended: a rehearsal sent without its prefix"
  grep -q 'forge would keep this run.s records in broadcast, not' <<<"$out" || die "attended: a send without the prefix: ${out: -400}"
  out=$("${check[@]}" 2>&1) && die "attended: a rehearsal dry run ran without its prefix"
  grep -q 'forge would keep this run.s records in broadcast, not' <<<"$out" || die "attended: a dry run without the prefix: ${out: -400}"
  out=$(FOUNDRY_BROADCAST=deployments/$net/broadcast "${check[@]}" 2>&1) && die "attended: a rehearsal ran with resume data in cache/"
  grep -q 'forge would keep this run.s resume data in cache, not' <<<"$out" || die "attended: resume data in cache/: ${out: -400}"
  # The plan, run without the prefix, still probes a step's done view, which reads the journal the same way.
  out=$(G plan "$net" vault.check 2>&1) || die "attended: the plan of the next unit failed: ${out: -400}"
  ! grep -q '^# cannot reach' <<<"$out" || die "attended: the plan could not probe a step: $out"
  grep -q "forge script script/deploy/units/vault" <<<"$out" || die "attended: the plan has no vault step: $out"
  # The graph's rehearse sends every step from inside one dry run, which --resume can send too.
  local staged=deployments/fork-test-rehearse-$net
  local rehearse=(forge script script/deploy/DeployGraph.s.sol --sig 'rehearse(string,string)' "$net" vault.check --rpc-url "$LIVE" --sender "$OPS")
  out=$("${rehearse[@]}" 2>&1) && die "attended: the graph rehearsed without its prefix"
  grep -q 'forge would keep this run.s records in broadcast, not' <<<"$out" || die "attended: a rehearse without the prefix: ${out: -400}"
  out=$(FOUNDRY_BROADCAST=$staged/broadcast FOUNDRY_CACHE_PATH=$staged/cache "${rehearse[@]}" 2>&1) || die "attended: a rehearse with its prefix failed: ${out: -400}"
  grep -q 'reached vault.check' <<<"$out" || die "attended: the rehearse did not reach its target: ${out: -400}"
  ls "$staged/broadcast/DeployGraph.s.sol/1/dry-run/"*-latest.json >/dev/null || die "attended: the rehearse saved no dry run under its network"
  [ -z "$(ls -d broadcast/DeployGraph.s.sol cache/DeployGraph.s.sol 2>/dev/null)" ] || die "attended: a rehearse kept records or resume data outside its network"
  # A rehearsal network's journals leave the tree clean only while git ignores them, which the runner checks.
  exits 0 tty no "${run[@]}"
  sed -i.bak '/fork-test/d' .gitignore && rm .gitignore.bak
  git commit -qam unignore
  refused 'git does not ignore' tty no "${run[@]}"
  echo "ok  attended refusals send nothing, a change during the question stops the send, no sends nothing, yes sends once and asks every step, the rehearsal directories need the ignore line"
}

# `run` sends the command lines that the FileGraph tests and the example's plan print, and nothing hostile.
scenario_grammar() {
  { (cd "$ROOT" && forge test --match-path 'test/FileGraph*' -vv 2>&1) | sed -n 's/^ *PLAN //p'
    G plan local vault.check; } | grep -E '^([A-Z][A-Z0-9_]*=|forge script )' | sort -u >"$W/corpus"
  [ "$(wc -l <"$W/corpus")" -ge 6 ] || die "grammar: too few command lines in $W/corpus"
  bash "$HERE/plan-grammar.sh" "$W/corpus" 2>>"$W/log" || die "grammar: see $W/log"
  echo "ok  run sends every command line the tests and the example print, and no hostile mutation"
}

# The chart is for mermaid, which this script cannot run: check its shape against the export.
scenario_mermaid() {
  local m; m=$(G mermaid)
  [ "$(head -1 <<<"$m")" = "flowchart TD" ] || die "mermaid: the first line is not 'flowchart TD'"
  [ "$(grep -c '^subgraph ' <<<"$m")" = "$(jq '[.nodes[].unit] | unique | length' script/deploy/graph.generated.json)" ] \
    || die "mermaid: not one subgraph per unit"
  echo "ok  mermaid starts with flowchart TD and has one subgraph per unit"
}

setup
cd "$W"
scenario_mermaid
scenario_refuses
scenario_grammar
scenario_failure
scenario_rerun
scenario_recover
scenario_wait
scenario_kill
scenario_two_chain
scenario_attended
echo "PASS e2e"

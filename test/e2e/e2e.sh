#!/usr/bin/env bash
# The runner (bin/sprue.mjs) against real Anvil nodes, on the projects in examples/.
# Needs anvil, forge, cast, node, jq; the attended scenario also python3.
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
# runs in the checkout, as it does in CI: it writes out/, cache/ and its own deployments/rehearsal-*.
W=$(mktemp -d)
cleanup() {
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  # A failed check can leave a --keep fork running.
  for n in main mute wide rl; do (cd "$W" && node lib/sprue/bin/sprue.mjs rehearse --stop $n) >/dev/null 2>&1 || true; done
  [ -n "${E2E_KEEP:-}" ] && echo "kept $W" >&2 || rm -rf "$W" "$W".node-*.log "$W.bin" "$W.remote" "$W.pty.py" "$W.home" "$W.link"
}
trap cleanup EXIT

start_anvil() { # start_anvil <port> <chain id>
  anvil --port "$1" --chain-id "$2" --silent >/dev/null 2>&1 & PIDS="$PIDS $!"
  for _ in $(seq 1 100); do cast chain-id --rpc-url "http://127.0.0.1:$1" >/dev/null 2>&1 && return; sleep 0.1; done
  die "no anvil at port $1"
}
# live_node <port> <chain id>: an Anvil behind a proxy at <port> that answers web3_clientVersion as Geth,
# and with $LAG reports a head that many blocks behind.
# The units ask the node in process, so a cast stub would not pass for a live node.
live_node() {
  local log=$W.node-$1.log upstream=""
  anvil --port 0 --chain-id "$2" >"$log" 2>&1 & PIDS="$PIDS $!"
  for _ in $(seq 1 100); do upstream=$(sed -n 's/^Listening on \(.*\)$/http:\/\/\1/p' "$log"); [ -n "$upstream" ] && break; sleep 0.1; done
  [ -n "$upstream" ] || die "no anvil for port $1"
  python3 "$HERE/geth.py" "$1" "$upstream" & PIDS="$PIDS $!"
  for _ in $(seq 1 100); do [ "$(cast rpc web3_clientVersion --rpc-url "http://127.0.0.1:$1" 2>/dev/null)" = '"Geth/stub"' ] && return; sleep 0.1; done
  die "no live node at port $1"
}

# Each test port's foundry.toml alias, which a network names by its chain id.
ENDPOINTS="local = \"$RPC\"
live = \"$LIVE\"
geth = \"$GETH\"
receiver = \"http://127.0.0.1:$((PORT + 3))\"
wide = \"http://127.0.0.1:$((PORT + 4))\"
prod = \"http://127.0.0.1:$((PORT + 5))\"
stage = \"http://127.0.0.1:$((PORT + 6))\"
old = \"http://127.0.0.1:$((PORT + 8))\""
alias_of() {
  case $1 in 31337) echo local ;; 1) echo live ;; 412346) echo geth ;; 4663) echo wide ;; 10) echo prod ;; 11155111) echo stage ;; 1337) echo old ;; *) die "no alias for chain $1" ;; esac
}
endpoints() { # endpoints <foundry.toml>: its [rpc_endpoints] become the test ports'
  sed -i.bak '/^\[rpc_endpoints\]/,$d' "$1" && rm -f "$1.bak" && printf '[rpc_endpoints]\n%s\n' "$ENDPOINTS" >>"$1"
}

setup() {
  cp -R "$ROOT/examples/token-vault/." "$W/"
  mkdir -p "$W/lib/sprue"
  cp -R "$ROOT/src" "$ROOT/bin" "$W/lib/sprue/"
  ln -s "$FORGE_STD" "$W/lib/forge-std"
  cp "$HERE/pty.py" "$W/../$(basename "$W").pty.py"
  PTY=$W/../$(basename "$W").pty.py
  cd "$W"
  endpoints foundry.toml
  # The forks that rehearse starts cache what they read under ~/.foundry, so the runner gets a home of
  # its own, outside the repository, that shares only the compilers.
  mkdir -p "$W.home/.foundry" "$W.home/.local/share"
  # A command of its own, so that the pseudo-terminal can run it.
  # A version manager's node shim cannot survive another HOME: name the binary.
  mkdir -p bin; printf '#!/bin/sh\nHOME=%s; export HOME\nexec %s %s/lib/sprue/bin/sprue.mjs "$@"\n' "$W.home" "$(node -p process.execPath)" "$W" >bin/G; chmod +x bin/G
  export PATH=$W/bin:$PATH
  forge build -q >"$W/build.log" 2>&1 || { cat "$W/build.log" >&2; die "the example does not build"; }
  # Linked after the build, which may be the one that downloads solc.
  [ ! -e "$HOME/.svm" ] || ln -s "$HOME/.svm" "$W.home/.svm"
  [ ! -e "$HOME/.local/share/svm" ] || ln -s "$HOME/.local/share/svm" "$W.home/.local/share/svm"
  [ ! -e "$HOME/Library/Application Support/svm" ] || { mkdir -p "$W.home/Library/Application Support"
    ln -s "$HOME/Library/Application Support/svm" "$W.home/Library/Application Support/svm"; }
  # The attended and tag scenarios sign with this keystore, in the runner's home.
  HOME=$W.home cast wallet import e2e --mnemonic 'test test test test test test test test test test test junk' \
    --unsafe-password "$KEYSTORE_PW" >/dev/null
  # Offline after the build that may download solc: online, each forge command looks up the network.
  export FOUNDRY_OFFLINE=true
  git init -q; git config user.email t@t; git config user.name t
  node lib/sprue/bin/sprue.mjs json | diff - script/deploy/graph.generated.json || die "graph.generated.json is stale"
  # The attended scenario sends to an Anvil posing as chain 1; those records are not evidence.
  echo 'broadcast/Deploy*/1/' >>.gitignore
  # The scenarios' stderr, which must not make an attended run's tree dirty whichever scenarios run.
  echo /log >>.gitignore
  git add -A; git commit -qm example
  start_anvil "$PORT" 31337; start_anvil $((PORT + 1)) 1; start_anvil $((PORT + 2)) 412346
  SNAP=$(cast rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')
  OPS=$(cast rpc eth_accounts --rpc-url "$RPC" | jq -r '.[0]')
  export DEPLOYER=$OPS
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
# detached <command...>: the command in a session of its own, so without a controlling terminal.
detached() { python3 -c 'import os, sys
pid = os.fork()
if pid == 0:
    os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))' "$@"; }
nonce() { cast nonce "$OPS" --rpc-url "${1:-$RPC}"; }
now() { cast block latest -f timestamp --rpc-url "${1:-$RPC}"; }
all_done() { ! grep -Eqv '^(# (done|chain) |deployer )' <<<"$2" || die "$1 left a node not done: $2"; }
# network <name> <chain id> [openAt]: a fresh network of one chain.
network() {
  rm -rf "deployments/$1"; mkdir -p "deployments/$1"
  echo "{\"chains\":{\"l2\":{\"id\":$2,\"rpc\":\"$(alias_of "$2")\"}}}" >"deployments/$1/network.json"
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
  echo "{${p/d\/fork/d\/con},\"chains\":{}}" >"$d/p/sprue.json"
  (cd "$d/p" && refused "a name Windows reserves" node "$gs" list)
  # Only the prefix itself is ignored, not <prefix>-*.
  git init -q "$d/p"; echo "d/fork/" >"$d/p/.gitignore"
  echo "{$p,\"chains\":{}}" >"$d/p/sprue.json"
  (cd "$d/p" && refused "git does not ignore" node "$gs" list)
  rm -rf "$d"

  network refuse 31337
  refused "not a plain name" G plan Bad_name vault.check
  refused "Windows reserves the name" G plan com1 vault.check
  local n=deployments/refuse/network.json
  echo '[]' >$n; refused "not a plain lower-case name" G run refuse vault.check
  echo '{"chains":{"L2":{"id":31337}}}' >$n; refused "not a plain lower-case name" G run refuse vault.check
  echo '{"chains":{}}' >$n; refused "network.json names no chain" G run refuse vault.check
  echo '{"chains":{"other":{"id":31337,"rpc":"local"}}}' >$n; refused "has no chain l2" G run refuse vault.check
  echo '{"chains":{"l2":{"id":31337}}}' >$n; refused "chain l2's rpc is not a plain alias" G plan refuse vault.check
  echo '{"chains":{"l2":{"id":31337,"rpc":"a b"}}}' >$n; refused "rpc is not a plain alias" G run refuse vault.check
  echo '{"chains":{"l2":{"id":31337,"rpc":"my.node"}}}' >$n; refused "rpc is not a plain alias" G run refuse vault.check
  echo '{"chains":{"l2":{"id":31337,"rpc":"123"}}}' >$n; refused "rpc is not a plain alias" G run refuse vault.check
  echo '{"chains":{"l2":{"id":31337,"rpc":"Node"}}}' >$n; refused "rpc is not a plain alias" G run refuse vault.check
  # Only a rehearsal copy names a URL: its forks'.
  echo "{\"chains\":{\"l2\":{\"id\":31337,\"rpc\":\"$RPC\"}}}" >$n; refused "rpc is not a plain alias" G run refuse vault.check
  echo '{"chains":{"l2":{"id":1,"rpc":"local"}}}' >$n; refused "local is chain 31337, network.json says 1" G run refuse vault.check
  # forge and cast take these over the line's flags.
  network refuse 31337
  local n0; n0=$(nonce)
  # Set to forge's default sender, it shows no difference in forge config, yet still beats --sender.
  FOUNDRY_SENDER=0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38 refused "forge would take FOUNDRY_SENDER (" G run refuse vault.check
  dapp_test_sender=0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38 refused "forge would take dapp_test_sender (" G run refuse vault.check
  echo "export FOUNDRY_SENDER=$OPS" >.env
  refused "forge would take FOUNDRY_SENDER, sender" G run refuse vault.check
  # It overrides the foundry.toml aliases it names, so it could point the line's alias at any node.
  echo "FOUNDRY_RPC_ENDPOINTS={local=\"$RPC\"}" >.env
  refused "forge would take FOUNDRY_RPC_ENDPOINTS (" G run refuse vault.check
  rm .env
  [ "$(nonce)" = "$n0" ] || die "refuses: a run with an overriding variable sent"
  echo "ok  usage and configuration errors exit 2 before any chain is touched"
}

# The plan is the graph script's, so a saved export that no longer matches the graph decides nothing: a
# target the graph has runs, one it lacks is refused by the graph with exit 2 and no forge trace.
stale_export() { jq "$1" script/deploy/graph.generated.json >"$W/j" && mv "$W/j" script/deploy/graph.generated.json; }
scenario_live_graph() {
  local out
  stale_export '.nodes |= map(select(.unit != "vault"))'
  exits 0 G plan local vault.check
  git checkout -q script/deploy/graph.generated.json
  stale_export '.nodes += [(.nodes[0] | .id = "ghost.deploy")]'
  out=$(G plan local ghost.deploy 2>&1 </dev/null) && die "live graph: a target the graph lacks was planned"
  git checkout -q script/deploy/graph.generated.json
  grep -q '^sprue: cannot reach ghost.deploy: unknown target; see sprue list$' <<<"$out" || die "live graph: the unknown target was not named: $out"
  ! grep -q 'script failed\|Traceback\|Error:' <<<"$out" || die "live graph: the refusal shows forge's trace: $out"
  refused 'unknown target' G plan local ghost.deploy
  refused 'cannot reach ghost target: unknown target' G plan local 'ghost target'
  echo "ok  the plan is the live graph's: a target absent from the saved export runs, one absent from the graph exits 2 cleanly"
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
  local dead=0x000000000000000000000000000000000000dEaD out rc=0 n0
  echo "{\"chains\":{\"l2\":{\"id\":31337,\"rpc\":\"local\"}},\"deployer\":\"$dead\"}" >deployments/pinned/network.json
  # The pin is the default deployer, and one that the run cannot sign as is refused before any send.
  n0=$(nonce)
  refused "DEPLOYER is $OPS, and pinned's network.json pins the deployer $dead" G run pinned token.check
  refused "pins the deployer $dead, and Anvil signs only for its unlocked accounts" env -u DEPLOYER G run pinned token.check
  refused "DEPLOYER is $dead, and Anvil signs only for its unlocked accounts" env DEPLOYER="$dead" G run --unsafe-unexpected-deployer pinned token.check
  network nopin 31337
  refused "unexpected-deployer has no use: nopin's network.json pins no deployer" G run --unsafe-unexpected-deployer nopin token.check
  [ "$(nonce)" = "$n0" ] || die "failure: a refused deployer sent"
  # An unlocked deployer without funds: forge's own failure.
  cast rpc anvil_impersonateAccount "$dead" --rpc-url "$RPC" >/dev/null
  out=$(env -u DEPLOYER G run pinned token.check 2>&1) || rc=$?
  cast rpc anvil_stopImpersonatingAccount "$dead" --rpc-url "$RPC" >/dev/null
  grep -q "^deployer $dead, from network.json$" <<<"$out" || die "failure: the run did not print the pinned deployer: ${out: -400}"
  [ "$rc" = 1 ] || die "failure: exited $rc, not 1: ${out: -400}"
  [ "$(tail -n 1 <<<"$out")" = "$(tail -n 2 <<<"$out" | head -n 1)" ] && [[ $(tail -n 1 <<<"$out") == Error:* ]] \
    || die "failure: forge's Error: line is not repeated at the end: $(tail -n 2 <<<"$out" | cut -c1-80)"
  fresh "$RPC"; rm -f deployments/pinned/token.json
  out=$(env -u DEPLOYER G run --unsafe-unexpected-deployer pinned token.check 2>&1) || die "failure: the unsafe run failed: ${out: -400}"
  grep -qi "^deployer $OPS, from the signer (--unsafe-unexpected-deployer)$" <<<"$out" || die "failure: the unsafe run did not print its deployer: $(grep -v "^ " <<<"$out" | head -20)"
  [ "$(jq -r .tokenDeployer deployments/pinned/token.json | tr A-F a-f)" = "$(tr A-F a-f <<<"$OPS")" ] \
    || die "failure: --unsafe-unexpected-deployer did not send the pin's steps as the signer"
  # A send whose records forge would write where no unit reads them is refused, before it sends, by
  # what forge resolves: the inherited environment or foundry.toml.
  network elsewhere 31337; local n0; n0=$(nonce)
  refused 'forge would keep this run.s records in elsewhere, not broadcast' env FOUNDRY_BROADCAST=elsewhere G run elsewhere token.check
  mv foundry.toml foundry.toml.ok; { echo '[profile.default]'; echo 'broadcast = "elsewhere"'; tail -n +2 foundry.toml.ok; } >foundry.toml
  refused 'forge would keep this run.s records in elsewhere, not broadcast' G run elsewhere token.check
  mv foundry.toml.ok foundry.toml
  # The units read each artifact and its metadata from out/, so a build elsewhere would journal an earlier one.
  refused 'forge would build into elsewhere, not out' env FOUNDRY_OUT=elsewhere G run elsewhere token.check
  rm -rf elsewhere
  [ "$(nonce)" = "$n0" ] || die "failure: a send with records or build elsewhere sent"
  # Each spelling of out/ is out/, through a symbolic link too.
  ln -s "$(pwd -P)" "$W.link"; local o i=0
  for o in ./out/ "$(pwd -P)/out" "$W.link/out"; do
    fresh "$RPC"; network "spelled$((i += 1))" 31337; exits 0 env FOUNDRY_OUT="$o" G run "spelled$i" token.check
  done
  echo "ok  a deployer the run cannot sign as is refused; a failed step ends with forge's Error: line; a send whose records or build would go elsewhere is refused"
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
# and after that command a rerun reaches done. Without DEPLOYER the run sends as Anvil's dev key.
scenario_recover() {
  fresh "$RPC"; git clean -fdXq deployments/local
  local out cmd
  env -u DEPLOYER G run local vault.check >/dev/null 2>>log || die "recover: the first run failed"
  [ "$(jq -r .tokenDeployer deployments/local/token.json | tr A-F a-f)" = "$(tr A-F a-f <<<"$OPS")" ] \
    || die "recover: without DEPLOYER the run did not send as Anvil's dev key"
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
  PATH="$PWD/stub:$PATH" exits 4 env -u DEPLOYER G run wait vault.check
  [ -n "$(jq -r '.vault // empty' deployments/wait/vault.json)" ] || die "wait: the work before the date was not done"
  [ "$(jq -r .vaultDeployer deployments/wait/vault.json | tr A-F a-f)" = "$(tr A-F a-f <<<"$OPS")" ] \
    || die "wait: without DEPLOYER a run off Anvil did not send as its signing key"
  local at; at=$(jq .openAt deployments/wait/vault.input.json)
  (sleep 3; cast rpc evm_setNextBlockTimestamp "$at" --rpc-url "$GETH" >/dev/null; cast rpc evm_mine --rpc-url "$GETH" >/dev/null) &
  local bumper=$!
  PATH="$PWD/stub:$PATH" exits 0 G run wait vault.check --wait
  wait "$bumper"
  [ -n "$(jq -r '.checked // empty' deployments/wait/vault.json)" ] || die "wait: --wait did not finish the target"
  network onanvil 31337 0
  exits 2 G run --wait onanvil vault.check
  exits 2 G plan onanvil no.such.target
  refused "unknown network 'nosuch'" G plan nosuch vault.check
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

# Two runs of one network, a rehearse's of its copy included: the second refuses while the first, or a
# forge it started, runs. A signal to the runner alone stops its forge before the lock is released.
scenario_concurrent() {
  local a rc n0 step fork
  pending() { for _ in $(seq 1 600); do [ "$(cast rpc txpool_status --rpc-url "${1:-$RPC}" | jq -r .pending)" != 0x0 ] && return; sleep 0.1; done; die "concurrent: no transaction became pending"; }
  mine() { cast rpc evm_setAutomine true --rpc-url "${1:-$RPC}" >/dev/null; cast rpc evm_mine --rpc-url "${1:-$RPC}" >/dev/null; }
  # forge_of <pid> <text>: sets step to the forge child of <pid> whose command line holds <text>.
  forge_of() {
    for _ in $(seq 1 1500); do
      step=$(ps -eo pid=,ppid=,args= | awk -v p="$1" -v t="$2" '$2 == p && / forge script / && index($0, t) && !x {x = $1} END {if (x) print x}')
      [ -n "$step" ] && return; sleep 0.02
    done
    die "concurrent: no forge with $2 under pid $1"
  }
  # held <network> <runner pid> <command...>: refused, naming the runner or the forge it sends with. Both
  # hold a lock file, and the refusal names whichever the directory lists first.
  held() { local net=$1 run=$2; shift 2; forge_of "$run" --broadcast; refused "a run of $net is running, as pid \($run\|$step\);" "$@"; }
  fresh "$RPC"; network conc 31337; n0=$(nonce)
  cast rpc evm_setAutomine false --rpc-url "$RPC" >/dev/null
  G run conc vault.check >"$W.a" 2>&1 & a=$!
  pending
  held conc "$a" G run conc vault.check
  mine
  rc=0; wait "$a" || rc=$?
  [ "$rc" = 0 ] || die "concurrent: the first run exited $rc: $(tail -c 600 "$W.a")"
  [ "$(nonce)" = $((n0 + 3)) ] || die "concurrent: $(( $(nonce) - n0 )) transactions, not 3"

  # A step whose runner was killed alone holds the lock until it exits.
  fresh "$RPC"; network conc 31337; n0=$(nonce)
  cast rpc evm_setAutomine false --rpc-url "$RPC" >/dev/null
  G run conc token.check >"$W.a" 2>&1 & a=$!
  pending; forge_of "$a" --broadcast
  kill -9 "$a"; wait "$a" 2>/dev/null || true
  refused "a run of conc is running, as pid $step" G run conc token.check
  mine
  for _ in $(seq 1 300); do kill -0 "$step" 2>/dev/null || break; sleep 0.1; done
  exits 0 G run conc token.check
  [ "$(nonce)" = $((n0 + 1)) ] || die "concurrent: $(( $(nonce) - n0 )) transactions after a killed runner, not 1"
  [ -z "$(ls .git/sprue-locks/conc/)" ] || die "concurrent: a lock file outlived its runs: $(ls .git/sprue-locks/conc/)"

  # The plan's forge, which on a rehearsal network writes journals, is stopped too. Paused, it cannot end
  # on its own before the check.
  G run conc token.check >"$W.a" 2>&1 & a=$!
  forge_of "$a" "plan(string,string)"
  kill -STOP "$step"; kill -HUP "$a"; sleep 1
  kill -0 "$a" 2>/dev/null || { kill -CONT "$step"; die "concurrent: SIGHUP ended the runner before the plan's forge"; }
  kill -CONT "$step"; rc=0; wait "$a" || rc=$?
  [ "$rc" = 129 ] || die "concurrent: SIGHUP while planning exited $rc, not 129: $(tail -c 600 "$W.a")"
  ! kill -0 "$step" 2>/dev/null || die "concurrent: the plan's forge outlived its runner"

  # rehearse refuses before it stops a kept fork or restages a copy that a run is using.
  network rl 31337
  exits 0 G rehearse --keep rl token.check
  fork=$(jq -r .chains.l2.rpc deployments/rehearsal-rl/network.json)
  cast rpc evm_setAutomine false --rpc-url "$fork" >/dev/null
  G run rehearsal-rl vault.check >"$W.a" 2>&1 & a=$!
  pending "$fork"
  held rehearsal-rl "$a" G rehearse rl token.check
  held rehearsal-rl "$a" G rehearse --stop rl
  held rehearsal-rl "$a" G plan rehearsal-rl vault.check
  [ -f deployments/rehearsal-rl/token.json ] && cast chain-id --rpc-url "$fork" >/dev/null || die "concurrent: rehearse touched a copy in use"
  mine "$fork"
  rc=0; wait "$a" || rc=$?
  [ "$rc" = 0 ] || die "concurrent: the run of the copy exited $rc: $(tail -c 600 "$W.a")"
  exits 0 G rehearse --stop rl
  rm -f "$W.a"
  echo "ok  concurrent a second run of a network refuses while the first or its forge runs; a signal stops the forge, then the lock"
}

# examples/two-chain on two Anvils. A date of a step on the second chain is that chain's: the runner sets the
# second node's clock, one window at a time, and leaves the first node's alone.
scenario_two_chain() {
  local d=$W/two-chain rcv=http://127.0.0.1:$((PORT + 3)) at out zero=0x0000000000000000000000000000000000000000
  cp -R "$ROOT/examples/two-chain" "$d"; ln -s "$W/lib" "$d/lib"
  cd "$d"
  sed -i.bak '/^\[rpc_endpoints\]/,$d' foundry.toml && rm -f foundry.toml.bak
  printf '[rpc_endpoints]\nsource = "%s"\nreceiver = "%s"\n' "$RPC" "$rcv" >>foundry.toml
  start_anvil $((PORT + 3)) 31338
  forge build -q >"$W/build.log" 2>&1 || { cat "$W/build.log" >&2; die "the two-chain example does not build"; }
  node "$W/lib/sprue/bin/sprue.mjs" json | diff - script/deploy/graph.generated.json || die "two-chain: graph.generated.json is stale"
  fresh "$RPC"
  # The receiver is the first contract of account 0 on its fresh chain: the address the input file names.
  at=$(jq .openAt deployments/local/receiver.input.json)
  forge create script/deploy/units/receiver/Receiver.sol:Receiver --rpc-url "$rcv" --unlocked --from "$OPS" --broadcast >/dev/null 2>>log
  opened() { cast call "$(jq -r .receiver deployments/local/receiver.input.json)" 'opened(uint8)(address)' "$1" --rpc-url "$rcv"; }
  [ "$(cast code "$(jq -r .receiver deployments/local/receiver.input.json)" --rpc-url "$rcv")" != 0x ] || die "two-chain: no receiver at the input's address"

  # rehearse forks both chains and sets the receiver fork's clock; the real nodes mine nothing.
  local b0; b0="$(cast block-number --rpc-url "$RPC") $(cast block-number --rpc-url "$rcv")"
  out=$(G rehearse local receiver.notify.2 2>&1) || die "two-chain: rehearse failed: $(tail -c 600 <<<"$out")"
  [ "$(grep -c '^fork ' <<<"$out")" = 2 ] || die "two-chain: rehearse did not fork both chains: $(tail -c 600 <<<"$out")"
  [ "$(cast block-number --rpc-url "$RPC") $(cast block-number --rpc-url "$rcv")" = "$b0" ] || die "two-chain: rehearse mined on a real node"
  exits 0 G run local receiver.notify.2
  for w in 0 1 2; do
    [ "$(opened $w)" = "$(jq -r .checked.source deployments/local/source.json)" ] || die "two-chain: window $w is not open"
  done
  [ "$(now "$rcv")" -ge "$((at + 2 * 86400))" ] || die "two-chain: the receiver's clock did not reach the last window"
  [ "$(now)" -lt "$at" ] || die "two-chain: the source's clock was moved"
  all_done two-chain "$(G plan local receiver.notify.2 2>>log)"
  # A step that selects its own forks never reads its journal through _use, and is refused all the same.
  cp -R deployments/local deployments/rehearsal-two
  out=$(forge script script/deploy/units/receiver/DeployReceiver.s.sol:DeployReceiver --sig 'notify(string,uint8)' \
    rehearsal-two 0 --sender "$OPS" 2>&1) && die "two-chain: a rehearsal dry run ran without its prefix"
  grep -q 'forge would keep this run.s records in broadcast, not' <<<"$out" || die "two-chain: a dry run without the prefix: ${out: -400}"
  # With the receiver's chain not local, its Anvil is refused where the step selects that chain's fork.
  jq '.chains.local = [31337]' sprue.json >sprue.json.new && mv sprue.json.new sprue.json
  out=$(forge script script/deploy/units/receiver/DeployReceiver.s.sol:DeployReceiver --sig 'notify(string,uint8)' \
    local 0 --sender "$OPS" --unlocked --broadcast 2>&1) && die "two-chain: a step sent through an Anvil on a chain not local"
  grep -q 'chain 31338 is served by Anvil, a development node' <<<"$out" || die "two-chain: the selected fork's node was not refused: ${out: -400}"
  cd "$W"; rm -rf "$d"
  echo "ok  two-chain: the runner sets the receiver chain's clock for each window's date, and not the source's"
}

# rehearse runs a target on forks of the network's chains that it starts and stops, as senders that hold no
# key. The real chain mines nothing, and the network's own directory gets no journal.
scenario_rehearse() {
  local d=deployments/rehearsal-main dead=0x000000000000000000000000000000000000dEaD b0 out url
  network main 1 "$(($(now "$LIVE") + 1000))"
  # Only a unit's journal certifies: an input that has a `checked` object does not.
  jq '. + {checked: {token: "'"$dead"'", tokenCodeHash: "0x00"}}' deployments/main/vault.input.json >"$W/j" && mv "$W/j" deployments/main/vault.input.json
  cast rpc anvil_setBalance "$dead" 0x8ac7230489e80000 --rpc-url "$LIVE" >/dev/null
  b0=$(cast block-number --rpc-url "$LIVE")
  local go=(env DEPLOYER="$dead" G rehearse)
  forkof() { jq -r .chains.l2.rpc "deployments/rehearsal-$1/network.json"; }
  # Inherited, a keystore name that forge would fail to find, and an eth_rpc_url that forge would send to
  # over --rpc-url, are dropped.
  out=$(ETH_KEYSTORE_ACCOUNT=nosuch FOUNDRY_ETH_RPC_URL=$LIVE "${go[@]}" main vault.check 2>&1) || die "rehearse: failed: $(tail -c 600 <<<"$out")"
  grep -q "^deployer $dead, from DEPLOYER$" <<<"$out" || die "rehearse: the deployer and its source were not printed"
  [ "$(cast block-number --rpc-url "$LIVE")" = "$b0" ] || die "rehearse: the real chain mined a block"
  [ ! -e deployments/main/token.json ] || die "rehearse: the source network got a journal"
  jq -e .checked "$d/vault.json" >/dev/null || die "rehearse: the vault is not checked in $d: $(tail -c 600 <<<"$out")"
  url=$(grep -o '^fork l2 chain 1 block [0-9]* http://[0-9.:]*' <<<"$out" | awk '{print $NF}')
  [ -n "$url" ] || die "rehearse: no fork line: $(tail -c 600 <<<"$out")"
  ! cast chain-id --rpc-url "$url" >/dev/null 2>&1 || die "rehearse: the fork still runs"
  [ -z "$(ls -d broadcast/*/1 cache/*/1 2>/dev/null)" ] || die "rehearse: records or resume data outside $d"
  jq -e '.tokenDirty == true' "$d/token.json" >/dev/null || die "rehearse: a run from a dirty tree journaled the token clean"
  # The chain's alias names the fork's upstream; the copy names the fork, so every command reads it.
  grep -q '(from alias live)' <<<"$out" || die "rehearse: the alias did not name the upstream: $(tail -c 600 <<<"$out")"
  [ "$(forkof main)" = "$url" ] || die "rehearse: the copy names $(forkof main), not its fork $url"
  [ "$(jq -r .chains.l2.rpc deployments/main/network.json)" = live ] || die "rehearse: the source network's rpc changed"

  # A signal to the runner alone stops the running step before the lock is released: the step writes
  # its journal until it exits, and a kept fork would let it finish.
  "${go[@]}" --keep main vault.check >"$W.int" 2>&1 & local pid=$! rc=0 step=
  for _ in $(seq 1 1500); do
    # awk reads all of ps: an early exit would end ps with SIGPIPE, which pipefail makes fatal.
    # Only this runner's child: another suite on the machine runs the same commands.
    step=$(ps -eo pid=,ppid=,args= | awk -v r="$pid" '$2 == r && /forge script .* rehearsal-main .*--broadcast/ && !p {p = $1} END {if (p) print p}')
    [ -n "$step" ] && break; sleep 0.02
  done
  [ -n "$step" ] || die "rehearse: no step was seen to interrupt"
  kill -TERM "$pid"; wait "$pid" || rc=$?
  ! kill -0 "$step" 2>/dev/null || die "rehearse: the runner exited before its step"
  [ "$rc" = 143 ] || die "rehearse: SIGTERM exited $rc, not 143"
  exits 0 G rehearse --stop main
  # A fork still starting, here from an upstream that never answers, is stopped even with --keep: no
  # record could stop it later.
  local mute=$((PORT + 4)) fork=
  network mute 4663
  python3 -c "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', $mute)); s.listen(); c=s.accept(); time.sleep(120)" &
  local silent=$!; PIDS="$PIDS $silent"
  "${go[@]}" --keep mute token.check >/dev/null 2>&1 & pid=$!
  for _ in $(seq 1 300); do
    fork=$(ps -eo pid=,ppid=,args= | awk -v r="$pid" -v u="--fork-url wide " '$2 == r && index($0, u) && !p {p = $1} END {if (p) print p}')
    [ -n "$fork" ] && break; sleep 0.05
  done
  [ -n "$fork" ] || die "rehearse: no fork of the silent upstream started"
  sleep 0.5; kill -TERM "$pid"; wait "$pid" || true
  sleep 0.3; ! kill -0 "$fork" 2>/dev/null || die "rehearse: a fork still starting was kept"
  kill "$silent" 2>/dev/null || true
  # Ctrl-C stops the forks too.
  "${go[@]}" main vault.check >"$W.int" 2>&1 & local pid=$! rc=0
  for _ in $(seq 1 300); do grep -q '^senders are impersonated' "$W.int" && break; sleep 0.1; done
  url=$(grep -o '^fork l2 chain 1 block [0-9]* http://[0-9.:]*' "$W.int" | awk '{print $NF}')
  kill -INT "$pid"; wait "$pid" || rc=$?
  [ "$rc" = 130 ] || die "rehearse: an interrupt exited $rc, not 130"
  ! cast chain-id --rpc-url "${url:-none}" >/dev/null 2>&1 && [ -n "$url" ] || die "rehearse: an interrupt left the fork '$url' running"
  rm -f "$W.int"

  # --keep leaves the fork running, and the copy names it. The next rehearse stops it and starts over;
  # --stop stops a kept one.
  local kept
  "${go[@]}" --keep main token.check >/dev/null 2>&1; kept=$(forkof main)
  out=$(cast code "$(jq -r .token "$d/token.json")" --rpc-url "${kept:-none}") && [ "$out" != 0x ] || die "rehearse: no kept fork with the token at '$kept'"
  "${go[@]}" main token.check --keep >/dev/null 2>&1; url=$(forkof main)
  ! cast chain-id --rpc-url "$kept" >/dev/null 2>&1 || die "rehearse: a rerun left the kept fork running"
  cast chain-id --rpc-url "${url:-none}" >/dev/null 2>&1 || die "rehearse: no kept fork at '$url'"
  # --stop reads only the copy, so it stops forks whose source network is gone.
  mv deployments/main "$W.main"
  exits 0 G rehearse --stop main
  mv "$W.main" deployments/main
  ! cast chain-id --rpc-url "$url" >/dev/null 2>&1 || die "rehearse: --stop left the fork running"

  # A fork of a chain that bin/chains.json lists takes its code limit; others keep Ethereum's. One init
  # code returns 24577 bytes, one over Ethereum's code limit, and one is 49153 bytes, one over its
  # init-code limit.
  local code wide=http://127.0.0.1:$((PORT + 4))
  local big=(0x620060016000f3 "0x60006000f3$(printf '%098296d' 0)")
  "${go[@]}" --keep main token.check >/dev/null 2>&1; kept=$(forkof main)
  for code in "${big[@]}"; do
    ! cast estimate --from "$dead" --rpc-url "${kept:-none}" --create "$code" >/dev/null 2>&1 || die "rehearse: a fork of an unlisted chain took larger code"
  done
  start_anvil $((PORT + 4)) 4663
  cast rpc anvil_setBalance "$dead" 0x8ac7230489e80000 --rpc-url "$wide" >/dev/null
  network wide 4663
  out=$("${go[@]}" --keep wide token.check 2>&1) || die "rehearse: a fork of a listed chain failed: $(tail -c 600 <<<"$out")"
  grep -q '^fork l2 chain 4663 block [0-9]* code limit 98304 ' <<<"$out" || die "rehearse: the listed chain's code limit was not used: $(tail -c 600 <<<"$out")"
  kept=$(forkof wide)
  for code in "${big[@]}"; do
    cast estimate --from "$dead" --rpc-url "${kept:-none}" --create "$code" >/dev/null || die "rehearse: the listed chain's code limit did not reach its fork"
  done
  exits 0 G rehearse --stop wide

  refused 'no key signs' "${go[@]}" main token.check --account e2e
  refused 'it is a rehearsal network' "${go[@]}" rehearsal-main token.check
  # forge reads .env only for names unset, so a keystore named there is refused.
  echo 'ETH_KEYSTORE_ACCOUNT=nosuch' >.env
  refused 'sets ETH_KEYSTORE_ACCOUNT' "${go[@]}" main token.check
  echo "FOUNDRY_ETH_RPC_URL=$LIVE" >.env
  refused 'forge would take FOUNDRY_ETH_RPC_URL, eth_rpc_url (.env or foundry.toml) over the forks' "${go[@]}" main token.check
  rm .env
  # A copied check whose code the fork lacks, as at a --block before its deployment, is refused.
  cp "$d/token.json" deployments/main/token.json
  refused 'lacks the code token.json certifies' "${go[@]}" main token.check
  # The certificates are those of the copy's journals, whatever units the saved export names.
  cp "$d/token.json" deployments/main/token.json
  stale_export '(.nodes[] | select(.unit == "token") | .unit) = "renamed"'
  refused 'lacks the code token.json certifies' "${go[@]}" main vault.check
  git checkout -q script/deploy/graph.generated.json
  # A role certified on another chain is read on that chain's fork, and this network forks none.
  jq '.checked.tokenChainId = 99' "$d/token.json" >deployments/main/token.json
  out=$("${go[@]}" main token.check 2>&1) || true
  ! grep -q 'lacks the code' <<<"$out" || die "rehearse: a role was read on another chain's fork"
  rm deployments/main/token.json
  refused 'cannot reach nope.check: unknown target' "${go[@]}" main nope.check
  refused 'usage:' "${go[@]}" --wait main token.check
  network hand 1; mkdir -p deployments/rehearsal-hand; echo mine >deployments/rehearsal-hand/notes
  refused 'no rehearse staged it' "${go[@]}" hand token.check
  [ -f deployments/rehearsal-hand/notes ] || die "rehearse: deleted a directory it did not stage"
  mkdir -p "$W.noanvil"; ln -sf "$(command -v forge)" "$(command -v cast)" "$(command -v git)" "$W.noanvil/"
  refused 'anvil, which is not on PATH' /usr/bin/env PATH="$W/bin:$W.noanvil" DEPLOYER="$dead" G rehearse main token.check
  rm -rf "$W.noanvil" deployments/rehearsal-hand
  echo "ok  rehearse runs on forks it starts and stops as keyless senders; the real chain and network stay as they were"
}

# On a live chain (an Anvil of chain 1) a run is attended: each refusal sends nothing, and a change while the question waits stops it.
scenario_attended() {
  command -v python3 >/dev/null || { echo "skip attended: it needs python3"; return; }
  local net=rehearsal-live out rc n0 account=e2e
  network "$net" 1; network livenet 1
  git add -A; git commit -qm networks
  unset CI
  local run=(G run "$net" token.check --account "$account")
  refused 'no terminal' detached "${run[@]}"
  CI=1 refused 'CI is set' tty no "${run[@]}"
  refused 'development node' tty no G run livenet token.check --account "$account"
  # A line run by hand skips the runner's checks; the unit asks the node that forge sends to.
  out=$(forge script script/deploy/units/token/DeployToken.s.sol --sig 'deploy(string)' livenet --rpc-url live --sender "$OPS" \
    --unlocked --broadcast 2>&1) \
    && die "attended: a line run by hand ran on an Anvil posing as a live chain"
  grep -q 'is served by Anvil, a development node' <<<"$out" || die "attended: a line run by hand was not refused in process: ${out: -400}"
  # Rehearsal records are git-ignored, so an attended rehearsal must use development nodes.
  geth_stub "$W.bin"
  PATH=$W.bin:$PATH refused 'is not a development node' tty no "${run[@]}"
  # A node that does not name its client could be a development node, so it is refused too.
  printf '#!/bin/sh\n[ "$1 $2" != "rpc web3_clientVersion" ] || exit 1\nexec %s "$@"\n' "$(command -v cast)" >"$W.bin/cast"
  PATH=$W.bin:$PATH refused 'cannot read the node' tty no G run livenet token.check --account "$account"
  refused 'exactly one of' tty no G run "$net" token.check
  echo dirt >>README.md
  refused 'not clean' tty no "${run[@]}"
  refused 'has a live chain' tty no G run --allow-dirty "$net" token.check --account "$account"
  git checkout -q README.md
  git config core.autocrlf true; rm README.md; git checkout -q README.md
  refused 'other line endings than the commit' tty no "${run[@]}"
  git config --unset core.autocrlf; rm README.md; git checkout -q README.md
  DEPLOYER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 refused 'this run signs only as' tty no "${run[@]}"
  # A pin is the default deployer: a wallet that is not it is refused at the start, one that is it sends.
  local plain; plain=$(<"deployments/$net/network.json")
  jq -c '. + {deployer: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"}' <<<"$plain" >"deployments/$net/network.json"
  (unset DEPLOYER; refused 'pins the deployer 0x70997970C51812dc3A010C7d01b50e0d17dc79C8, and this run signs only as' tty no "${run[@]}")
  jq -c --arg d "$OPS" '. + {deployer: $d}' <<<"$plain" >"deployments/$net/network.json"
  rc=0; out=$( (unset DEPLOYER; tty no "${run[@]}") 2>&1) || rc=$?
  [ "$rc" = 6 ] && grep -aqi "^deployer $OPS, from network.json" <<<"$out" || die "attended: the pinned wallet did not reach its question as the deployer ($rc): ${out: -600}"
  echo "$plain" >"deployments/$net/network.json"
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
  grep -aqE 'chain 1 nonce [0-9a-fx]+: CREATE Token 0x[0-9a-fA-F]{40} value 0x0' <<<"$out" || die "attended: the preview does not show the CREATE's chain, nonce, address and value: ${out: -600}"
  grep -aq 'Estimated amount required' <<<"$out" || die "attended: the preview does not show the cost"
  [ "$(nonce "$LIVE")" = "$n0" ] || die "attended: an answer of no sent"
  # Ctrl-C at the question ends the run at once: no listener holds the signal until Enter.
  rc=0; tty ^C "${run[@]}" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 130 ] && [ "$(nonce "$LIVE")" = "$n0" ] || die "attended: Ctrl-C at the question exited $rc, not 130, or sent"
  # Every step is asked, the check too.
  # Without DEPLOYER the run sends as its signer.
  out=$( (unset DEPLOYER; tty yes "${run[@]}") 2>&1) || die "attended: yes failed: ${out: -600}"
  [ "$(grep -ac 'Type yes: ' <<<"$out")" = 2 ] || die "attended: the deployment and the check were not both asked"
  grep -aq 'no transactions in the dry run' <<<"$out" || die "attended: the check's empty dry run was not shown as such"
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
  # sprue plan passes the prefix to the graph's probes of done views, not only to the commands it prints.
  out=$(G plan "$net" vault.check 2>&1) || die "attended: the plan of the next unit failed: ${out: -400}"
  ! grep -q '^# cannot reach' <<<"$out" || die "attended: the plan could not probe a step: $out"
  grep -q "forge script script/deploy/units/vault" <<<"$out" || die "attended: the plan has no vault step: $out"
  # --resume can send the graph's saved simulation, so rehearse keeps both paths under the staged network.
  local staged=deployments/rehearsal-rehearse-$net
  local rehearse=(forge script script/deploy/DeployGraph.s.sol --sig 'rehearse(string,string)' "$net" vault.check --rpc-url "$LIVE" --sender "$OPS")
  out=$("${rehearse[@]}" 2>&1) && die "attended: the graph rehearsed without its prefix"
  grep -q 'forge would keep this run.s records in broadcast, not' <<<"$out" || die "attended: a rehearse without the prefix: ${out: -400}"
  out=$(FOUNDRY_BROADCAST=$staged/broadcast FOUNDRY_CACHE_PATH=$staged/cache "${rehearse[@]}" 2>&1) || die "attended: a rehearse with its prefix failed: ${out: -400}"
  grep -q 'reached vault.check' <<<"$out" || die "attended: the rehearse did not reach its target: ${out: -400}"
  ls "$staged/broadcast/DeployGraph.s.sol/1/dry-run/"*-latest.json >/dev/null || die "attended: the rehearse saved no dry run under its network"
  [ -z "$(ls -d broadcast/DeployGraph.s.sol cache/DeployGraph.s.sol 2>/dev/null)" ] || die "attended: a rehearse kept records or resume data outside its network"
  # A rehearsal network's journals leave the tree clean only while git ignores them, which the runner checks.
  exits 0 tty no "${run[@]}"
  sed -i.bak '/rehearsal/d' .gitignore && rm .gitignore.bak
  git commit -qam unignore
  refused 'git does not ignore' tty no "${run[@]}"
  echo "ok  attended refusals send nothing, a change during the question stops the send, no sends nothing, yes sends once and asks every step, the rehearsal directories need the ignore line"
}

# On a live chain an attended run offers a tag at the journal's commit for each certified unit, and its
# push. A rerun offers only what is missing; a failed push keeps the run's status; a tag never moves.
scenario_tag() {
  command -v python3 >/dev/null || { echo "skip tag: it needs python3"; return; }
  unset CI
  local tag=deploy/prod/token out first commit prod=http://127.0.0.1:$((PORT + 5))
  # A chain of its own: the deployer's CREATEs on chain 1 would trip the nonce fence.
  live_node $((PORT + 5)) 10
  echo 'deployments/rehearsal*/' >>.gitignore
  # The run takes its units from the graph, not the saved export, which here names the token's unit otherwise.
  stale_export '(.nodes[] | select(.unit == "token") | .unit) = "renamed"'
  network prod 10; git add -A; git commit -qm prod
  # A rehearsal network's sends must reach Anvil, here one that answers as Geth.
  network rehearsal-prod 10
  out=$(FOUNDRY_BROADCAST=deployments/rehearsal-prod/broadcast FOUNDRY_CACHE_PATH=deployments/rehearsal-prod/cache \
    forge script script/deploy/units/token/DeployToken.s.sol --sig 'deploy(string)' rehearsal-prod --rpc-url prod \
    --sender "$OPS" --unlocked --broadcast 2>&1) && die "tag: a rehearsal sent to a live node"
  grep -q 'chain 10 is not served by Anvil, which a rehearsal network requires' <<<"$out" || die "tag: a rehearsal's live node was not refused: ${out: -400}"
  git init -q --bare "$W.remote"; git remote add origin "$W.remote"
  # The push names one tag, whatever the configuration follows.
  git config push.followTags true; git tag -a -m other unrelated
  local run=(G run prod token.check --account e2e)
  out=$(tty yes,yes,yes,yes "${run[@]}" 2>&1) || die "tag: the run failed: $(tail -c 600 <<<"$out")"
  [ "$(git cat-file -t "$tag")" = tag ] || die "tag: no annotated tag $tag: $(tail -c 600 <<<"$out")"
  [ "$(git rev-parse "$tag^{commit}")" = "$(git rev-parse "$(jq -r .tokenCommit deployments/prod/token.json)^{commit}")" ] || die "tag: not at the journal's commit"
  git ls-remote --tags origin "refs/tags/$tag" | grep -q . || die "tag: not pushed"
  ! git ls-remote --tags origin refs/tags/unrelated | grep -q . || die "tag: the push took another tag"
  git add -A; git commit -qm journals
  out=$(tty no "${run[@]}" 2>&1) || die "tag: the rerun failed: $(tail -c 600 <<<"$out")"
  ! grep -q "Type yes\|$tag" <<<"$out" || die "tag: a finished rerun asked or reported: $(tail -c 600 <<<"$out")"
  git push -q origin ":refs/tags/$tag"
  out=$(tty no "${run[@]}" 2>&1) || die "tag: a rerun failed: $(tail -c 600 <<<"$out")"
  ! git ls-remote --tags origin "refs/tags/$tag" | grep -q . || die "tag: pushed without a yes"
  out=$(tty yes "${run[@]}" 2>&1) || die "tag: a rerun failed: $(tail -c 600 <<<"$out")"
  git ls-remote --tags origin "refs/tags/$tag" | grep -q . || die "tag: a rerun did not offer the lost push again"
  git push -q origin ":refs/tags/$tag"; git remote set-url origin "$W.nowhere"
  out=$(tty yes "${run[@]}" 2>&1) || die "tag: a failed push failed the run"
  grep -qF "push failed; retry with git push --no-follow-tags origin refs/tags/$tag:refs/tags/$tag" <<<"$out" || die "tag: no retry command: $(tail -c 600 <<<"$out")"
  git remote set-url origin "$W.remote"
  first=$(git rev-list --max-parents=0 HEAD)
  git tag -d "$tag" >/dev/null; git tag -a -m other "$tag" "$first"
  out=$(tty no "${run[@]}" 2>&1) || die "tag: a rerun failed: $(tail -c 600 <<<"$out")"
  grep -q 'a tag of another tree exists' <<<"$out" || die "tag: another tree's tag was not reported: $(tail -c 600 <<<"$out")"
  [ "$(git rev-parse "$tag^{commit}")" = "$first" ] || die "tag: a tag moved"
  git tag -d "$tag" >/dev/null
  out=$(tty no "${run[@]}" 2>&1) || die "tag: a rerun failed: $(tail -c 600 <<<"$out")"
  ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "tag: tagged without a yes"
  # A squash merge gives the journal's commit's tree another commit: a tag there is pushed as it is.
  commit=$(jq -r .tokenCommit deployments/prod/token.json)
  squash=$(git commit-tree "$commit^{tree}" -m squash)
  git tag -a -m squash "$tag" "$squash"
  out=$(tty yes "${run[@]}" 2>&1) || die "tag: a rerun failed: $(tail -c 600 <<<"$out")"
  [ "$(git ls-remote origin "refs/tags/$tag^{}" | cut -f1)" = "$squash" ] || die "tag: a squash commit's tag was not pushed: $(tail -c 600 <<<"$out")"
  git tag -d "$tag" >/dev/null; git push -q origin ":refs/tags/$tag"
  # A ref named as the journal's abbreviated commit does not pick the commit.
  git branch "$commit" "$first"
  out=$(tty yes "${run[@]}" 2>&1) || die "tag: a rerun failed: $(tail -c 600 <<<"$out")"
  grep -q 'not one commit of this repository' <<<"$out" || die "tag: a ref named as the commit was tagged: $(tail -c 600 <<<"$out")"
  git branch -D "$commit" >/dev/null
  # A recorded object that is no commit is never tagged.
  jq --arg t "$(git rev-parse HEAD^{tree})" '.tokenCommit = $t' deployments/prod/token.json >"$W/j" && mv "$W/j" deployments/prod/token.json
  git add deployments/prod/token.json; git commit -qm tree
  out=$(tty yes "${run[@]}" 2>&1) || die "tag: a rerun failed: $(tail -c 600 <<<"$out")"
  grep -q 'not one commit of this repository' <<<"$out" || die "tag: a tree was tagged: $(tail -c 600 <<<"$out")"
  # A journal that records a dirty tree is neither tagged nor, tagged by hand, pushed.
  git tag -a -m by-hand "$tag" "$commit^{commit}"
  jq --arg c "$commit" '.tokenCommit = $c | .tokenDirty = true' deployments/prod/token.json >"$W/j" && mv "$W/j" deployments/prod/token.json
  git add deployments/prod/token.json; git commit -qm dirty
  out=$(tty yes "${run[@]}" 2>&1) || die "tag: a rerun failed: $(tail -c 600 <<<"$out")"
  grep -q 'not tagged: tokenDirty records a dirty tree' <<<"$out" || die "tag: a dirty journal was offered: $(tail -c 600 <<<"$out")"
  ! git ls-remote --tags origin "refs/tags/$tag" | grep -q . || die "tag: a dirty journal's tag was pushed"
  # A unit certified on a test chain gets no offer, though its network also names a live chain.
  live_node $((PORT + 6)) 11155111
  network stage 11155111
  echo '{"chains":{"l2":{"id":11155111,"rpc":"stage"},"eth":{"id":10,"rpc":"prod"}}}' >deployments/stage/network.json
  git add -A; git commit -qm stage
  out=$(tty yes,yes,yes,yes,yes,yes G run stage token.check --account e2e 2>&1) \
    || die "tag: the test-chain run failed: $(tail -c 600 <<<"$out")"
  grep -q '# chain eth 10 live' <<<"$out" || die "tag: the stage network names no live chain: $(tail -c 600 <<<"$out")"
  jq -e '.checked' deployments/stage/token.json >/dev/null || die "tag: the test-chain run certified nothing"
  ! git rev-parse -q --verify refs/tags/deploy/stage/token >/dev/null || die "tag: a test-chain unit was tagged"
  ! grep -q 'deploy/stage/token' <<<"$out" || die "tag: a test-chain unit was offered: $(tail -c 600 <<<"$out")"
  rm -rf "$W.remote"
  echo "ok  a live run offers a tag at the journal's commit and its push; a rerun offers only what is missing, a failed push keeps the status, a tag never moves, a dirty journal or a unit on a test chain gets none"
}

# `run` sends the command lines that the FileGraph tests and the example's plan print, and nothing hostile.
scenario_grammar() {
  { (cd "$ROOT" && forge test --match-path 'test/FileGraph*' -vv 2>&1) | sed -n 's/^ *PLAN //p'
    G plan local vault.check; } | grep -E '^([A-Z][A-Z0-9_]*=|forge script )' | sort -u >"$W/corpus"
  [ "$(wc -l <"$W/corpus")" -ge 6 ] || die "grammar: too few command lines in $W/corpus"
  bash "$HERE/plan-grammar.sh" "$W/corpus" 2>>"$W/log" || die "grammar: see $W/log"
  echo "ok  run sends every command line the tests and the example print, and no hostile mutation"
}

# An RPC that answers from a node a block behind the one that took each send: each run stops at a step
# that cannot see the last send yet, and says why, and the reruns end done with no transaction twice.
scenario_lag() {
  local up out rc nodes i seen=no
  nodes=$PIDS; LAG=1 live_node $((PORT + 8)) 1337; nodes=${PIDS#"$nodes"}
  up=$(sed -n 's/^Listening on \(.*\)$/http:\/\/\1/p' "$W.node-$((PORT + 8)).log")
  fresh "$up"; network lag 1337
  for i in 1 2 3 4 5 6; do
    rc=0; out=$(env -u DEPLOYER G run lag vault.check 2>&1) || rc=$?
    [ "$rc" = 0 ] && break
    ! grep -aq "token at 0x[0-9a-fA-F]* has no code: if the RPC lags" <<<"$out" || seen=yes
    grep -aq "token at 0x[0-9a-fA-F]* has no code: if the RPC lags\|its plan is unchanged after sending it\|the vault is not funded" <<<"$out" \
      || die "lag: run $i exited $rc for another reason: $(grep -a '^Error\|sprue:' <<<"$out" | tail -3)"
    cast rpc evm_mine --rpc-url "$up" >/dev/null
  done
  [ "$rc" = 0 ] || die "lag: not done after $i runs"
  [ "$seen" = yes ] || die "lag: no run said a role has no code, so the node did not lag"
  [ "$(cast nonce "$OPS" --rpc-url "$up")" = 3 ] || die "lag: $(cast nonce "$OPS" --rpc-url "$up") transactions, not 3"
  for p in $nodes; do kill "$p" 2>/dev/null || true; done
  echo "ok  lag a lagging RPC stops each run at what it cannot see yet, and the reruns end done, each transaction once"
}

# The chart is for mermaid, which this script cannot run: check its shape against the export.
scenario_mermaid() {
  local m; m=$(G mermaid)
  [ "$(head -1 <<<"$m")" = "flowchart TD" ] || die "mermaid: the first line is not 'flowchart TD'"
  [ "$(grep -c '^subgraph ' <<<"$m")" = "$(jq '[.nodes[].unit] | unique | length' script/deploy/graph.generated.json)" ] \
    || die "mermaid: not one subgraph per unit"
  echo "ok  mermaid starts with flowchart TD and has one subgraph per unit"
}

for s in ${E2E_ONLY:-}; do declare -F "scenario_$s" >/dev/null || die "E2E_ONLY: no scenario $s"; done
setup
cd "$W"
# E2E_ONLY="<name> ..." runs only those scenarios, in this order. Called outside a condition, so that
# set -e holds inside each.
for s in mermaid refuses live_graph grammar failure rerun recover wait kill concurrent lag two_chain rehearse attended tag; do
  if [ -n "${E2E_ONLY:-}" ] && [[ " $E2E_ONLY " != *" $s "* ]]; then continue; fi
  "scenario_$s"
done
echo "PASS e2e"

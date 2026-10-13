#!/bin/sh
# SPDX-License-Identifier: MIT
# The deploy graph from the shell; POSIX sh, for Linux and macOS.
set -eu
fail() { printf 'graph.sh: %s\n' "$2" >&2; exit "$1"; }
usage() {
  cat <<'EOF'
usage: graph.sh list | json | mermaid [target] | plan <network> <target> | run [flags] <network> <target>

run flags may appear anywhere after the command.

  list                      the targets: nodes no other node depends on
  json                      the graph from the units' code; the saved export, graph.generated.json beside the graph script, is it
  mermaid [target]          a flowchart of the graph, or of what target depends on
  plan <network> <target>   the commands that reach target; reads $R, the default chain's RPC; sends nothing
  run [--wait] [--unsafe-unexpected-deployer] [--allow-dirty] [--account <name> | --ledger | --trezor] <network> <target>
                            sends what plan prints and plans again; needs R and DEPLOYER

On a network whose chains sprue.json lists all as local it sends unattended, sending from Anvil's unlocked
accounts, or signing with KEY (Anvil's dev key if unset) on another node. On any other chain it is attended: it needs a
terminal and no CI variable, refuses a development node unless the network is a rehearsal network (the name that paths.rehearsal ends in),
signs through exactly one of --account, --ledger and --trezor, as the step's sender, and starts only on a clean git checkout (uncommitted journals of an
interrupted run included: commit them). Each step's dry run is shown with its transactions and cost,
and every step is asked: it is sent only after `yes` is typed at the terminal, with no pending
transaction and the sender's nonces, the git HEAD and status (but for the journals the run writes),
.env and ~/.foundry/foundry.toml unchanged since before the dry run. Nothing skips the question.

--allow-dirty skips only the clean-checkout check at the start, with a warning, and never on a live
chain; the per-step comparison and the question stay.

--unsafe-unexpected-deployer lets a deploy step send with a key other than network.json's `deployer`
(it exports UNSAFE_UNEXPECTED_DEPLOYER=1 for this run; forge takes only the variable).

run stops with one of these; after a stop at 3 or 4, meet the condition and run it again, which
skips every node already done:

  0   the target is done
  1   a step or a clock read failed
  2   usage error, unknown target, `--wait` on the unlocked chain, an unknown plan line, or a refusal: no terminal,
      CI set, a development node, a signer other than the step's sender, a pending transaction
  3   a node it cannot reach yet (`# cannot reach`)
  4   a date the chain has not reached; --wait waits for it instead
  5   the target is not done: a plan is unchanged after its sends
  6   the person did not answer `yes`; the step was not sent
  *   forge's own code, when a step refuses
EOF
}
# Help needs no project.
case ${1:-} in -h|--help) usage; exit ;; esac
# The project root is the nearest directory, from the current one up, that holds sprue.json. It does
# not depend on where this script lives. This script validates `paths` itself, because it needs them
# before forge can run, and reads only the few `chains` fields it uses. Chains.sol validates the whole
# file in every `FileGraph` `plan`, and a plan precedes every send.
PROJECT=sprue.json
root=$(pwd -P)
while [ ! -f "$root/$PROJECT" ]; do
  [ "$root" != / ] || fail 2 "refusing: no $PROJECT in $PWD or above"
  root=$(dirname "$root")
done
cd "$root"
jq -s -e 'length == 1 and (.[0] | type == "object" and keys == ["chains", "paths"] and (.chains | type == "object")
  and (.paths | type == "object" and keys == ["deployments", "graph", "rehearsal", "units"]
    and all(.[]; type == "string" and length > 0 and (test("\\s") | not))))' "$PROJECT" >/dev/null \
  || fail 2 "refusing: $PROJECT is not a file of exactly paths and chains, with the non-empty, whitespace-free paths deployments, graph, rehearsal and units"
DEPLOYMENTS=$(jq -r .paths.deployments "$PROJECT")
GRAPH_SCRIPT=$(jq -r .paths.graph "$PROJECT")
REHEARSAL=$(jq -r .paths.rehearsal "$PROJECT")
# The graph contract is named like its script file, and the saved export lies beside it.
script_file=${GRAPH_SCRIPT##*/}
GRAPH=$GRAPH_SCRIPT:${script_file%.s.sol}
case $GRAPH_SCRIPT in */*) GRAPH_JSON=${GRAPH_SCRIPT%/*}/graph.generated.json ;; *) GRAPH_JSON=graph.generated.json ;; esac
# A rehearsal network is <prefix> or <prefix>-<suffix>, a plain name under the deployments directory.
# The script checks that git ignores `<prefix>` and `<prefix>-x`, as a sample of the project's ignore
# rule for every rehearsal directory. Keeping that rule complete is the project's job. Calling forge
# directly bypasses this check.
rehearsal=${REHEARSAL#"$DEPLOYMENTS"/}
case $REHEARSAL in "$DEPLOYMENTS"/*) ;; *) rehearsal= ;; esac
case $rehearsal in ''|-*|*[!a-z0-9-]*) fail 2 "refusing: $PROJECT's paths.rehearsal is not $DEPLOYMENTS/<lower-case name>" ;; esac
git check-ignore -q "$REHEARSAL/" && git check-ignore -q "$REHEARSAL-x/" \
  || fail 2 "refusing: git does not ignore the directories <paths.rehearsal> and <paths.rehearsal>-*, where a rehearsal writes"
# The one shape of a command line, as Graph._command prints it. Forge's output also carries the
# console.log of every contract the plan calls, so a line is run only if it matches whole.
q="'"
COMMAND="^([A-Z][A-Z0-9_]*_RPC=\\$[A-Z][A-Z0-9_]*_RPC )*forge script [A-Za-z0-9_./][A-Za-z0-9_./-]*(:[A-Za-z0-9_]+)? --sig ${q}[A-Za-z_][A-Za-z0-9_]*\\((string|string,uint8)\\)${q} [a-z0-9][a-z0-9-]*( [0-9]+)?( --rpc-url (\\$[A-Z][A-Z0-9_]*|[a-z][a-z0-9_-]*))? --sender (\\\$DEPLOYER|0x[0-9a-fA-F]{40})( --slow)?\$"
# Anvil's published dev key, which signs on a local chain when KEY is unset.
DEV_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

known() {
  jq -e --arg t "$1" 'any(.nodes[]; .id == $t)' "$GRAPH_JSON" >/dev/null || fail 2 "cannot reach $1: unknown target; see graph.sh list, or regenerate graph.generated.json if the graph changed"
}

# graph <tag> <sig> [args]: prints the graph script's output lines that start with `<tag> `, without
# the tag. forge's output is captured first, because without pipefail a pipe would hide forge's failure.
graph() {
  tag=$1; shift
  out=$(forge script "$GRAPH" --sig "$@" 2>&1) || {
    printf '%s\n' "$out" >&2
    return 1
  }
  printf '%s\n' "$out" | sed -n "s/^ *$tag //p"
}

case ${1:-} in
  list) [ $# -eq 1 ] || { usage >&2; exit 2; }; graph TARGET 'list()'; exit ;;
  json) [ $# -eq 1 ] || { usage >&2; exit 2; }; graph GRAPH 'graph()'; exit ;;
  # Reads graph.generated.json, not forge, so the chart shows exactly the saved export.
  mermaid)
    [ $# -le 2 ] || { usage >&2; exit 2; }
    [ -z "${2:-}" ] || known "$2"
    jq -r --arg t "${2:-}" '
      def k: "n" + (gsub("[^A-Za-z0-9]"; "_"));
      def shape: if .kind == "predicate" then "([\"\(.id)\"])" else "[\"\(.id)\"]" end;
      . as $g | ($g.nodes | map({(.id): .}) | add) as $by
      | def close($i): $i, ($by[$i].dependencies[] | close(.));
      ($g.nodes | if $t == "" then . else ([close($t)] | unique) as $keep | map(select(.id | IN($keep[]))) end) as $ns
      | "flowchart TD",
        ($ns | group_by(.unit)[]
          | "subgraph \(.[0].unit | k)[\"\(.[0].unit)\"]",
            (.[] | "  \(.id | k)\(shape)" + (if .flags.testOnly then ":::testOnly" else "" end)),
            "end"),
        ($ns[] | .id as $id | .dependencies[] | "\(. | k) --> \($id | k)"),
        "classDef testOnly stroke-dasharray: 4 3"' "$GRAPH_JSON"
    exit
    ;;
  plan|run) verb=$1; shift ;;
  *) usage >&2; exit 2 ;;
esac

# Flags may stand anywhere. The other arguments keep their order.
wait= account= hw= signers=0 dirty_ok=
# Only `attend` sets it, per step: an inherited value would stamp a clean run's roles dirty.
unset DEPLOY_TREE_DIRTY
n=$#
while [ "$verb" = run ] && [ "$n" -gt 0 ]; do
  a=$1; shift; n=$((n - 1))
  case $a in
    --wait) wait=1 ;;
    --unsafe-unexpected-deployer) UNSAFE_UNEXPECTED_DEPLOYER=1; export UNSAFE_UNEXPECTED_DEPLOYER ;;
    --allow-dirty) dirty_ok=1 ;;
    --account) [ "$n" -gt 0 ] || { usage >&2; exit 2; }; account=$1; signers=$((signers + 1)); shift; n=$((n - 1)) ;;
    --ledger|--trezor) hw=${a#--}; signers=$((signers + 1)) ;;
    *) set -- "$@" "$a" ;;
  esac
done
[ $# -eq 2 ] || { usage >&2; exit 2; }
network=$1 target=$2
[ -n "$network" ] && [ -n "$target" ] || { usage >&2; exit 2; }
# The network name is printed into every command, so a space or a newline in it would add flags.
case $network in [!a-z0-9]*|*[!a-z0-9-]*) fail 2 "refusing network '$network': not a plain name" ;; esac
[ -f "$DEPLOYMENTS/$network/network.json" ] || fail 2 "unknown network '$network': no $DEPLOYMENTS/$network/network.json"
known "$target"
[ -n "${R:-}" ] || fail 2 "set R to the RPC the plan reads"
[ "$verb" = run ] || { graph PLAN 'plan(string,string)' "$network" "$target" --rpc-url "$R"; exit; }
[ -n "${DEPLOYER:-}" ] || fail 2 "set DEPLOYER to the sender of steps without .by"
printf '%s\n' "$DEPLOYER" | grep -Eq '^0x[0-9a-fA-F]{40}$' || fail 2 "DEPLOYER is not a 0x address"

# git status as the person sees it. Configuration (status.showUntrackedFiles, diff.ignoreSubmodules)
# must not hide an untracked file or a dirty submodule, and a failing git is a refusal, never an empty
# status.
porcelain() {
  git status --porcelain --untracked-files=all --ignore-submodules=none || fail 2 "refusing: git status failed"
}
units=$(jq -r '[.nodes[].unit | select(length > 0)] | unique[]' "$GRAPH_JSON")
# The signer's flags are kept in the positional parameters and passed as "$@", so a key is never
# parsed as shell syntax.
attended=
netfile=$DEPLOYMENTS/$network/network.json
jq -s -e 'length == 1 and (.[0] | type == "object" and ((.chains // {}) | type == "object" and all(keys[]; test("\\A[a-z][a-z0-9]*\\z"))))' "$netfile" >/dev/null \
  || fail 2 "refusing $network: a chain's name is not a plain lower-case name"
chains=$(jq -r '.chains // {} | keys_unsorted[]' "$netfile")
# The default chain: sprue.json's chains.default, which the network must have, else its only chain, else none
# (a step without .on then refuses at plan).
home=$(jq -r '.chains.default // empty' "$PROJECT")
if [ -n "$home" ]; then
  jq -e --arg h "$home" '.chains[$h]' "$netfile" >/dev/null 2>&1 \
    || fail 2 "refusing $network: network.json has no chain $home, which $PROJECT names as chains.default"
else
  home=$(jq -r '.chains // {} | keys_unsorted | if length == 1 then .[0] else empty end' "$netfile")
fi
# Local: every chain of the network is listed in sprue.json's chains.local, so a send needs no person.
# This only picks the signer. `plan`, which precedes every send, refuses a malformed list.
is_local() { jq -n -e --argjson i "$1" --slurpfile p "$PROJECT" '$p[0].chains.local | index($i) != null' >/dev/null; }
local_net=$(jq -r --slurpfile p "$PROJECT" '[.chains // {} | .[].id] as $ids
  | if ($ids | length) > 0 and all($ids[]; . as $i | $p[0].chains.local | index($i) != null) then 1 else empty end' "$netfile")
# Whether the node at $1 is Anvil, which sets its own clock.
is_anvil() { case $(cast rpc web3_clientVersion --rpc-url "$1" 2>/dev/null | tr -d '"') in anvil/*) return 0 ;; esac; return 1; }
anvil=
if [ -n "$local_net" ]; then
  # Anvil can send as any address a step names, which need not be the dev key's. Any other node signs
  # with a single key.
  if is_anvil "$R"; then anvil=1; set -- --unlocked; else set -- --private-key "${KEY:-$DEV_KEY}"; fi
  [ -z "$wait" ] || [ -z "$anvil" ] || fail 2 "--wait has no use on Anvil: it moves the clock itself"
else
  attended=1
fi
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# A chain's RPC: its alias, else the <CHAIN>_RPC variable. $R also serves the default chain.
rpc_of() {
  rpc=$(jq -r --arg r "$1" '.chains[$r].rpc // empty' "$netfile")
  [ -n "$rpc" ] || eval "rpc=\${$(printf '%s_RPC' "$1" | tr '[:lower:]' '[:upper:]'):-}"
  printf '%s' "$rpc"
}
# Each endpoint must serve the chain that network.json names. With FOUNDRY_CHAIN_ID set, forge's own
# chain check reads the variable and not the node, so the preview would show the network's chain for a
# send to another node.
expect_chain() {
  [ -n "$1" ] || return 0
  got=$(cast chain-id --rpc-url "$1") || fail 2 "cannot read the chain id at $1"
  [ "$got" = "$2" ] || fail 2 "refusing $network: $1 is chain $got, network.json says $2"
}
# A chain's rpc alias is printed into the commands, like the network name. A date line tells an alias from
# an RPC variable by its lower case.
jq -e '[.chains[]?.rpc // empty] | all(type == "string" and test("\\A[a-z][a-z0-9_-]*\\z"))' \
  "$netfile" >/dev/null || fail 2 "refusing $network: a chain's rpc alias is not a plain name"
endpoints=$R
for chain in $chains; do
  rpc=$(rpc_of "$chain")
  expect_chain "$rpc" "$(jq -r --arg r "$chain" '.chains[$r].id' "$netfile")"
  [ "$chain" != "$home" ] || expect_chain "$R" "$(jq -r --arg r "$chain" '.chains[$r].id' "$netfile")"
  endpoints="$endpoints $rpc"
done
if [ -n "$attended" ]; then
  # Not stdin: the question is read from /dev/tty, so it is the terminal that must open.
  [ -z "${CI+x}" ] || fail 2 "refusing $network: CI is set; a person at a terminal sends to a public chain"
  (: </dev/tty) 2>/dev/null || fail 2 "refusing $network: no terminal to ask on"
  [ "$signers" = 1 ] || fail 2 "sign with exactly one of --account, --ledger and --trezor"
  if [ -n "$dirty_ok" ]; then
    # A live chain deploys only from a clean commit, so refuse if any chain is live. The kinds come from
    # the `# chain` lines that `plan` prints. Refuse too if no kind is seen.
    planned=$(graph PLAN 'plan(string,string)' "$network" "$target" --rpc-url "$R")
    kinds=$(printf '%s\n' "$planned" | sed -n 's/^# chain [^ ]* [0-9]* //p')
    [ -n "$kinds" ] && ! printf '%s\n' "$kinds" | grep -qx live \
      || fail 2 "refusing --allow-dirty: $network has a live chain (or no chain kind), which deploys from a clean commit"
    printf 'warning: --allow-dirty: the working tree is not required to be clean\n'
  else
    status=$(porcelain)
    [ -z "$status" ] \
      || fail 2 "refusing: the working tree is not clean; commit it (the journals of an interrupted run too), or on a test chain pass --allow-dirty"
  fi
  # Outside a rehearsal network a development node is refused: a run on a fork or devnet would write
  # the network's committed journals and records.
  case $network in
    "$rehearsal"|"$rehearsal"-*) ;;
    *)
      for rpc in $endpoints; do
        version=$(cast rpc web3_clientVersion --rpc-url "$rpc") || fail 2 "cannot read the node at $rpc"
        id=$(cast chain-id --rpc-url "$rpc") || fail 2 "cannot read the chain id at $rpc"
        dev=
        case $(printf '%s' "$version" | tr -d '"') in anvil/*) dev=1 ;; *) ! is_local "$id" || dev=1 ;; esac
        [ -z "$dev" ] || fail 2 "refusing $network: $rpc is a development node ($version, chain $id); rehearse on a $rehearsal-* network"
      done
      ;;
  esac
  if [ -n "$account" ]; then set -- --account "$account"; else set -- "--$hw"; fi
  me=$(cast wallet address "$@")
  printf 'signer %s\n' "$me"
fi

# Prints the sender's latest nonce on each endpoint, and refuses if the sender has a pending
# transaction at any of them.
nonces() {
  for rpc in $endpoints; do
    latest=$(cast nonce "$sender" --block latest --rpc-url "$rpc")
    [ "$latest" = "$(cast nonce "$sender" --block pending --rpc-url "$rpc")" ] \
      || fail 2 "refusing: $sender has a pending transaction at $rpc; wait for it or replace it"
    printf '%s ' "$latest"
  done
}
# The working-tree changes that matter while the person is asked to confirm: git status, minus the
# journals and metadata the run itself writes (<unit>.json and *.metadata.json). Known gap: the send
# runs forge again, so any other state that forge reads may differ from the dry run the person saw.
changes() {
  st=$(porcelain)
  printf '%s\n' "$st" | while IFS= read -r l; do
    p=${l#???} skip=
    case $p in "$DEPLOYMENTS/$network/"*.metadata.json) skip=1 ;; esac
    for u in $units; do [ "$p" != "$DEPLOYMENTS/$network/$u.json" ] || skip=1; done
    [ -n "$skip" ] || printf '%s\n' "$l"
  done
}
# listed <lines> <line>: whether <line> is one of the newline-separated <lines>.
listed() {
  case "
$1
" in *"
$2
"*) return 0 ;; esac
  return 1
}
# changes(), minus the untracked records that this run's own earlier sends created (ownership is by
# path, in $ours). `tree`, the approval comparison, does not filter them: a new record path that
# appears while the question waits makes the send refuse. Rewriting an existing untracked path does
# not.
unowned() { changes | while IFS= read -r l; do listed "$ours" "$l" || printf '%s\n' "$l"; done; }
tree() {
  changes
  for f in .env "${HOME:-/nonexistent}/.foundry/foundry.toml"; do [ ! -f "$f" ] || cksum "$f"; done
}
# step <command...>: runs it with its output streaming. If it fails, repeats forge's last `Error:` line
# after the output, where a long run buries it, and exits with its code.
step() {
  log=$(mktemp); rcfile=$(mktemp)
  { rc=0; "$@" </dev/null 2>&1 || rc=$?; echo "$rc" >"$rcfile"; } | tee "$log"
  rc=$(cat "$rcfile")
  [ "$rc" = 0 ] || { grep '^Error:' "$log" | tail -n 1 >&2 || :; rm -f "$log" "$rcfile"; exit "$rc"; }
  rm -f "$log" "$rcfile"
}
# attend: show $line's dry run, and send it only if the person at the terminal answers yes.
attend() {
  sender=$(printf '%s\n' "$line" | sed -n 's/.* --sender \([^ ]*\).*/\1/p')
  [ "$sender" != '$DEPLOYER' ] || sender=$DEPLOYER
  [ "$(lc "$sender")" = "$(lc "$me")" ] || fail 2 "refusing: this step sends as $sender, not the signer $me: $line"
  snap=$(nonces)
  head=$(git rev-parse HEAD) || fail 2 "refusing: git rev-parse failed"
  seen=$(tree)
  # The journal records this for a role the step creates: the tree at the send, not at a later recovery.
  # A record under the path of this run's own earlier send makes no later step dirty.
  export DEPLOY_TREE_DIRTY=$([ -z "$(unowned)" ] || echo 1)
  rc=0; out=$(sh -c "$line" </dev/null 2>&1) || rc=$?
  printf '%s\n' "$out"
  [ "$rc" = 0 ] || { printf '%s\n' "$out" | grep '^Error:' | tail -n 1 >&2 || :; exit "$rc"; }
  # Forge saves a dry run that has transactions and names the file. If the output says it has
  # transactions but names no file, they cannot be shown, so refuse.
  records=$(printf '%s\n' "$out" | sed -n 's/^Transactions saved to: //p')
  if [ -n "$records" ]; then
    printf '%s\n' "$records" | while IFS= read -r f; do
      jq -r '(.deployments // [.])[] | .chain as $c | .transactions[] | "  chain \($c) nonce \(.transaction.nonce):"
        + " \(.transactionType) \(.contractName // "") \(.contractAddress // .transaction.to) value \(.transaction.value)"
        + " \(.function // "") \(.arguments // [] | tojson)"' "$f"
    done
  else
    ! printf '%s\n' "$out" | grep -q '^SIMULATION COMPLETE' || fail 2 "refusing: the dry run has transactions but names no record to show"
    printf '  no transactions in the dry run\n'
  fi
  printf '%s\nSend this as %s? Type yes: ' "$line" "$sender" >/dev/tty
  answer=; IFS= read -r answer </dev/tty || :
  [ "$answer" = yes ] || fail 6 "not sent: the answer was not yes"
  [ "$(nonces)" = "$snap" ] || fail 2 "refusing: the sender's nonce moved since before the dry run; run again"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail 2 "refusing: HEAD moved since before the dry run; run again"
  [ "$(tree)" = "$seen" ] || fail 2 "refusing: the working tree changed since before the dry run; run again"
  pre=$(porcelain)
  step sh -c "$line --broadcast \"\$@\"" graph.sh "$@"
  # Ownership is by path: the new untracked records under this step's script directory (its chain id is
  # not known here). A concurrent run of the same script is not told apart.
  script=$(printf '%s\n' "$line" | sed -n 's/.*forge script \([^ :]*\).*/\1/p')
  ours=$ours$(porcelain | while IFS= read -r l; do
    case $l in "?? broadcast/${script##*/}/"*) listed "$pre" "$l" || printf '\n%s' "$l" ;; esac
  done)
}
# A date line names the RPC variable or alias of its chain (`# not before <ts> on <CHAIN>_RPC ...`).
# Without `on`, the clock is $R's.
before() {
  clock=$R
  if [ -n "$on" ]; then
    case $on in *[!A-Za-z0-9_-]*) fail 2 "unknown plan line: $line" ;; esac
    # An RPC variable's name is upper case; anything else is a foundry.toml alias, which cast resolves.
    case $on in *[!A-Z0-9_]*) clock=$on ;; *) eval "clock=\${$on}" ;; esac
  fi
  now=$(cast block latest --field timestamp --rpc-url "$clock") || fail 1 "cannot read the clock at $clock"
  [ "$now" -lt "$at" ]
}
sent=
ours=
while :; do
  lines=$(graph PLAN 'plan(string,string)' "$network" "$target" --rpc-url "$R")
  # A plan equal to the one just sent shows no progress in planning. Stop instead of sending the same
  # commands again.
  [ -z "$sent" ] || [ "$lines" != "$sent" ] || fail 5 "cannot reach $target: its plan is unchanged after sending it"

  while IFS= read -r line; do
    case $line in
      "# not before "*)
        at=${line#'# not before '}; rest=${at#* }; at=${at%% *}
        on=; case $rest in "on "*) on=${rest#on }; on=${on%% *} ;; esac
        case $at in ''|*[!0-9]*) fail 2 "unknown plan line: $line" ;; esac
        if before; then
          if [ -n "$anvil" ] && is_anvil "$clock"; then
            cast rpc evm_setNextBlockTimestamp "$at" --rpc-url "$clock" >/dev/null
            cast rpc evm_mine --rpc-url "$clock" >/dev/null
          else
            [ -n "$wait" ] || fail 4 "$line"
            printf '%s: waiting\n' "$line"
            while before; do sleep 5; done
          fi
          # The rest of this plan was judged before the date, so plan again.
          continue 2
        fi
        ;;
      "# then plan again "*) sent=$lines; continue 2 ;;
      # The step's command follows and would refuse, so it is not sent.
      "# cannot reach "*) printf '%s\n' "$line"; exit 3 ;;
      "# chain "*|"# done "*) printf '%s\n' "$line" ;;
      "#"*) fail 2 "unknown plan line: $line" ;;
      "") ;;
      *)
        printf '%s\n' "$line" | grep -Eq "$COMMAND" || fail 2 "unknown plan line: $line"
        # The shell splits an unquoted variable at whitespace, which would add flags to the command.
        for name in $(printf '%s\n' "$line" | grep -Eo '\$[A-Z][A-Z0-9_]*' | tr -d '$'); do
          eval "value=\${$name-}"
          case $value in *[[:space:]]*) fail 2 "refusing: \$$name holds whitespace" ;; esac
        done
        sent=$lines
        if [ -n "$attended" ]; then attend "$@"; else step sh -c "$line --broadcast \"\$@\"" graph.sh "$@"; fi
        ;;
    esac
  done <<EOF
$lines
EOF
  # Judge what the sends left: a plan with nothing to send, even an empty one, ends the run.
  [ -n "$sent" ] && [ "$sent" = "$lines" ] || break
done

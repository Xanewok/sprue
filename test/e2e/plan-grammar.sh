#!/usr/bin/env bash
# `run` sends every command line that Graph._command prints, as one `forge script` argv, and runs
# nothing else. Usage: plan-grammar.sh <file of real command lines>. Needs node and git; forge and cast
# are stubs.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CORPUS=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

mkdir -p "$W/bin" "$W/deployments/net" "$W/script"
cd "$W"
git init -q
printf 'deployments/rehearsal*/\n' >.gitignore
cat >sprue.json <<'JSON'
{"paths":{"graph":"script/G.s.sol","units":"script/units","deployments":"deployments","rehearsal":"deployments/rehearsal"},
 "chains":{"default":"l2","local":[31337],"test":[],"unrecordedDeploys":{}}}
JSON
echo '{"chains":{"l2":{"id":31337}}}' >deployments/net/network.json
echo '{"nodes":[{"id":"t","unit":"u"}]}' >script/graph.generated.json
cat >bin/forge <<'STUB'
#!/bin/sh
case " $* " in
  *" plan(string,string) "*) sed 's/^/PLAN /' "$PLAN_FILE" ;;
  " config --json ") printf '{"broadcast":"%s","cache_path":"%s"}\n' "${FOUNDRY_BROADCAST:-broadcast}" "${FOUNDRY_CACHE_PATH:-cache}" ;;
  *) for a in "$@"; do printf '[%s]' "$a"; done >>"$CALLS"; echo >>"$CALLS" ;;
esac
STUB
cat >bin/cast <<'STUB'
#!/bin/sh
case $1 in rpc) echo '"anvil/v1"' ;; chain-id) echo 31337 ;; esac
STUB
chmod +x bin/forge bin/cast
export PATH=$W/bin:$PATH PLAN_FILE=$W/plan CALLS=$W/calls R=http://127.0.0.1:1 DEPLOYER=0x1111111111111111111111111111111111111111 MARK=$W/MARK

# The corpus names the RPC variables of its chains; a variable a line names must be set.
for v in $(grep -Eoh '\$[A-Z][A-Z0-9_]*' "$CORPUS" | tr -d '$' | sort -u); do
  [ -n "${!v-}" ] || export "$v=http://127.0.0.1:1"
done

# run_line <line>: whether `run` sent it to forge, as exactly one `forge script` call. A hostile line
# may also leave $MARK.
run_line() {
  local net=net
  # A rehearsal network's line runs on that network, the only one whose records it may move.
  if [[ $1 =~ ^FOUNDRY_BROADCAST=deployments/(rehearsal-[a-z0-9-]+)/broadcast\ FOUNDRY_CACHE_PATH= ]]; then
    net=${BASH_REMATCH[1]}; mkdir -p "deployments/$net"; cp deployments/net/network.json "deployments/$net/"
  fi
  printf '%s\n' "$1" >plan; : >calls; rm -f MARK
  node "${RUNNER:-$HERE/../../bin/sprue.mjs}" run "$net" t >out 2>&1 </dev/null || true
  [ -s calls ] || return 1
  [ "$(wc -l <calls)" = 1 ] && [[ $(<calls) == '[script]['* && $(<calls) == *'[--broadcast][--unlocked]' ]] \
    || { echo "FAIL not one forge script argv: $(<calls)" >&2; fail=$((fail + 1)); }
}

fail=0 total=0
while IFS= read -r line; do
  total=$((total + 1))
  run_line "$line" && [ ! -e MARK ] || { fail=$((fail + 1)); echo "FAIL not sent: $line" >&2; }
done <"$CORPUS"

# Each payload is added to a real line at two of five places, rotating through the corpus.
mapfile -t lines <"$CORPUS"
payloads=(
  "; touch \$MARK" ";touch \$MARK" "&& touch \$MARK" "|| touch \$MARK" "| touch \$MARK" "& touch \$MARK"
  "\$(touch \$MARK)" '`touch $MARK`' "> \$MARK" "' ; touch \$MARK ; '" '"' '\' ' --broadcast'
  ' --private-key 0x1' ' --unlocked' ' --rpc-url http://evil' ' #' '*' ' --sender 0xdead' '~' ' --slow --slow'
  ' -- x' ' ' $'\t'
)
i=0
for p in "${payloads[@]}"; do
  l=${lines[i % ${#lines[@]}]}
  places=("$l$p" "$p$l" "${l/ --sender/$p --sender}" "${l/forge script/forge script$p}" "${l/forge script/forge$p script}")
  for hostile in "${places[i % 5]}" "${places[(i + 2) % 5]}"; do
    total=$((total + 1))
    if run_line "$hostile" || [ -e MARK ]; then
      fail=$((fail + 1)); echo "FAIL ran hostile: $hostile" >&2
    fi
  done
  i=$((i + 1))
done
# An environment assignment other than a chain's RPC variable could redirect `forge` itself, and only
# a rehearsal network's lines move its records and resume data, both of them.
for prefix in 'PATH=$PWD ' 'FOO_RPC=$PATH ' 'X_RPC=$X ' 'L2_RPC=$L2_RPC PATH=$PWD ' \
  'FOUNDRY_BROADCAST=deployments/net/broadcast FOUNDRY_CACHE_PATH=deployments/net/cache '; do
  total=$((total + 1))
  if run_line "$prefix${lines[0]}" || [ -e MARK ]; then
    fail=$((fail + 1)); echo "FAIL ran hostile: $prefix${lines[0]}" >&2
  fi
done
rehearsalLine=$(grep -m1 '^FOUNDRY_BROADCAST=' "$CORPUS" || true)
cacheAssignment=$(grep -o 'FOUNDRY_CACHE_PATH=[^ ]* ' <<<"$rehearsalLine" || true)
for hostile in "${rehearsalLine/"$cacheAssignment"/}" "${rehearsalLine/\/cache /\/elsewhere }"; do
  total=$((total + 1))
  if [ -z "$cacheAssignment" ] || run_line "$hostile" || [ -e MARK ]; then
    fail=$((fail + 1)); echo "FAIL ran hostile: $hostile" >&2
  fi
done
# A variable that holds whitespace or a flag stays one argument of the command.
for var in R DEPLOYER; do
  total=$((total + 1))
  saved=${!var}
  using=$(grep -m1 "\\\$$var\b" "$CORPUS" || true)
  [ -n "$using" ] || continue
  export "$var=$saved --ffi"
  if { run_line "$using" && [[ $(<calls) == *'[--ffi]'* ]]; } || [ -e MARK ]; then
    fail=$((fail + 1)); echo "FAIL $var holding whitespace added an argument: $(<calls)" >&2
  fi
  export "$var=$saved"
done
# An unset variable would drop its argument and shift the next flag into its place.
total=$((total + 1))
using=$(grep -m1 -e '--rpc-url \$B_RPC' "$CORPUS" || true)
if [ -n "$using" ] && { (unset B_RPC; run_line "$using"); }; then
  fail=$((fail + 1)); echo "FAIL ran with B_RPC unset" >&2
fi
# Plan lines carry the paths unquoted, so a path that a shell would act on is refused.
for bad in 'deployments(archive)' 'deployments$archive'; do
  total=$((total + 1))
  cp sprue.json sprue.json.ok
  sed -i.bak "s|\"graph\":\"script/G.s.sol\"|\"graph\":\"script/$bad.s.sol\"|" sprue.json && rm sprue.json.bak
  rc=0; node "${RUNNER:-$HERE/../../bin/sprue.mjs}" run net t >out 2>&1 </dev/null || rc=$?
  { [ "$rc" = 2 ] && grep -q 'nonempty strings using only A-Z' out; } || { fail=$((fail + 1)); echo "FAIL a path of $bad exited $rc: $(<out)" >&2; }
  mv sprue.json.ok sprue.json
done
# A line JavaScript ends at U+2028 is still one plan line, and refused: dropped, the plan would look
# empty and the target reached.
total=$((total + 1))
printf '%s\n' $'# unexpected\u2028payload' >plan
rc=0; node "${RUNNER:-$HERE/../../bin/sprue.mjs}" run net t >out 2>&1 </dev/null || rc=$?
[ "$rc" = 2 ] || { fail=$((fail + 1)); echo "FAIL a U+2028 plan line exited $rc, not 2" >&2; }
echo "$total cases, $fail wrong"
[ "$fail" = 0 ]

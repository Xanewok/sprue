#!/usr/bin/env bash
# `run` sends every command line that Graph._command prints, and runs nothing else. Usage:
# plan-grammar.sh <file of real command lines>. Needs jq and git; forge and cast are stubs.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CORPUS=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

mkdir -p "$W/bin" "$W/deployments/net" "$W/script"
cd "$W"
git init -q
printf 'deployments/fork-test*/\n' >.gitignore
cat >sprue.json <<'JSON'
{"paths":{"graph":"script/G.s.sol","units":"script/units","deployments":"deployments","rehearsal":"deployments/fork-test"},
 "chains":{"default":"l2","local":[31337],"test":[],"unrecordedDeploys":{}}}
JSON
echo '{"chains":{"l2":{"id":31337}}}' >deployments/net/network.json
echo '{"nodes":[{"id":"t","unit":"u"}]}' >script/graph.generated.json
cat >bin/forge <<'STUB'
#!/bin/sh
case " $* " in
  *" plan(string,string) "*) sed 's/^/PLAN /' "$PLAN_FILE" ;;
  *) echo "$*" >>"$CALLS" ;;
esac
STUB
cat >bin/cast <<'STUB'
#!/bin/sh
case $1 in rpc) echo '"anvil/v1"' ;; chain-id) echo 31337 ;; esac
STUB
chmod +x bin/forge bin/cast
export PATH=$W/bin:$PATH PLAN_FILE=$W/plan CALLS=$W/calls R=http://127.0.0.1:1 DEPLOYER=0x1111111111111111111111111111111111111111 MARK=$W/MARK

# run_line <line>: whether `run` sent it to forge. A hostile line may also leave $MARK.
run_line() {
  printf '%s\n' "$1" >plan; : >calls; rm -f MARK
  sh "${GRAPH_SH:-$HERE/../bin/graph.sh}" run net t >out 2>&1 </dev/null || true
  [ -s calls ]
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
# An environment assignment other than a chain's RPC variable could redirect `forge` itself.
for prefix in 'PATH=$PWD ' 'FOO_RPC=$PATH ' 'X_RPC=$X ' 'L2_RPC=$L2_RPC PATH=$PWD '; do
  total=$((total + 1))
  if run_line "$prefix${lines[0]}" || [ -e MARK ]; then
    fail=$((fail + 1)); echo "FAIL ran hostile: $prefix${lines[0]}" >&2
  fi
done
# An unquoted variable that holds whitespace would add flags to the command.
for var in R DEPLOYER; do
  total=$((total + 1))
  saved=${!var}
  using=$(grep -m1 "\\\$$var\b" "$CORPUS" || true)
  [ -n "$using" ] || continue
  export "$var=$saved --ffi"
  if run_line "$using" || [ -e MARK ]; then
    fail=$((fail + 1)); echo "FAIL ran with $var holding whitespace" >&2
  fi
  export "$var=$saved"
done
echo "$total cases, $fail wrong"
[ "$fail" = 0 ]

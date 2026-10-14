# Changelog

## Unreleased

A rehearsal network keeps forge's records in `<paths.deployments>/<network>/broadcast`: its
commands start with `FOUNDRY_BROADCAST=` that path and its units read records only there. A send
whose records forge would write elsewhere than its units read is refused, on any network. A
rehearsal on a fork that keeps a public chain id no longer leaves records that the real run reads
as a lost journal.

## 0.1.1

The runner is `bin/sprue.mjs`, Node 18 or later with no dependencies, and replaces `bin/graph.sh`:
run it as `node lib/sprue/bin/sprue.mjs` (forge install) or `npx sprue` (npm). It needs no `sh` or
`jq` and starts no shell; Windows without WSL is not yet tested. A plan line becomes the argv of one
`forge script`, so a variable that holds whitespace is one argument instead of a refusal; an unset
variable in a line's arguments is refused.

## 0.1.0

First release: the deploy graph (`Graph`, `FileGraph`, `Unit`), the `graph.sh` runner and the
`@xanewok/sprue` npm package.

The journal format has no version field yet, and the API may change in a 0.x release.

The `v0.1.0` tag first pointed at an earlier commit. Moving from it: `ForgeBroadcasts.Create.at` is
now `addr` (`at` is a keyword from solc 0.8.36), and a `graph.sh` plan line must match the command
grammar in full.

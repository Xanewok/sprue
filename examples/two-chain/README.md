# two-chain

Two chains with different ids. `source` deploys a `Source` on the default chain. `receiver` then opens
windows 0, 1 and 2 on a `Receiver` that already exists on the second chain, each at its own date on that
chain's clock, recording the `Source` address.

```
sprue.json                              chains.default is source; 31337 and 31338 are local
deployments/local/network.json          the network's two chains, source and receiver
deployments/local/receiver.input.json   the Receiver's address, and openAt: the first window's date
script/deploy/units/source/             Source, and its steps: deploy, check
script/deploy/units/receiver/           Receiver, and its steps: notify.0, notify.1, notify.2
```

`receiver.notify.<i>` is `.on("receiver").reads("source").ownsForks().withArg(i)` with a `.gateView`. It
selects both chains itself, so its command passes no `--rpc-url`: it reads each chain's `rpc` alias.
Its date view `windowStart` leaves the receiver chain selected, so the graph compares
the date with that chain's clock.

The `Receiver` is deployed outside the graph, and the second-chain step only calls it.

## Run it on two Anvils

Copy this directory out of the sprue checkout, then:

```sh
git init && forge install foundry-rs/forge-std Xanewok/sprue@v0.1.3
anvil --port 8545 --chain-id 31337 &
anvil --port 8546 --chain-id 31338 &
export DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
forge create script/deploy/units/receiver/Receiver.sol:Receiver --rpc-url receiver --unlocked --from $DEPLOYER --broadcast
G="node lib/sprue/bin/sprue.mjs"
$G plan local receiver.notify.2
$G run local receiver.notify.2
cast call 0x5FbDB2315678afecb367f032d93F642f64180aa3 'opened(uint8)(address)' 2 --rpc-url receiver
```

1. `forge create` puts the `Receiver` on the second chain. As account 0's first transaction there, it
   lands at the address `receiver.input.json` names.
2. `plan` prints the source's steps, then `# then plan again`: the notify steps need the checked source.
3. `run` deploys and checks the `Source` on chain 31337, then sends each `notify` to chain 31338.
4. `cast call` shows window 2 holds the `Source` address.

On Anvil, `sprue` sets the receiver chain's own clock to each window's date, so one `run` opens the
windows in order and leaves the source chain's clock alone. On a node that is not Anvil it exits 4 until
that chain's clock reaches the date.

## For a real network

- Add a network with both chains' ids, and give each chain an `rpc` alias from `foundry.toml`'s
  `[rpc_endpoints]`; list the ids in `sprue.json`'s `chains.test` (or leave them unlisted for a live
  chain).
- Deploy your receiver on its chain, and put its address and the first date in `receiver.input.json`.
- A non-local `run` is attended ([Your own project](https://github.com/Xanewok/sprue#your-own-project), step 7).

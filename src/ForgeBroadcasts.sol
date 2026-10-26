// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {Journal, slashed} from "./Journal.sol";

/// @dev A cheatcode that forge 1.8 provides and the forge-std this library builds against does not
///      declare.
interface VmRpcJson {
    function rpcJson(string calldata method, string calldata params) external returns (string memory);
}

/// @dev The only Solidity reader of forge's `broadcast/` records in this library. They are the evidence a
///      lost journal is rebuilt from: `broadcast/<script>/<chain id>/<step>-latest.json`, the
///      timestamped records beside it, and multi-chain records under `broadcast/multi/`, whose runs
///      sit in `.deployments[]`. A transaction's hash in a record is only a candidate, because older
///      forge versions ordered `transactions[].hash` by the order the sends returned. The receipts
///      name the right one.
abstract contract ForgeBroadcasts is Journal {
    function _txInput(Create memory c) internal pure returns (bytes memory) {
        return vm.parseJsonBytes(c.record, string.concat(c.key, ".transaction.input"));
    }

    /// @dev The commit of `c`'s run, if the record has one. `_recordReceipt` reads a commit only from
    ///      the top level of a single-chain record.
    function _commit(Create memory c) internal view returns (bool, string memory) {
        return _commitAt(c.record, string.concat(c.run, ".commit"));
    }

    /// @dev Forge writes `null` for a run outside git. That must stay `pending`, never the string
    ///      "null": a journal's commit is hex or `pending`.
    function _commitAt(string memory record, string memory key) internal view returns (bool, string memory commit) {
        if (!_has(record, key)) return (false, "");
        commit = vm.parseJsonString(record, key);
        if (keccak256(bytes(commit)) == keccak256("null")) return (false, "");
        return (true, commit);
    }

    function _hasTransaction(Create memory c, uint256 j) internal view returns (bool) {
        return _has(c.record, string.concat(c.run, ".transactions[", vm.toString(j), "]"));
    }

    /// @dev Transaction `j`'s recorded hash; `ok` is false for one that does not parse. Read one at a
    ///      time so a caller that finds its match stops parsing.
    function _candidateHash(Create memory c, uint256 j) internal view returns (bool ok, bytes32 hash) {
        try vm.parseJsonBytes32(c.record, string.concat(c.run, ".transactions[", vm.toString(j), "].hash")) returns (
            bytes32 h
        ) {
            return (true, h);
        } catch {
            return (false, 0);
        }
    }

    struct Create {
        /// @dev A factory call forge recorded as `CREATE2`: no nonce fixes its address.
        bool create2;
        address addr;
        address from;
        uint256 nonce;
        string path;
        string record;
        /// @dev The run's and the transaction's paths within `record`.
        string run;
        string key;
        /// @dev The current inputs' constructor arguments, set by `_requireCurrent`.
        bytes args;
    }

    /// @dev Every CREATE and CREATE2 of `artifact` that this chain's broadcast records hold, by any
    ///      sender. An unreadable record is refused, as one that may hold it. A missing records
    ///      directory holds none.
    function _creates(string memory artifact) internal view returns (Create[] memory found) {
        if (!vm.exists(_records())) return found;
        VmSafe.DirEntry[] memory files = vm.readDir(_records(), 3);
        for (uint256 i; i < files.length; ++i) {
            require(
                bytes(files[i].errorMessage).length == 0,
                string.concat("cannot rule out a stray ", artifact, ": ", files[i].errorMessage)
            );
            if (files[i].isDir || files[i].depth != 3 || !_endsWith(files[i].path, ".json")) continue;
            string memory path = slashed(files[i].path);
            string memory record = vm.readFile(path);
            if (_has(record, ".chain")) {
                found = _createsIn(found, artifact, path, record, "");
                continue;
            }
            // A multi-chain run's record holds one run per chain.
            require(
                _has(record, ".deployments"),
                string.concat("cannot rule out a stray ", artifact, ": ", path, " names no chain")
            );
            for (uint256 k; _has(record, string.concat(".deployments[", vm.toString(k), "]")); ++k) {
                found = _createsIn(found, artifact, path, record, string.concat(".deployments[", vm.toString(k), "]"));
            }
        }
    }

    /// @dev Matches the chain id written inside the run, not the chain directory in the path,
    ///      because path separators differ between hosts.
    function _createsIn(
        Create[] memory found,
        string memory artifact,
        string memory path,
        string memory record,
        string memory run
    ) private view returns (Create[] memory) {
        if (_uint(record, string.concat(run, ".chain")) != block.chainid) return found;
        for (uint256 j; _has(record, string.concat(run, ".transactions[", vm.toString(j), "]")); ++j) {
            string memory t = string.concat(run, ".transactions[", vm.toString(j), "]");
            if (!_isCreateOf(record, t, artifact)) continue;
            Create[] memory more = new Create[](found.length + 1);
            for (uint256 n; n < found.length; ++n) {
                more[n] = found[n];
            }
            more[found.length] = Create({
                create2: keccak256(bytes(vm.parseJsonString(record, string.concat(t, ".transactionType"))))
                    == keccak256("CREATE2"),
                addr: _addr(record, string.concat(t, ".contractAddress")),
                from: _addr(record, string.concat(t, ".transaction.from")),
                nonce: _uint(record, string.concat(t, ".transaction.nonce")),
                path: path,
                record: record,
                run: run,
                key: t,
                args: ""
            });
            found = more;
        }
        return found;
    }

    function _endsWith(string memory s, string memory suffix) internal pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory end = bytes(suffix);
        if (b.length < end.length) return false;
        for (uint256 i; i < end.length; ++i) {
            if (b[b.length - end.length + i] != end[i]) return false;
        }
        return true;
    }

    function _isCreateOf(string memory record, string memory t, string memory artifact) private view returns (bool) {
        bytes32 kind = keccak256(bytes(vm.parseJsonString(record, string.concat(t, ".transactionType"))));
        if (kind != keccak256("CREATE") && kind != keccak256("CREATE2")) return false;
        // A CREATE forge could not attribute has a null name.
        try vm.parseJsonString(record, string.concat(t, ".contractName")) returns (string memory name) {
            return keccak256(bytes(name)) == keccak256(bytes(artifact));
        } catch {
            return false;
        }
    }

    /// @dev The deploy run cannot see its own receipt, because forge writes it under `broadcast/`
    ///      after the run returns. So a later run of the step, or `check`, with `deployed`'s chain
    ///      selected, records the receipt that this chain confirms created `deployed` (`_findReceipt`).
    ///
    ///      A `pending` commit, the label a unit records, becomes the commit forge sent from.
    function _recordReceipt(string memory journal, string memory role, address deployed) internal {
        _recordReceipt(journal, role, deployed, false);
    }

    /// @dev A CREATE2 receipt names no created address: the factory call whose salt and initcode
    ///      fix `deployed` succeeded at most once, since the factory reverts on an occupied address.
    function _recordCreate2Receipt(string memory journal, string memory role, address deployed) internal {
        _recordReceipt(journal, role, deployed, true);
    }

    function _recordReceipt(string memory journal, string memory role, address deployed, bool create2) private {
        // forge writes a send's record after the run, so a probe would find its receipt and plan the step
        // again after every send. The step's next run, or `check`, journals it.
        if (_inProbe()) return;
        // A recorded receipt is final. A rerun must not replace the transaction or block the journal
        // names.
        if (_has(journal, string.concat(".", role, "Tx")) && _has(journal, string.concat(".", role, "Block"))) {
            return;
        }
        (bytes32 hash, uint256 landed, string memory record) = _findReceipt(journal, role, deployed, create2);
        if (landed == 0) {
            console.log("neither a local receipt under broadcast/ nor the chain shows the creation of", role);
            return;
        }
        _put(string.concat(".", role, "Tx"), vm.toString(hash));
        _put(string.concat(".", role, "Block"), vm.toString(landed));
        if (bytes(record).length != 0) _settleCommit(journal, role, record);
    }

    /// @dev The transaction that created `deployed`, the block it landed in (zero if none is found) and
    ///      the broadcast record that holds it (empty if only the chain does). Only `receipts[]` names
    ///      the right hash: older forge versions wrote a batch's hashes into `transactions[]` in the
    ///      order the sends returned. With no record, as after a killed forge, a CREATE is searched for
    ///      on the chain by the journal's deployer and nonce.
    function _findReceipt(string memory journal, string memory role, address deployed, bool create2)
        internal
        returns (bytes32 hash, uint256 landed, string memory record)
    {
        string memory candidates = create2
            ? string.concat(
                "$..receipts[?(@.to == '", vm.toLowercase(vm.toString(CREATE2_FACTORY)), "')].transactionHash"
            )
            : string.concat(
                "$..receipts[?(@.contractAddress == '", vm.toLowercase(vm.toString(deployed)), "')].transactionHash"
            );
        if (vm.exists(_records())) {
            try vm.readDir(_records(), 3) returns (VmSafe.DirEntry[] memory files) {
                for (uint256 i; i < files.length; ++i) {
                    if (files[i].isDir || !_endsWith(files[i].path, ".json")) continue;
                    record = vm.readFile(files[i].path);
                    // A multi-chain run can create the same address on two chains.
                    bytes32[] memory sent = _matches(record, candidates);
                    for (uint256 j; j < sent.length; ++j) {
                        landed = _createdIn(sent[j], deployed, create2);
                        if (landed != 0) return (sent[j], landed, record);
                    }
                }
            } catch {}
        }
        string memory key = string.concat(".", role);
        // An adopted role, which this project did not create, has no nonce.
        if (create2 || !_has(journal, string.concat(key, "Deployer")) || !_has(journal, string.concat(key, "Nonce"))) {
            return (0, 0, "");
        }
        hash = _sentAt(_addr(journal, string.concat(key, "Deployer")), _uint(journal, string.concat(key, "Nonce")));
        landed = hash == 0 ? 0 : _createdIn(hash, deployed, false);
        record = "";
    }

    /// @dev The hash of `deployer`'s transaction at `nonce`, as the chain shows it, or zero while the
    ///      nonce is unused. Zero too with no RPC, or for a transaction older than the state the RPC keeps.
    function _sentAt(address deployer, uint256 nonce) private returns (bytes32) {
        // The chain's, not the simulation's: a deployment this run simulated has no transaction. And
        // `block.number` can be a rollup's parent chain's number.
        uint256 hi;
        try vm.rpc("eth_blockNumber", "[]") returns (bytes memory head) {
            hi = _rpcUint(head);
        } catch {
            // No RPC, as under `forge test`.
            return 0;
        }
        (bool landed, uint256 sent) = _nonceAt(deployer, hi);
        if (!landed || sent <= nonce) return 0;
        // Invariant: `deployer`'s nonce at `hi` is past `nonce`, and at `lo` is not or is not served. A
        // block whose state the RPC no longer keeps counts as before the transaction: the scan below checks.
        uint256 lo;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (bool ok, uint256 used) = _nonceAt(deployer, mid);
            if (ok && used > nonce) hi = mid;
            else lo = mid;
        }
        string memory blockJson;
        try VmRpcJson(address(vm)).rpcJson("eth_getBlockByNumber", string.concat('["', _hex(hi), '", true]')) returns (
            string memory found
        ) {
            blockJson = found;
        } catch {
            return 0;
        }
        for (uint256 i; _has(blockJson, string.concat(".transactions[", vm.toString(i), "]")); ++i) {
            string memory t = string.concat(".transactions[", vm.toString(i), "]");
            if (
                _addr(blockJson, string.concat(t, ".from")) == deployer
                    && _uint(blockJson, string.concat(t, ".nonce")) == nonce
            ) {
                return vm.parseJsonBytes32(blockJson, string.concat(t, ".hash"));
            }
        }
        return 0;
    }

    function _nonceAt(address account, uint256 blockNumber) private returns (bool, uint256) {
        try vm.rpc(
            "eth_getTransactionCount", string.concat('["', vm.toString(account), '", "', _hex(blockNumber), '"]')
        ) returns (
            bytes memory count
        ) {
            return (true, _rpcUint(count));
        } catch {
            return (false, 0);
        }
    }

    function _rpcUint(bytes memory word) private pure returns (uint256) {
        return uint256(bytes32(word)) >> (8 * (32 - word.length));
    }

    /// @dev A JSON-RPC quantity: hex without leading zeros.
    function _hex(uint256 x) private pure returns (string memory) {
        bytes memory digits = bytes(vm.toString(bytes32(x)));
        uint256 start = 2;
        while (start < 65 && digits[start] == "0") ++start;
        bytes memory out = new bytes(digits.length - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = digits[start + i];
        }
        return string.concat("0x", string(out));
    }

    /// @dev The input of the chain's transaction `hash`, whose receipt the chain showed. Virtual only
    ///      so a test with no RPC can supply it.
    function _sentInput(bytes32 hash) internal virtual returns (bytes memory) {
        string memory sent =
            VmRpcJson(address(vm)).rpcJson("eth_getTransactionByHash", string.concat('["', vm.toString(hash), '"]'));
        require(
            _has(sent, ".input"),
            string.concat(
                "the RPC shows the receipt of ",
                vm.toString(hash),
                " but not the transaction: if it lags behind the chain, run again once it shows it"
            )
        );
        return vm.parseJsonBytes(sent, ".input");
    }

    function _settleCommit(string memory journal, string memory role, string memory record) private {
        string memory key = string.concat(".", role, "Commit");
        (bool has, string memory commit) = _commitAt(record, ".commit");
        if (has && _has(journal, key) && keccak256(bytes(vm.parseJsonString(journal, key))) == keccak256("pending")) {
            _put(key, string.concat('"', commit, '"'));
        }
    }

    /// @dev forge returns no match as no bytes, one as itself and several as an array.
    function _matches(string memory json, string memory path) private pure returns (bytes32[] memory hashes) {
        bytes memory found = vm.parseJson(json, path);
        if (found.length != 32) return found.length == 0 ? hashes : abi.decode(found, (bytes32[]));
        hashes = new bytes32[](1);
        hashes[0] = bytes32(found);
    }

    /// @dev The block in which `txHash` created `deployed` on the selected chain, or zero. A
    ///      candidate from another chain has no receipt here, or one the node refuses to serve.
    ///      Virtual only so a test with no RPC can confirm a receipt.
    function _createdIn(bytes32 txHash, address deployed, bool create2) internal virtual returns (uint256) {
        string memory hash = string.concat('["', vm.toString(txHash), '"]');
        try VmRpcJson(address(vm)).rpcJson("eth_getTransactionReceipt", hash) returns (string memory receipt) {
            if (!_has(receipt, ".status") || _uint(receipt, ".status") != 1) return 0;
            if (create2) return _factoryCreated(hash) == deployed ? _uint(receipt, ".blockNumber") : 0;
            // A call's receipt names no created address.
            try vm.parseJsonAddress(receipt, ".contractAddress") returns (address created) {
                return created == deployed ? _uint(receipt, ".blockNumber") : 0;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    /// @dev The address that the factory call `hash` (input: `salt ++ initcode`) created, else zero.
    ///      The receipt names no created address, and a broadcast record is a local, editable file.
    ///      So the address is computed from what the chain says was sent to the factory.
    function _factoryCreated(string memory hash) private returns (address) {
        string memory sent = VmRpcJson(address(vm)).rpcJson("eth_getTransactionByHash", hash);
        try vm.parseJsonAddress(sent, ".to") returns (address to) {
            if (to != CREATE2_FACTORY) return address(0);
        } catch {
            return address(0);
        }
        bytes memory input = vm.parseJsonBytes(sent, ".input");
        if (input.length < 32) return address(0);
        bytes32 salt;
        bytes32 initcodeHash;
        assembly ("memory-safe") {
            salt := mload(add(input, 0x20))
            initcodeHash := keccak256(add(input, 0x40), sub(mload(input), 0x20))
        }
        return vm.computeCreate2Address(salt, initcodeHash, CREATE2_FACTORY);
    }
}

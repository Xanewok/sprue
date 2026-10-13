// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {Journal} from "./Journal.sol";

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
            string memory record = vm.readFile(files[i].path);
            if (_has(record, ".chain")) {
                found = _createsIn(found, artifact, files[i].path, record, "");
                continue;
            }
            // A multi-chain run's record holds one run per chain.
            require(
                _has(record, ".deployments"),
                string.concat("cannot rule out a stray ", artifact, ": ", files[i].path, " names no chain")
            );
            for (uint256 k; _has(record, string.concat(".deployments[", vm.toString(k), "]")); ++k) {
                found = _createsIn(
                    found, artifact, files[i].path, record, string.concat(".deployments[", vm.toString(k), "]")
                );
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

    /// @dev The directory of broadcast records, with `<script>/<chain id>/<step>-latest.json`
    ///      beneath it. `forge test` writes none, so a test keeps its own under its network
    ///      directory, where no local run's record for the same chain id can reach it.
    function _records() internal view returns (string memory) {
        return vm.isContext(VmSafe.ForgeContext.Test) ? string.concat(_dir(), "/broadcast") : "broadcast";
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
    ///      selected, records the receipt there that this chain confirms created `deployed`. Only
    ///      `receipts[]` names the right hash: older forge versions wrote a batch's hashes into
    ///      `transactions[]` in the order the sends returned.
    ///
    ///      A `pending` commit, the label a unit records, becomes the commit forge sent from.
    function _recordReceipt(string memory journal, string memory role, address deployed) internal {
        string memory created = string.concat(
            "$..receipts[?(@.contractAddress == '", vm.toLowercase(vm.toString(deployed)), "')].transactionHash"
        );
        _recordReceipt(journal, role, created, deployed, false);
    }

    /// @dev A CREATE2 receipt names no created address: the factory call whose salt and initcode
    ///      fix `deployed` succeeded at most once, since the factory reverts on an occupied address.
    function _recordCreate2Receipt(string memory journal, string memory role, address deployed) internal {
        string memory sent = string.concat(
            "$..receipts[?(@.to == '", vm.toLowercase(vm.toString(CREATE2_FACTORY)), "')].transactionHash"
        );
        _recordReceipt(journal, role, sent, deployed, true);
    }

    function _recordReceipt(
        string memory journal,
        string memory role,
        string memory candidates,
        address deployed,
        bool create2
    ) private {
        // A recorded receipt is final. A rerun must not replace the transaction or block the journal
        // names.
        if (_has(journal, string.concat(".", role, "Tx")) && _has(journal, string.concat(".", role, "Block"))) {
            return;
        }

        if (vm.exists(_records())) {
            try vm.readDir(_records(), 3) returns (VmSafe.DirEntry[] memory files) {
                for (uint256 i; i < files.length; ++i) {
                    if (files[i].isDir || !_endsWith(files[i].path, ".json")) continue;
                    string memory record = vm.readFile(files[i].path);
                    // A multi-chain run can create the same address on two chains.
                    bytes32[] memory sent = _matches(record, candidates);
                    for (uint256 j; j < sent.length; ++j) {
                        uint256 landed = _createdIn(sent[j], deployed, create2);
                        if (landed == 0) continue;
                        _put(string.concat(".", role, "Tx"), vm.toString(sent[j]));
                        _put(string.concat(".", role, "Block"), vm.toString(landed));
                        _settleCommit(journal, role, record);
                        return;
                    }
                }
            } catch {}
        }
        console.log("no local receipt under broadcast/ creates the journal", role);
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

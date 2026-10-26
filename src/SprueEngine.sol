// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {chainId, planRpc} from "./Chains.sol";
import {ForgeBroadcasts, VmRpcJson} from "./ForgeBroadcasts.sol";
import {isRehearsalNetwork, outputsEnv, slashed} from "./Journal.sol";

/// @dev What the engine needs of the unit that calls it, as its first argument: the engine keeps no state, so
///      each call carries the unit's view of the run. `host` is set only under `forge test`, where a unit
///      may answer the engine's test hooks; a script may not use its own address.
struct Ctx {
    address host;
    string unit;
    string deployments;
    string network;
    string script;
    string defaultChain;
    string selected;
    bool fenced;
    bool rehearsal;
    bool probing;
}

/// @dev The engine's answers to a unit's test hooks, which stand in for the RPC under `forge test`.
interface ITestHooks {
    function sprueCreatedIn(bytes32 txHash, address deployed, bool create2) external returns (uint256);
    function sprueSentInput(bytes32 txHash) external returns (bytes memory);
}

/// @dev `SprueEngine`'s entry points as a unit calls them: declared `view`, so that each call is a static call,
///      which forge never records as a broadcast transaction, whatever the engine reads or writes.
interface ISprueEngine {
    function requireNoStray(
        Ctx calldata ctx,
        string calldata journal,
        string calldata role,
        string calldata artifact,
        address adopted
    ) external view;
    function requireNoUnjournaled(Ctx calldata ctx, string calldata journal, string calldata role, address sender)
        external
        view;
    function hasRecoverStep(Ctx calldata ctx) external view returns (bool);
    function recordReceipt(
        Ctx calldata ctx,
        string calldata journal,
        string calldata role,
        address deployed,
        bool create2
    ) external view;
    function findReceipt(
        Ctx calldata ctx,
        string calldata journal,
        string calldata role,
        address deployed,
        bool create2
    ) external view returns (bytes32, uint256, string memory);
    function createToRecover(
        Ctx calldata ctx,
        string calldata journal,
        string calldata role,
        string calldata artifact,
        address sender,
        bytes32 initcodeHash
    ) external view returns (ForgeBroadcasts.Create memory);
    function requireCurrent(
        Ctx calldata ctx,
        ForgeBroadcasts.Create calldata found,
        string calldata artifact,
        bytes calldata args
    ) external view returns (ForgeBroadcasts.Create memory);
    function journalRecovered(
        Ctx calldata ctx,
        string calldata journal,
        string[2][] calldata roles,
        ForgeBroadcasts.Create[] calldata found
    ) external view;
}

/// @notice The heavy, rarely executed part of a unit: the scans of forge's broadcast records, the stray and
///         fence guards, receipts and recovery. A unit places it at one address with `vm.etch` and calls it
///         with a static call, so no unit carries the code and no call is a broadcast transaction.
/// @dev Stateless: every external function takes `Ctx` first, and reads it back from calldata.
contract SprueEngine is ForgeBroadcasts {
    function _ctx() private pure returns (Ctx memory) {
        return abi.decode(msg.data[4:], (Ctx));
    }

    function _unit() internal pure override returns (string memory) {
        return _ctx().unit;
    }

    function _deployments() internal pure override returns (string memory) {
        return _ctx().deployments;
    }

    function _graphScript() internal pure override returns (string memory) {
        revert("the engine names no graph script");
    }

    function _deployScript() internal pure override returns (string memory) {
        return _ctx().script;
    }

    function _defaultChain(string memory) internal pure override returns (string memory) {
        return _ctx().defaultChain;
    }

    function _selectedChain() internal pure override returns (string memory) {
        return _ctx().selected;
    }

    function _networkName() internal pure override returns (string memory) {
        return _ctx().network;
    }

    function _fenced() internal pure override returns (bool) {
        return _ctx().fenced;
    }

    function _rehearsal() internal pure override returns (bool) {
        return _ctx().rehearsal;
    }

    function _inProbe() internal pure override returns (bool) {
        return _ctx().probing;
    }

    function _createdIn(bytes32 txHash, address deployed, bool create2) internal override returns (uint256) {
        address host = _ctx().host;
        return host == address(0)
            ? super._createdIn(txHash, deployed, create2)
            : ITestHooks(host).sprueCreatedIn(txHash, deployed, create2);
    }

    function _sentInput(bytes32 txHash) internal override returns (bytes memory) {
        address host = _ctx().host;
        return host == address(0) ? super._sentInput(txHash) : ITestHooks(host).sprueSentInput(txHash);
    }

    // ==== Entry points ====

    function requireNoStray(
        Ctx calldata,
        string calldata journal,
        string calldata role,
        string calldata artifact,
        address adopted
    ) external view {
        _requireNoStray(journal, role, artifact, adopted);
    }

    function requireNoUnjournaled(Ctx calldata, string calldata journal, string calldata role, address sender)
        external
        view
    {
        _requireNoUnjournaled(journal, role, sender);
    }

    function hasRecoverStep(Ctx calldata) external view returns (bool) {
        return _hasRecoverStep();
    }

    function recordReceipt(
        Ctx calldata,
        string calldata journal,
        string calldata role,
        address deployed,
        bool create2
    ) external {
        _recordReceipt(journal, role, deployed, create2);
    }

    function findReceipt(
        Ctx calldata,
        string calldata journal,
        string calldata role,
        address deployed,
        bool create2
    ) external returns (bytes32, uint256, string memory) {
        return _findReceipt(journal, role, deployed, create2);
    }

    function createToRecover(
        Ctx calldata,
        string calldata journal,
        string calldata role,
        string calldata artifact,
        address sender,
        bytes32 initcodeHash
    ) external returns (Create memory) {
        return _createToRecover(journal, role, artifact, sender, initcodeHash);
    }

    function requireCurrent(Ctx calldata, Create memory found, string calldata artifact, bytes calldata args)
        external
        returns (Create memory)
    {
        _requireCurrent(found, artifact, args);
        return found;
    }

    function journalRecovered(
        Ctx calldata,
        string calldata journal,
        string[2][] calldata roles,
        Create[] calldata found
    ) external {
        _journalRecovered(journal, roles, found);
    }

    // ==== Moved from `ForgeBroadcasts` and `Deployment` ====

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
            uint256 mark = _freeMemory();
            uint256 had = found.length;
            string memory path = slashed(files[i].path);
            string memory record = vm.readFile(path);
            if (_has(record, ".chain")) {
                found = _createsIn(found, artifact, path, record, "");
                if (found.length == had) _releaseMemory(mark);
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
            if (found.length == had) _releaseMemory(mark);
        }
    }

    function _freeMemory() private pure returns (uint256 at) {
        assembly ("memory-safe") {
            at := mload(0x40)
        }
    }

    /// @dev Frees everything allocated since `_freeMemory` returned `at`; the caller must reference none of it.
    ///      A scan of many records calls it after each record that yields nothing: a step never frees memory,
    ///      and its gas grows with the square of what it holds, so a dozen records would end a probe.
    function _releaseMemory(uint256 at) private pure {
        assembly ("memory-safe") {
            mstore(0x40, at)
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
        // One query for the whole run: a query per transaction copies the record each time.
        if (!_has(record, string.concat("$", run, ".transactions[?(@.contractName == '", artifact, "')]"))) {
            return found;
        }
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
    ///      order the sends returned. Only the unit's own script's records are read, its runs on this chain
    ///      and its multi-chain runs: the others grow with every unit and run, and a probe reads them under
    ///      the block gas limit. With no record, as after a killed forge or for a role another script created, a CREATE
    ///      is searched for on the chain by the journal's deployer and nonce.
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
        string[] memory script = vm.split(_deployScript(), "/");
        string memory name = script[script.length - 1];
        (hash, landed, record) = _receiptIn(
            string.concat(_records(), "/", name, "/", vm.toString(block.chainid)), 1, "", candidates, deployed, create2
        );
        if (landed != 0) return (hash, landed, record);
        // A multi-chain run's records: `multi/<script>-latest/` and `multi/<script>-<timestamp>/`.
        (hash, landed, record) = _receiptIn(
            string.concat(_records(), "/multi"), 2, string.concat("/", name, "-"), candidates, deployed, create2
        );
        if (landed != 0) return (hash, landed, record);
        string memory key = string.concat(".", role);
        // An adopted role, which this project did not create, has no nonce.
        if (create2 || !_has(journal, string.concat(key, "Deployer")) || !_has(journal, string.concat(key, "Nonce"))) {
            return (0, 0, "");
        }
        hash = _sentAt(_addr(journal, string.concat(key, "Deployer")), _uint(journal, string.concat(key, "Nonce")));
        landed = hash == 0 ? 0 : _createdIn(hash, deployed, false);
        record = "";
    }

    /// @dev The first receipt in the records `depth` levels under `dir`, in a path that contains `under`, whose
    ///      hash `candidates` selects and that this chain confirms created `deployed`.
    function _receiptIn(
        string memory dir,
        uint64 depth,
        string memory under,
        string memory candidates,
        address deployed,
        bool create2
    ) private returns (bytes32, uint256, string memory) {
        if (!vm.exists(dir)) return (0, 0, "");
        try vm.readDir(dir, depth) returns (VmSafe.DirEntry[] memory files) {
            for (uint256 i; i < files.length; ++i) {
                string memory path = slashed(files[i].path);
                if (files[i].isDir || files[i].depth != depth || !_endsWith(path, ".json")) continue;
                if (bytes(under).length != 0 && !vm.contains(path, under)) continue;
                uint256 mark = _freeMemory();
                string memory record = vm.readFile(path);
                // A multi-chain run can create the same address on two chains.
                bytes32[] memory sent = _matches(record, candidates);
                for (uint256 j; j < sent.length; ++j) {
                    uint256 landed = _createdIn(sent[j], deployed, create2);
                    if (landed != 0) return (sent[j], landed, record);
                }
                _releaseMemory(mark);
            }
        } catch {}
        return (0, 0, "");
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

    /// @dev For a role that `journal` lacks. A CREATE, or a CREATE2 factory call, of `artifact` in
    ///      this chain's broadcast records, by any sender, may be the role's lost record, and a fresh
    ///      deployment would then be a second one. Such a record is refused while it has code, or
    ///      while its nonce may still land, with or without a receipt. Only two kinds are ignored: a
    ///      record without code whose nonce is used elsewhere, and an address in the journal's
    ///      `retired` list. Another journal naming the address does not exempt it, because that
    ///      journal can outlive the lost one.
    function _requireNoStray(string memory journal, string memory role, string memory artifact) internal view {
        _requireNoStray(journal, role, artifact, address(0));
    }

    /// @dev `adopted`, a CREATE2 address the step is about to deploy or adopt, is that role itself.
    function _requireNoStray(string memory journal, string memory role, string memory artifact, address adopted)
        internal
        view
    {
        Create[] memory creates = _creates(artifact);
        for (uint256 i; i < creates.length; ++i) {
            Create memory c = creates[i];
            if (c.addr.code.length == 0 && vm.getNonce(c.from) > c.nonce) continue;
            if (c.create2 && c.addr == adopted) continue;
            require(
                _isRetired(journal, c.addr),
                string.concat(
                    _unit(),
                    ".json lacks ",
                    role,
                    ", yet ",
                    c.path,
                    c.create2 ? " holds a CREATE2 of " : " holds a CREATE of ",
                    artifact,
                    " at ",
                    vm.toString(c.addr),
                    " that landed or may land: restore the journal",
                    c.create2 || !_hasRecoverStep() ? "" : _recoverCommand(c)
                )
            );
        }
    }

    /// @dev Whether the unit's script compiled a `recover(string)` function, read from the ABIs under
    ///      `out/<script file>/`. False when that directory is absent, so a refusal never names a
    ///      command that cannot run.
    function _hasRecoverStep() internal view returns (bool) {
        string[] memory path = vm.split(_deployScript(), "/");
        string memory dir = string.concat("out/", path[path.length - 1]);
        if (!vm.exists(dir)) return false;
        VmSafe.DirEntry[] memory files = vm.readDir(dir);
        for (uint256 i; i < files.length; ++i) {
            if (!vm.exists(files[i].path) || files[i].isDir) continue;
            string memory abi_ = vm.readFile(files[i].path);
            if (!vm.keyExistsJson(abi_, ".abi")) continue;
            for (uint256 k; vm.keyExistsJson(abi_, string.concat(".abi[", vm.toString(k), "]")); ++k) {
                string memory entry = string.concat(".abi[", vm.toString(k), "]");
                if (
                    vm.keyExistsJson(abi_, string.concat(entry, ".name"))
                        && keccak256(bytes(vm.parseJsonString(abi_, string.concat(entry, ".name"))))
                            == keccak256("recover") && vm.keyExistsJson(abi_, string.concat(entry, ".inputs[0].type"))
                        && !vm.keyExistsJson(abi_, string.concat(entry, ".inputs[1]"))
                        && keccak256(bytes(vm.parseJsonString(abi_, string.concat(entry, ".inputs[0].type"))))
                            == keccak256("string")
                ) return true;
            }
        }
        return false;
    }

    function _recoverCommand(Create memory c) private view returns (string memory) {
        return string.concat(
            ", or rebuild it: ",
            isRehearsalNetwork(_networkName()) ? outputsEnv(_dir()) : "",
            "forge script ",
            _deployScript(),
            " --sig 'recover(string)' ",
            _networkName(),
            " --rpc-url ",
            planRpc(_networkJson()),
            " --sender ",
            vm.toString(c.from)
        );
    }

    /// @dev The most nonces of one deployer that `_requireNoUnjournaled` will scan for code. A
    ///      deployer past it is refused, not partly checked.
    uint256 internal constant FENCED_NONCES = 256;

    /// @dev For a role that `journal` lacks, on a `_fenced()` chain. Code at a CREATE address of
    ///      `sender`, of the pinned deployer, or of any deployer that a journal of this network
    ///      records may be this role's deployment whose journal and broadcast records are both lost,
    ///      and a fresh deployment would then be a second one. The code passes only if a journal has
    ///      a `<role>Deployer` key and records the address as `<role>` with `<role>CodeHash` equal to
    ///      the live code hash (`_journaled`), or if the journal's `retired` list names the address.
    ///      The deployer and nonce are not compared here: that relies on the journal having been
    ///      written by `_recordSender`. Another journal merely naming the address, as a dependency,
    ///      does not count. The code itself is not compared: no build can say what a lost
    ///      deployment's code was. On a chain where `_fenced()` is false this does nothing.
    function _requireNoUnjournaled(string memory journal, string memory role, address sender) internal view {
        if (!_fenced()) return;
        string[] memory journals = _journals();
        address pinned = _pinnedDeployer();
        if (sender != DEFAULT_SENDER) _requireNoUnjournaled(journal, role, sender, journals);
        if (pinned != address(0)) _requireNoUnjournaled(journal, role, pinned, journals);
        for (uint256 j; j < journals.length; ++j) {
            string[] memory keys = vm.parseJsonKeys(journals[j], "$");
            for (uint256 k; k < keys.length; ++k) {
                if (!_endsWith(keys[k], "Deployer")) continue;
                _requireNoUnjournaled(journal, role, _addr(journals[j], string.concat(".", keys[k])), journals);
            }
        }
    }

    function _requireNoUnjournaled(
        string memory journal,
        string memory role,
        address deployer,
        string[] memory journals
    ) private view {
        uint256 used = vm.getNonce(deployer);
        require(
            used <= FENCED_NONCES,
            string.concat(
                vm.toString(deployer),
                " has used more nonces than the fence reads: a person must account for its deployments, or use a fresh deploy key, or list the chain in chains.unrecordedDeploys[<id>]"
            )
        );
        for (uint256 n; n < used; ++n) {
            address addr = vm.computeCreateAddress(deployer, n);
            if (addr.code.length == 0 || _isRetired(journal, addr) || _journaled(journals, addr)) continue;
            revert(
                string.concat(
                    _unit(),
                    ".json lacks ",
                    role,
                    ", yet ",
                    vm.toString(addr),
                    ", the CREATE of ",
                    vm.toString(deployer),
                    " at nonce ",
                    vm.toString(n),
                    ", has code no journal records: find its journal with git log --all -i -G ",
                    vm.toString(addr),
                    " -- ",
                    _dir(),
                    "; if it is none of ",
                    _unit(),
                    "'s roles, list it in ",
                    _unit(),
                    ".json's retired; if it may be one and git has no journal, stop: a person must resolve it"
                )
            );
        }
    }

    /// @dev The contents of every `.json` file in the network directory except `*.input.json`. Any
    ///      other entry reads as `{}`. Inputs are skipped because a malformed input must not abort an
    ///      unrelated step. Files that are not journals hold no `*Deployer` key, so they match
    ///      nothing.
    function _journals() private view returns (string[] memory journals) {
        VmSafe.DirEntry[] memory files = vm.readDir(_dir());
        journals = new string[](files.length);
        for (uint256 i; i < files.length; ++i) {
            string memory path = files[i].path;
            journals[i] = !files[i].isDir && _endsWith(path, ".json") && !_endsWith(path, ".input.json")
                ? vm.readFile(path)
                : "{}";
        }
    }

    /// @dev Whether some journal records `at` as a role with `at`'s current code hash. The address
    ///      fixes the deployer and nonce, which `_recordSender` keeps consistent with it. The hash
    ///      also tells a multi-chain unit's record on one chain from a CREATE on another chain by
    ///      the same key at the same nonce.
    function _journaled(string[] memory journals, address addr) private view returns (bool) {
        for (uint256 j; j < journals.length; ++j) {
            string memory journal = journals[j];
            string[] memory keys = vm.parseJsonKeys(journal, "$");
            for (uint256 k; k < keys.length; ++k) {
                if (!_endsWith(keys[k], "Deployer")) continue;
                string memory role = string.concat(".", vm.replace(keys[k], "Deployer", ""));
                if (
                    _has(journal, role) && _addr(journal, role) == addr
                        && _has(journal, string.concat(role, "CodeHash"))
                        && vm.parseJsonBytes32(journal, string.concat(role, "CodeHash")) == addr.codehash
                ) return true;
            }
        }
        return false;
    }

    /// @dev The one landed CREATE of `artifact` by `sender` on this chain, for a `recover` step to
    ///      journal as `role` once `_requireCurrent` holds. Returns a `Create` with a zero `at` when
    ///      the journal already has the role or no such CREATE landed.
    function _createToRecover(string memory journal, string memory role, string memory artifact, address sender)
        internal
        returns (Create memory found)
    {
        return _createToRecover(journal, role, artifact, sender, 0);
    }

    /// @dev `_createToRecover` where several CREATEs of `artifact` landed, as for two roles of one
    ///      artifact: the one whose input is `initcodeHash`'s, if exactly one is.
    function _createToRecover(
        string memory journal,
        string memory role,
        string memory artifact,
        address sender,
        bytes32 initcodeHash
    ) internal returns (Create memory found) {
        if (_has(journal, string.concat(".", role))) return found;
        bool landed;
        (landed, found) = _landedCreate(journal, role, artifact, sender, initcodeHash);
        if (landed) _requireNoKeysOf(journal, role);
    }

    /// @dev Reverts unless `found`, if set, was made from this build's `artifact` with `args`, as the
    ///      chain shows. A genuine deployment from other inputs is an earlier one, not the one the
    ///      journal lost.
    function _requireCurrent(Create memory found, string memory artifact, bytes memory args) internal {
        if (found.addr == address(0)) return;
        bytes memory input = _txInput(found);
        require(
            keccak256(input) == _initcodeHash(artifact, args),
            string.concat(
                found.path,
                " records ",
                artifact,
                " at ",
                vm.toString(found.addr),
                " with initcode other than this build's with the current inputs: if it is the lost deployment,",
                " restore the commit and inputs that made it; if not, list it in ",
                _unit(),
                ".json's retired"
            )
        );
        require(
            vm.computeCreateAddress(found.from, found.nonce) == found.addr, "a deployment is not at its sender's nonce"
        );
        Create memory landed = _landedAsRecorded(artifact, found, input);
        (found.path, found.record, found.run, found.key, found.args) =
        (landed.path, landed.record, landed.run, landed.key, args);
    }

    /// @dev Writes each role of `roles` (role, artifact) whose `found` is set. Call it only after
    ///      every check passed, so that a refusal leaves no key behind.
    function _journalRecovered(string memory journal, string[2][] memory roles, Create[] memory found) internal {
        bool recovered;
        for (uint256 i; i < roles.length; ++i) {
            if (found[i].addr == address(0)) continue;
            _recoverRole(roles[i][0], roles[i][1], found[i]);
            recovered = true;
        }
        if (recovered && !_has(journal, _selectedStampKey())) _putChainStamp();
    }

    /// @dev Reverts if the journal holds any extension key of `role`, so that recovery never writes
    ///      over part of a role. A key counts if it is `<role>` followed by an uppercase letter, so a
    ///      unit's own extensions (`<role>Salt`) count without being listed here.
    function _requireNoKeysOf(string memory journal, string memory role) private view {
        string[] memory keys = vm.parseJsonKeys(journal, "$");
        uint256 n = bytes(role).length;
        for (uint256 i; i < keys.length; ++i) {
            bytes memory k = bytes(keys[i]);
            if (k.length <= n || vm.indexOf(keys[i], role) != 0 || k[n] < "A" || k[n] > "Z") continue;
            revert(string.concat(_unit(), ".json holds ", keys[i], " but not ", role, ": a person must resolve it"));
        }
    }

    /// @dev Journals a recovered role. The original code hash is lost, so it records the live code's
    ///      hash, which proves nothing about the code. What vouches for it is the initcode check in
    ///      `_requireCurrent`.
    function _recoverRole(string memory role, string memory artifact, Create memory found) private {
        bytes memory input = _txInput(found);
        _recordSender(role, found.addr, found.from, found.nonce);
        _put(string.concat(".", role, "Args"), vm.toString(found.args));
        _put(string.concat(".", role, "InitcodeHash"), vm.toString(keccak256(input)));
        require(
            input.length >= found.args.length, string.concat("the recovered ", role, "'s arguments exceed its input")
        );
        (bytes32 code,) = _hashSplit(input, found.args.length);
        _put(string.concat(".", role, "CreationCodeHash"), vm.toString(code));
        _recordBuild(role, found.addr, artifact);
        (bool hasCommit, string memory commit) = _commit(found);
        if (hasCommit) _put(string.concat(".", role, "Commit"), string.concat('"', commit, '"'));
        _put(string.concat(".", role), vm.toString(found.addr));
        _recordReceipt(_journal(), role, found.addr);
        console.log("recovered", role, found.addr);
    }

    /// @dev `sender`'s one CREATE of `artifact` on this chain that has code, ignoring addresses the
    ///      journal's `retired` list names. Only `sender`'s count: an address another sender created
    ///      is not this project's to adopt, so the stray guard keeps refusing it until a person
    ///      resolves it. Reverts if a CREATE has no code but its nonce is unused, or if two
    ///      different ones landed and not exactly one of them with input `initcodeHash`.
    function _landedCreate(
        string memory journal,
        string memory role,
        string memory artifact,
        address sender,
        bytes32 initcodeHash
    ) private returns (bool, Create memory found) {
        Create[] memory creates = _creates(artifact);
        string memory landed;
        uint256 count;
        uint256 matching;
        Create memory match_;
        for (uint256 i; i < creates.length; ++i) {
            Create memory c = creates[i];
            if (c.from != sender || c.create2 || _isRetired(journal, c.addr)) continue;
            if (c.addr.code.length == 0) {
                require(
                    vm.getNonce(sender) > c.nonce,
                    string.concat(
                        _unit(),
                        ".json lacks ",
                        role,
                        ", yet ",
                        c.path,
                        " holds a CREATE of ",
                        artifact,
                        " at ",
                        vm.toString(c.addr),
                        " that may still land: wait, or spend the nonce"
                    )
                );
                continue;
            }
            // forge writes each run twice, as `-latest` and timestamped, so an address can repeat.
            // The same address with other initcode is a transaction replaced at that nonce, and only
            // the chain knows which one landed.
            if (vm.contains(landed, vm.toString(c.addr))) {
                require(
                    c.addr != found.addr || keccak256(_txInput(c)) == keccak256(_txInput(found)),
                    string.concat(
                        _unit(),
                        ".json lacks ",
                        role,
                        ", and the records create ",
                        artifact,
                        " at ",
                        vm.toString(c.addr),
                        " with different initcode: a person must choose"
                    )
                );
                continue;
            }
            landed = count == 0 ? vm.toString(c.addr) : string.concat(landed, ", ", vm.toString(c.addr));
            found = c;
            ++count;
            if (initcodeHash != 0 && keccak256(_txInput(c)) == initcodeHash) {
                match_ = c;
                ++matching;
            }
        }
        if (count > 1 && matching == 1) return (true, match_);
        require(
            count < 2,
            string.concat(
                _unit(),
                ".json lacks ",
                role,
                ", and ",
                vm.toString(sender),
                " created ",
                artifact,
                " at ",
                landed,
                ": a person must choose"
            )
        );
        return (count == 1, found);
    }

    /// @dev A CREATE replaced at the same nonce outside forge lands other initcode at the same
    ///      address with no record, so the recorded initcode proves nothing about the live code. The
    ///      chain must therefore show that a transaction of a run recording `found`'s CREATE, with
    ///      `input`, created it. A resend with a higher fee leaves the landed hash in another run.
    ///      `forge test` keeps no transaction history, so under test this takes `found` as the
    ///      record that landed. Only a run against a live node proves it.
    function _landedAsRecorded(string memory artifact, Create memory found, bytes memory input)
        private
        returns (Create memory)
    {
        if (vm.isContext(VmSafe.ForgeContext.Test)) return found;
        Create[] memory creates = _creates(artifact);
        for (uint256 i; i < creates.length; ++i) {
            Create memory c = creates[i];
            if (
                !c.create2 && c.addr == found.addr && keccak256(_txInput(c)) == keccak256(input)
                    && _isLandedIn(c, input)
            ) {
                return c;
            }
        }
        revert(
            string.concat(
                "no transaction of ",
                found.path,
                " that the chain shows created ",
                vm.toString(found.addr),
                " sent the recorded initcode: a person must resolve it"
            )
        );
    }

    /// @dev Any of the run's hashes may be `c`'s: see `_recordReceipt`.
    function _isLandedIn(Create memory c, bytes memory input) private returns (bool) {
        for (uint256 j; _hasTransaction(c, j); ++j) {
            (bool ok, bytes32 hash) = _candidateHash(c, j);
            if (!ok || _createdIn(hash, c.addr, false) == 0) continue;
            if (keccak256(_sentInput(hash)) == keccak256(input)) return true;
        }
        return false;
    }

    /// @dev Whether the journal's `retired` list names `at`.
    function _isRetired(string memory journal, address addr) private view returns (bool) {
        if (!_has(journal, ".retired")) return false;
        address[] memory retired = vm.parseJsonAddressArray(journal, ".retired");
        for (uint256 i; i < retired.length; ++i) {
            if (retired[i] == addr) return true;
        }
        return false;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {console} from "forge-std/Script.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";

import {
    PROJECT_FILE,
    chainId,
    chainKindIn,
    defaultChainIn,
    pathIn,
    planRpcIn,
    rehearsalPrefixIn,
    validatedProject
} from "./Chains.sol";
import {requireBuild as checkBuild, requireLost as checkLost} from "./DeployChecks.sol";
import {ForgeBroadcasts, VmRpcJson} from "./ForgeBroadcasts.sol";
import {isRehearsalNetworkIn, outputsEnv, slashed, unitInputHash} from "./Journal.sol";

/// @dev What the engine needs of the unit that calls it, as its first argument: the engine keeps no state, so
///      each call carries the unit's view of the run. `host` is set only under `forge test`, where a unit
///      may answer the engine's test hooks; a script may not use its own address.
/// @dev Where the engine is placed, and the only way to reach it. A static call to it is not a transaction of a
///      broadcast. Places it on first use, in a view too: forge allows `vm.etch` in a static frame, which only
///      the compiler forbids. The engine's code is a cache of the build, so a probe that places it and reverts
///      leaves nothing a rerun reads.
address constant ENGINE = address(uint160(uint256(keccak256("sprue.engine.v1"))));

function engine() view returns (ISprueEngine) {
    if (ENGINE.code.length == 0) _asView(_place)();
    return ISprueEngine(ENGINE);
}

function _place() {
    Vm cheat = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes memory code;
    try cheat.getDeployedCode("SprueEngine.sol:SprueEngine") returns (bytes memory found) {
        code = found;
    } catch {
        revert("sprue's engine is not found by name: a contract named SprueEngine in this project hides it");
    }
    cheat.etch(ENGINE, code);
    cheat.allowCheatcodes(ENGINE);
    cheat.makePersistent(ENGINE);
}

function _asView(function() f) pure returns (function() view g) {
    assembly ("memory-safe") {
        g := f
    }
}

/// @dev The initcode and argument hashes of a contract the unit's `_deployRole` created in this run.
struct Created {
    bytes32 initcodeHash;
    bytes32 argsHash;
}

/// @dev What a unit hands the engine to journal a deployment it made or reused.
struct Deployed {
    string role;
    string artifact;
    bytes args;
    address addr;
    address recorded;
    address deployer;
    uint256 nonce;
    bytes32 salt;
    bool journaled;
    bool sent;
    bool dirty;
}

struct Ctx {
    address host;
    string unit;
    string deployments;
    string network;
    string script;
    string graph;
    bytes32 projectHash;
    string defaultChain;
    string selected;
    bool fenced;
    bool rehearsal;
    bool probing;
    /// @dev Set by the unit for the one role a proof reads.
    Created created;
    bool trusted;
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
    function validateProject(string calldata path) external view returns (string memory);
    function requireBuild(address addr, string calldata artifact) external view;
    function requireLost(address addr, address deployer, uint256 nonce, string calldata unit) external view;
    function reuseForSend(
        Ctx calldata ctx,
        string calldata journal,
        string calldata role,
        string calldata artifact,
        bytes calldata args,
        address sender,
        uint256 next
    ) external view returns (address);
    function reuseForDue(
        Ctx calldata ctx,
        string calldata journal,
        string calldata role,
        string calldata artifact,
        bytes calldata args
    ) external view returns (address);
    function requireRecordedCode(Ctx calldata ctx, string calldata journal, string calldata role)
        external
        view
        returns (address);
    function findCreationInput(Ctx calldata ctx, string calldata journal, string calldata role)
        external
        view
        returns (bytes memory);
    function requireCreatedFrom(
        Ctx calldata ctx,
        string calldata journal,
        string calldata role,
        string calldata artifact,
        bytes calldata args
    ) external view;
    function requireCreatedWith(Ctx calldata ctx, string calldata journal, string calldata role, bytes calldata args)
        external
        view;
    function requireJournaledCreate(
        Ctx calldata ctx,
        string calldata unit,
        string calldata record,
        string calldata role,
        bytes calldata args
    ) external view;
    function requireCreateIdentity(
        Ctx calldata ctx,
        string calldata journal,
        string calldata role,
        bytes calldata args
    ) external view;
    function requireCreateRecord(
        Ctx calldata ctx,
        string calldata unit,
        string calldata journal,
        string calldata role,
        address addr
    ) external view;
    function requireCreate2Record(
        Ctx calldata ctx,
        string calldata journal,
        string calldata role,
        bytes calldata args,
        bool withArgs
    ) external view;
    function requireCreate2Address(
        Ctx calldata ctx,
        bytes32 salt,
        string calldata artifact,
        bytes calldata args,
        address addr
    ) external view;
    function requireDeployable(Ctx calldata ctx, address sender, bool strict, bool allowed) external view;
    function recordIntent(Ctx calldata ctx, string calldata role, string calldata artifact, bytes calldata args)
        external
        view;
    function use(Ctx calldata ctx) external view returns (string memory);
    function leave(Ctx calldata ctx, bool sends) external view returns (string memory);
    function putChainStamp(Ctx calldata ctx) external view;
    function checkOutputs(Ctx calldata ctx) external view;
    function requireClient(Ctx calldata ctx) external view;
    function checkedAddress(Ctx calldata ctx, string calldata unit, string calldata role)
        external
        view
        returns (address);
    function recorded(Ctx calldata ctx, string calldata unit, string calldata role) external view returns (address);
    function journalOf(Ctx calldata ctx, string calldata unit) external view returns (string memory);
    function checkedOptional(Ctx calldata ctx, string calldata unit, string calldata role)
        external
        view
        returns (bool, address);
    function certifyChecked(Ctx calldata ctx, string calldata checked) external view;
    function beginChecked(Ctx calldata ctx, string calldata role, address addr) external view returns (string memory);
    function certifyRole(Ctx calldata ctx, string calldata obj, string calldata role, address addr) external view;
    function certificate(
        Ctx calldata ctx,
        string calldata journal,
        string[] calldata names,
        address[] calldata addrs,
        uint8[] calldata kinds
    ) external view returns (string memory);
    function create2Pre(
        Ctx calldata ctx,
        string calldata journal,
        string calldata role,
        string calldata artifact,
        bytes calldata args,
        bytes32 salt,
        address at
    ) external view returns (bool, bool);
    function create2Record(Ctx calldata ctx, Deployed calldata d) external view;
    function recordDeployment(Ctx calldata ctx, string calldata journal, Deployed calldata d)
        external
        view
        returns (uint256);
}

/// @notice The heavy, rarely executed part of a unit: the scans of forge's broadcast records, the stray and
///         fence guards, receipts and recovery. A unit places it at one address with `vm.etch` and calls it
///         with a static call, so no unit carries the code and no call is a broadcast transaction.
/// @dev Stateless: every external function takes `Ctx` first, and reads it back from calldata.
contract SprueEngine is ForgeBroadcasts {
    /// @dev Points into the call's own calldata: a getter copies the one field it returns, not the whole context.
    function _ctx() private pure returns (Ctx calldata c) {
        assembly ("memory-safe") {
            c := add(4, calldataload(4))
        }
    }

    function _unit() internal pure override returns (string memory) {
        return _ctx().unit;
    }

    function _deployments() internal pure override returns (string memory) {
        return _ctx().deployments;
    }

    /// @dev The project's `sprue.json` as the unit validated it, else validated here: the engine keeps no state to
    ///      remember it by.
    function _project() private view returns (string memory json) {
        json = vm.readFile(PROJECT_FILE);
        if (keccak256(bytes(json)) != _ctx().projectHash) validatedProject(PROJECT_FILE);
    }

    function _graphScript() internal view override returns (string memory) {
        string memory graph = _ctx().graph;
        return bytes(graph).length == 0 ? pathIn(_project(), "graph") : graph;
    }

    /// @dev Empty in the context means the one `Deploy*.s.sol` in the unit's directory.
    function _deployScript() internal view override returns (string memory) {
        string memory script = _ctx().script;
        return bytes(script).length == 0 ? _defaultDeployScript() : script;
    }

    /// @dev Empty in the context means the project's rule.
    function _defaultChain(string memory network) internal view override returns (string memory) {
        string memory chain = _ctx().defaultChain;
        if (bytes(chain).length != 0) return chain;
        chain = defaultChainIn(_project(), network);
        require(bytes(chain).length != 0, "network.json has several chains and sprue.json sets no chains.default");
        return chain;
    }

    function _selectedChain() internal view override returns (string memory) {
        string memory chain = _ctx().selected;
        return bytes(chain).length == 0 ? _defaultChain(_networkJson()) : chain;
    }

    function _checkOutputs() internal override {
        _requireOutput("records", "FOUNDRY_BROADCAST", "broadcast", _records());
        if (_rehearsal()) {
            _requireOutput("resume data", "FOUNDRY_CACHE_PATH", "cache", string.concat(_dir(), "/cache"));
        }
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

    function validateProject(string calldata path) external view returns (string memory) {
        return validatedProject(path);
    }

    function requireBuild(address addr, string calldata artifact) external view {
        checkBuild(addr, artifact);
    }

    function requireLost(address addr, address deployer, uint256 nonce, string calldata unit) external view {
        checkLost(addr, deployer, nonce, unit);
    }

    function reuseForSend(
        Ctx calldata,
        string calldata journal,
        string calldata role,
        string calldata artifact,
        bytes calldata args,
        address sender,
        uint256 next
    ) external returns (address) {
        return _reuseForSend(journal, role, artifact, args, sender, next);
    }

    function reuseForDue(
        Ctx calldata,
        string calldata journal,
        string calldata role,
        string calldata artifact,
        bytes calldata args
    ) external returns (address) {
        return _reuseForDue(journal, role, artifact, args);
    }

    function requireRecordedCode(Ctx calldata, string calldata journal, string calldata role)
        external
        view
        returns (address)
    {
        return _requireRecordedCode(journal, role);
    }

    function findCreationInput(Ctx calldata, string calldata journal, string calldata role)
        external
        returns (bytes memory)
    {
        return _findCreationInput(journal, role);
    }

    function requireCreatedFrom(
        Ctx calldata,
        string calldata journal,
        string calldata role,
        string calldata artifact,
        bytes calldata args
    ) external {
        _requireCreatedFrom(journal, role, artifact, args);
    }

    function requireCreatedWith(Ctx calldata, string calldata journal, string calldata role, bytes calldata args)
        external
    {
        _requireCreatedWith(journal, role, args);
    }

    function requireJournaledCreate(
        Ctx calldata,
        string calldata unit,
        string calldata record,
        string calldata role,
        bytes calldata args
    ) external view {
        _requireJournaledCreate(unit, record, role, args);
    }

    function requireCreateIdentity(Ctx calldata, string calldata journal, string calldata role, bytes calldata args)
        external
    {
        _requireCreateIdentity(journal, role, args);
    }

    function requireCreateRecord(
        Ctx calldata,
        string calldata unit,
        string calldata journal,
        string calldata role,
        address addr
    ) external view {
        _requireCreateRecord(unit, journal, role, addr);
    }

    function requireCreate2Record(
        Ctx calldata,
        string calldata journal,
        string calldata role,
        bytes calldata args,
        bool withArgs
    ) external view {
        _requireCreate2Record(journal, role, args, withArgs);
    }

    function requireCreate2Address(
        Ctx calldata,
        bytes32 salt,
        string calldata artifact,
        bytes calldata args,
        address addr
    ) external view {
        _requireCreate2Address(salt, artifact, args, addr);
    }

    function requireDeployable(Ctx calldata, address sender, bool strict, bool allowed) external {
        _requireDeployable(sender, strict, allowed);
    }

    function recordIntent(Ctx calldata, string calldata role, string calldata artifact, bytes calldata args)
        external
    {
        _recordIntent(role, artifact, args);
    }

    function create2Pre(
        Ctx calldata,
        string calldata journal,
        string calldata role,
        string calldata artifact,
        bytes calldata args,
        bytes32 salt,
        address at
    ) external view returns (bool, bool) {
        return _create2Pre(journal, role, artifact, args, salt, at);
    }

    function create2Record(Ctx calldata, Deployed calldata d) external {
        _create2Record(d.role, d.artifact, d.args, d.salt, d.addr, d.journaled, d.sent, d.dirty);
    }

    function recordDeployment(Ctx calldata, string calldata journal, Deployed calldata d) external returns (uint256) {
        return _recordDeployment(journal, d.role, d.artifact, d.args, d.addr, d.recorded, d.deployer, d.nonce, d.sent, d.dirty);
    }

    function use(Ctx calldata) external returns (string memory) {
        return _enter();
    }

    function leave(Ctx calldata, bool sends) external returns (string memory) {
        return _leave(sends);
    }

    function putChainStamp(Ctx calldata) external {
        _putChainStamp();
    }

    function checkOutputs(Ctx calldata) external {
        _checkOutputs();
    }

    function requireClient(Ctx calldata) external {
        _requireClient();
    }

    function checkedAddress(Ctx calldata, string calldata unit, string calldata role) external view returns (address) {
        return _checked(unit, role);
    }

    function recorded(Ctx calldata, string calldata unit, string calldata role) external view returns (address) {
        return _recorded(unit, role);
    }

    function journalOf(Ctx calldata, string calldata unit) external view returns (string memory) {
        return _journalOf(unit);
    }

    function checkedOptional(Ctx calldata, string calldata unit, string calldata role)
        external
        view
        returns (bool, address)
    {
        return _checkedOptional(unit, role);
    }

    function certifyChecked(Ctx calldata, string calldata checked) external {
        _certify(checked);
    }

    function beginChecked(Ctx calldata, string calldata role, address addr) external returns (string memory) {
        return _beginChecked(role, addr);
    }

    function certifyRole(Ctx calldata, string calldata obj, string calldata role, address addr) external {
        string memory checked = vm.serializeBytes32(obj, string.concat(role, "CodeHash"), addr.codehash);
        console.log(string.concat("checked ", checked));
        _certify(checked);
    }

    /// @dev The certificate object of the first proved role, with the others' addresses and code hashes, after
    ///      the receipts of those a unit deployed. `kinds` are `Roles.Kind` values: an extern role has no receipt.
    function certificate(
        Ctx calldata,
        string calldata journal,
        string[] calldata names,
        address[] calldata addrs,
        uint8[] calldata kinds
    ) external returns (string memory obj) {
        obj = _beginChecked(names[0], addrs[0]);
        for (uint256 i; i < names.length; ++i) {
            if (kinds[i] != 2) _recordReceipt(journal, names[i], addrs[i], kinds[i] == 1);
            if (i != 0) {
                vm.serializeAddress(obj, names[i], addrs[i]);
                vm.serializeBytes32(obj, string.concat(names[i], "CodeHash"), addrs[i].codehash);
            }
        }
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
            isRehearsalNetworkIn(rehearsalPrefixIn(_project()), _networkName()) ? outputsEnv(_dir()) : "",
            "forge script ",
            _deployScript(),
            " --sig 'recover(string)' ",
            _networkName(),
            " --rpc-url ",
            planRpcIn(_project(), _networkJson()),
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

    /// @dev The code hash of forge-std's `CREATE2_FACTORY`, the keyless deployment proxy. A unit that
    ///      opts into CREATE2 requires this code at that address on its chain, so that the factory
    ///      is the implementation whose behaviour the address computation assumes.
    bytes32 internal constant CREATE2_FACTORY_CODEHASH =
        0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;

    /// @dev The role's recorded address if it has code. Zero if the journal lacks the role, or if its
    ///      recorded deployment can never land: it has no code and `requireLost` shows the deployer's
    ///      nonce is used. A recorded address without code and with an unused nonce is refused,
    ///      because the step cannot tell a lost broadcast from a pending one.
    function _reusableAddress(string memory journal, string memory role) internal returns (address existing) {
        string memory key = string.concat(".", role);
        if (!_has(journal, key)) return address(0);
        existing = _addr(journal, key);
        require(existing != address(0), string.concat("journal ", role, " is the zero address"));
        if (existing.code.length != 0) return existing;
        _requireNoLandedRecord(journal, role);

        require(
            _has(journal, string.concat(key, "Deployer")),
            string.concat("journal ", role, " has no code and no recorded deployer")
        );
        checkLost(
            existing,
            _addr(journal, string.concat(key, "Deployer")),
            _uint(journal, string.concat(key, "Nonce")),
            _unit()
        );
        _requireNoUnjournaled(journal, role, address(0));
        console.log("journal", role, "was never deployed and never can be: its nonce is used; deploying afresh");
        // The old intent stays in the journal until the deploy step overwrites it.
        return address(0);
    }

    /// @dev Reverts unless the code at the role's recorded address has the code hash the journal
    ///      recorded. It compares with the journal, not with the current build, so that a later
    ///      source change does not orphan a deployment. A record without a hash is refused, with no
    ///      fallback.
    function _requireRecordedCode(string memory journal, string memory role) internal view returns (address addr) {
        string memory hashKey = string.concat(".", role, "CodeHash");
        require(_has(journal, hashKey), string.concat(_unit(), ".json records no ", role, "CodeHash"));
        addr = _addr(journal, string.concat(".", role));
        _requireCode(addr, role);
        require(
            addr.codehash == vm.parseJsonBytes32(journal, hashKey),
            string.concat(role, "'s code differs from ", _unit(), ".json")
        );
    }

    /// @dev The initcode that created `role`, as the chain shows it: the input of the transaction that
    ///      created the recorded address, after the salt for a CREATE2 through the factory. The hash
    ///      is the journal's `<role>Tx`, else a broadcast record's, else the chain's (`_findReceipt`),
    ///      and the chain must show that it created the address; else this reverts. Comparing the
    ///      result whole with the initcode a unit expects proves the constructor's arguments.
    function _findCreationInput(string memory journal, string memory role) internal returns (bytes memory) {
        return _inputOf(journal, role, _creationTx(journal, role));
    }

    /// @dev `role` was created from this build's `artifact` with `args`: by this unit's `_deployRole`
    ///      in this run, whose record decides, or by the transaction `_findCreationInput` reads. A role
    ///      with neither passes only in a test that called `trustTestCreations`. For a role created
    ///      otherwise, compare `_findCreationInput` with what it was created from.
    function _requireCreatedFrom(string memory journal, string memory role, string memory artifact, bytes memory args)
        internal
    {
        bytes32 expected = _initcodeHash(artifact, args);
        bytes32 created = _ctx().created.initcodeHash;
        if (created == 0) {
            bytes32 hash = _creationTx(journal, role);
            if (hash == 0 && _ctx().trusted) return;
            created = keccak256(_inputOf(journal, role, hash));
        }
        require(
            created == expected,
            string.concat(
                role,
                " was not created from this build's ",
                artifact,
                " with the step's arguments: if they changed after its creation, or its source after its deployment, compare _findCreationInput with what it was created from"
            )
        );
    }

    /// @dev `role` was created with `args` from the code its journal records: by this unit's
    ///      `_deployRole` in this run, or by the transaction `_findCreationInput` reads, whose input must
    ///      be code that hashes to `<role>CreationCodeHash` followed by `args`. Unlike
    ///      `_requireCreatedFrom`, a role whose source changed after its deployment passes; the code's
    ///      identity rests on the journal. A journal without that key, written by an older sprue, has the
    ///      whole input proven against `<role>InitcodeHash` and `args` against `<role>Args`, which the
    ///      same write recorded. A role with neither passes only in a test that called
    ///      `trustTestCreations`.
    function _requireCreatedWith(string memory journal, string memory role, bytes memory args) internal {
        string memory key = string.concat(".", role);
        Created memory run = _ctx().created;
        bool created;
        if (run.initcodeHash != 0) {
            created = run.argsHash == keccak256(args);
        } else {
            bytes32 hash = _creationTx(journal, role);
            if (hash == 0 && _ctx().trusted) return;
            bytes memory input = _inputOf(journal, role, hash);
            if (input.length >= args.length) {
                (bytes32 code, bytes32 tail) = _hashSplit(input, args.length);
                created = tail == keccak256(args)
                    && (_has(journal, string.concat(key, "CreationCodeHash"))
                            ? code == vm.parseJsonBytes32(journal, string.concat(key, "CreationCodeHash"))
                            : keccak256(input) == vm.parseJsonBytes32(journal, string.concat(key, "InitcodeHash"))
                            && keccak256(vm.parseJsonBytes(journal, string.concat(key, "Args"))) == keccak256(args));
            }
        }
        require(
            created,
            string.concat(role, " was not created with the step's arguments from the code ", _unit(), ".json records")
        );
    }

    /// @dev The journal's record of `role` is consistent with a CREATE of `args` by the deployer that
    ///      `network.json` pins: the recorded arguments are `args`, and the recorded deployer and nonce give
    ///      the address the journal records, which is the one a step reuses. Refused on a network that pins
    ///      no deployer, where any key's record would pass. It proves what the journal says, not what the
    ///      chain shows: `_requireCreatedWith` reads the creation itself, where the input is the code
    ///      followed by `args` alone.
    function _requireJournaledCreate(string memory journal, string memory role, bytes memory args) internal view {
        _requireJournaledCreate(_unit(), journal, role, args);
    }

    /// @dev `_requireJournaledCreate` of `unit`'s journal `record`, as `_journalOf(unit)` reads it.
    function _requireJournaledCreate(string memory unit, string memory record, string memory role, bytes memory args)
        internal
        view
    {
        address pinned = _pinnedDeployer();
        require(
            pinned != address(0),
            string.concat("network.json pins no deployer, so ", unit, ".json alone cannot prove ", role, "'s creation")
        );
        string memory key = string.concat(".", role);
        require(
            keccak256(vm.parseJsonBytes(record, string.concat(key, "Args"))) == keccak256(args),
            string.concat(role, "'s constructor arguments differ from ", unit, ".json")
        );
        require(
            _addr(record, string.concat(key, "Deployer")) == pinned,
            string.concat(role, "'s recorded deployer is not network.json's deployer")
        );
        require(
            vm.computeCreateAddress(pinned, _uint(record, string.concat(key, "Nonce"))) == _addr(record, key),
            string.concat(role, "'s address is not its recorded deployer's CREATE at its recorded nonce")
        );
    }

    function _creationTx(string memory journal, string memory role) internal returns (bytes32 hash) {
        string memory key = string.concat(".", role);
        if (_has(journal, string.concat(key, "Tx"))) return vm.parseJsonBytes32(journal, string.concat(key, "Tx"));
        address addr = _addr(journal, key);
        (hash,,) = _findReceipt(journal, role, addr, false);
        if (hash == 0) (hash,,) = _findReceipt(journal, role, addr, true);
    }

    /// @dev `_creationTx` of a CREATE role, which no CREATE2 factory call made.
    function _createTx(string memory journal, string memory role) private returns (bytes32 hash) {
        string memory key = string.concat(".", role, "Tx");
        if (_has(journal, key)) return vm.parseJsonBytes32(journal, key);
        (hash,,) = _findReceipt(journal, role, _addr(journal, string.concat(".", role)), false);
    }

    function _inputOf(string memory journal, string memory role, bytes32 hash) private returns (bytes memory input) {
        string memory key = string.concat(".", role);
        require(
            hash != 0,
            string.concat(
                "neither ",
                _unit(),
                ".json, a broadcast record nor the chain shows the transaction that created ",
                role,
                ": journal it as ",
                role,
                "Tx"
            )
        );
        address addr = _addr(journal, key);
        bool create2 = _createdIn(hash, addr, false) == 0;
        require(
            !create2 || _createdIn(hash, addr, true) != 0,
            string.concat(
                vm.toString(hash),
                ", the transaction of ",
                role,
                ", did not create ",
                vm.toString(addr),
                " as this RPC shows the chain: if it lags behind the chain or no longer serves old transactions, use one that does"
            )
        );
        input = _sentInput(hash);
        if (create2) {
            require(input.length >= 32, "a CREATE2 factory call's input is shorter than its salt");
            // SAFETY: the length is at least 32, checked above. The new head overwrites the salt.
            assembly ("memory-safe") {
                let length := sub(mload(input), 0x20)
                input := add(input, 0x20)
                mstore(input, length)
            }
        }
    }

    /// @dev Returns zero when this run must send the role: the journal lacks it, an intent in it has
    ///      not landed, or its deployment is lost for good (see `_reusableAddress`). A pending intent
    ///      is sent again only as the same transaction, `sender` at nonce `next` with this initcode,
    ///      which can land at most once. Otherwise returns the recorded address, checked against the
    ///      recorded code. A role the journal lacks is refused while a broadcast record may hold its
    ///      deployment.
    function _reuseForSend(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        address sender,
        uint256 next
    ) internal returns (address addr) {
        string memory key = string.concat(".", role);
        if (
            _samePendingIntent(journal, role, artifact, args)
                && _addr(journal, string.concat(key, "Deployer")) == sender
                && _uint(journal, string.concat(key, "Nonce")) == next
        ) {
            _requireNoLandedRecord(journal, role);
            return address(0);
        }
        if (!_has(journal, key)) {
            _requireNoStray(journal, role, artifact);
            _requireNoUnjournaled(journal, role, sender);
        }
        addr = _reusableAddress(journal, role);
        if (addr != address(0)) _requireRecordedCode(journal, role);
    }

    /// @dev `_reuseForSend` for a `Due` view. A view shares the step's decision but knows neither the
    ///      sender nor the nonce. So any pending intent with the same hash yields zero here, and the
    ///      fence lacks the current sender (the pin or a deployer in a journal may still cover it).
    ///      A zero from this function therefore does not authorize a resend: only the step decides
    ///      that. A unit authenticates a nonzero result.
    function _reuseForDue(string memory journal, string memory role, string memory artifact, bytes memory args)
        internal
        returns (address addr)
    {
        if (!_has(journal, string.concat(".", role))) {
            _requireNoStray(journal, role, artifact);
            _requireNoUnjournaled(journal, role, address(0));
            return address(0);
        }
        addr = _addr(journal, string.concat(".", role));
        if (addr != address(0) && addr.code.length == 0 && _samePendingIntent(journal, role, artifact, args)) {
            _requireNoLandedRecord(journal, role);
            return address(0);
        }
        addr = _reusableAddress(journal, role);
        if (addr != address(0)) _requireRecordedCode(journal, role);
    }

    /// @dev A receipt or a check of `role` says it landed. With no code at its address, the RPC lags or the
    ///      chain was reset, and a resend or a replacement would let the stale `checked` vouch for an
    ///      unchecked contract with the same code.
    function _requireNoLandedRecord(string memory journal, string memory role) internal view {
        require(
            !_has(journal, string.concat(".", role, "Tx")) && !_has(journal, string.concat(".checked.", role)),
            string.concat(
                _unit(),
                ".json records ",
                role,
                " as landed, but the RPC shows no code at its address: the RPC lags or the chain was reset; a person must resolve it"
            )
        );
    }

    /// @dev Whether the journal records `role` at an address with no code, and its recorded
    ///      initcode hash equals this build's `artifact` with `args`.
    function _samePendingIntent(string memory journal, string memory role, string memory artifact, bytes memory args)
        private
        view
        returns (bool)
    {
        string memory key = string.concat(".", role);
        string memory hashKey = string.concat(key, "InitcodeHash");
        return _has(journal, key) && _has(journal, hashKey) && _addr(journal, key) != address(0)
            && _addr(journal, key).code.length == 0
            && vm.parseJsonBytes32(journal, hashKey) == _initcodeHash(artifact, args);
    }

    function _recordIntent(string memory role, string memory name, bytes memory args) internal {
        _put(string.concat(".", role, "Args"), vm.toString(args));
        _put(string.concat(".", role, "InitcodeHash"), vm.toString(_initcodeHash(name, args)));
        _put(
            string.concat(".", role, "CreationCodeHash"),
            vm.toString(keccak256(vm.getCode(string.concat(name, ".sol:", name))))
        );
    }

    /// @dev Reverts unless `at` is where the factory puts this build's `artifact` with `args` under
    ///      `salt`. The unit's input file names `at`, so a reviewer sees the address before any send.
    ///      A change of the initcode, through the build or the arguments, moves the address, and the
    ///      refusal gives the initcode hash to mine a new salt for.
    function _requireCreate2Address(bytes32 salt, string memory artifact, bytes memory args, address addr)
        internal
        view
    {
        require(
            CREATE2_FACTORY.codehash == CREATE2_FACTORY_CODEHASH,
            string.concat("this chain has no CREATE2 factory at ", vm.toString(CREATE2_FACTORY), ": opt out of create2")
        );
        bytes32 initcodeHash = _initcodeHash(artifact, args);
        require(
            vm.computeCreate2Address(salt, initcodeHash, CREATE2_FACTORY) == addr,
            string.concat(
                "this build of ",
                artifact,
                " does not land at the input's create2.address under its salt: mine a salt for init code hash ",
                vm.toString(initcodeHash)
            )
        );
    }

    /// @dev `role`'s address is the CREATE of its recorded deployer at its recorded nonce, that deployer is
    ///      the one `network.json` pins or one of its `formerDeployers`, its recorded arguments are `args`, and some transaction is known to
    ///      have created it: the journal's `<role>Tx`, a broadcast record's, the chain's at the recorded
    ///      nonce, or this run's. On a network that pins no deployer, the recorded deployer stands, with a
    ///      warning: nothing then says whose CREATE the role must be.
    function _requireCreateIdentity(string memory journal, string memory role, bytes memory args) internal {
        string memory key = string.concat(".", role);
        address addr = _addr(journal, key);
        _requireCreateRecord(_unit(), journal, role, addr);
        _requireKey(_unit(), journal, role, "Args");
        require(
            keccak256(vm.parseJsonBytes(journal, string.concat(key, "Args"))) == keccak256(args),
            string.concat(role, "'s constructor arguments differ from ", _unit(), ".json")
        );
        if (_ctx().created.initcodeHash != 0) return;
        require(
            _createTx(journal, role) != 0 || _ctx().trusted,
            string.concat(
                "neither ",
                _unit(),
                ".json, a broadcast record nor the chain shows the transaction that created ",
                role,
                ": journal it as ",
                role,
                "Tx"
            )
        );
    }

    /// @dev `unit`'s `journal` puts `role` at `addr` by a CREATE of its recorded deployer at its
    ///      recorded nonce, and that deployer is the pin or a former one, if `network.json` has a pin.
    function _requireCreateRecord(string memory unit, string memory journal, string memory role, address addr)
        internal
        view
    {
        string memory key = string.concat(".", role);
        _requireKey(unit, journal, role, "Deployer");
        _requireKey(unit, journal, role, "Nonce");
        address deployer = _addr(journal, string.concat(key, "Deployer"));
        address pinned = _pinnedDeployer();
        if (pinned == address(0)) {
            console.log(
                string.concat(
                    "WARNING: network.json pins no deployer, so ", role, " is proven against ", unit, ".json's deployer"
                )
            );
        } else {
            require(
                deployer == pinned || _isFormerDeployer(deployer),
                string.concat(
                    role, "'s recorded deployer is neither network.json's deployer nor one of its formerDeployers"
                )
            );
        }
        require(
            vm.computeCreateAddress(deployer, _uint(journal, string.concat(key, "Nonce"))) == addr,
            string.concat(role, "'s address is not its recorded deployer's CREATE at its recorded nonce")
        );
    }

    /// @dev Whether `network.json`'s `formerDeployers`, the keys a pin replaced, lists `deployer`: a role one
    ///      of them created stays proven, though only the pin sends.
    function _isFormerDeployer(address deployer) internal view returns (bool) {
        string memory network = _networkJson();
        if (!_has(network, ".formerDeployers")) return false;
        address[] memory former = vm.parseJsonAddressArray(network, ".formerDeployers");
        for (uint256 i; i < former.length; ++i) {
            if (former[i] == deployer && deployer != address(0)) return true;
        }
        return false;
    }

    function _requireKey(string memory unit, string memory journal, string memory role, string memory suffix)
        internal
        view
    {
        require(_has(journal, string.concat(".", role, suffix)), string.concat(unit, ".json records no ", role, suffix));
    }

    /// @dev The factory puts `role`, under the salt and initcode hash `journal` records, at the address it
    ///      records, and, with `withArgs`, the recorded arguments are `args`. Against the recorded initcode
    ///      hash, not this build's, so that a later source edit does not orphan the role.
    function _requireCreate2Record(string memory journal, string memory role, bytes memory args, bool withArgs)
        internal
        view
    {
        string memory key = string.concat(".", role);
        require(
            _has(journal, string.concat(key, "Salt")) && _has(journal, string.concat(key, "InitcodeHash"))
                && vm.computeCreate2Address(
                    vm.parseJsonBytes32(journal, string.concat(key, "Salt")),
                    vm.parseJsonBytes32(journal, string.concat(key, "InitcodeHash")),
                    CREATE2_FACTORY
                ) == _addr(journal, key),
            string.concat(role, "'s address is not the CREATE2 factory's for its recorded salt and initcode")
        );
        if (!withArgs) return;
        _requireKey(_unit(), journal, role, "Args");
        require(
            keccak256(vm.parseJsonBytes(journal, string.concat(key, "Args"))) == keccak256(args),
            string.concat(role, "'s constructor arguments differ from ", _unit(), ".json")
        );
    }

    /// @dev Called just before a step sends a CREATE, after the step's broadcast started, because it
    ///      reads the broadcaster. A run that creates no transaction never reaches it. Reverts when the
    ///      broadcaster is forge's default sender, except under `forge test`. With a pin, the
    ///      broadcaster must be the pinned deployer unless `UNSAFE_UNEXPECTED_DEPLOYER` is exactly
    ///      `1`, which logs a warning instead.
    /// @dev `_requireDeployable`, which with `strict` refuses a key other than the pin whatever the opt-in.
    function _requireDeployable(address sender, bool strict, bool allowed) internal {
        require(
            vm.isContext(VmSafe.ForgeContext.Test) || sender != DEFAULT_SENDER,
            "pass --sender <deployer> to the dry run, or --account"
        );
        address pinned = _pinnedDeployer();
        if (pinned == address(0) || sender == pinned) return;
        require(
            !strict,
            string.concat(
                vm.toString(sender),
                " is not ",
                _dir(),
                "/network.json's deployer ",
                vm.toString(pinned),
                ": only the pin sends a declared CREATE role, whose address follows from its sender; to change keys, pin the new one in a reviewed commit and list the old one in network.json's formerDeployers"
            )
        );
        require(
            allowed,
            string.concat(
                vm.toString(sender),
                " is not ",
                _dir(),
                "/network.json's deployer ",
                vm.toString(pinned),
                ": run with that key, or pass --unsafe-unexpected-deployer to sprue (UNSAFE_UNEXPECTED_DEPLOYER=1 for forge) to deploy with another"
            )
        );
        console.log(
            string.concat(
                "WARNING: deploying as ",
                vm.toString(sender),
                ", not ",
                _dir(),
                "/network.json's deployer ",
                vm.toString(pinned)
            )
        );
    }

    /// @dev Journals a deployment. If `recorded` is non-zero the role was reused, and only its
    ///      receipt is recorded. Returns the deployer's next unused nonce.
    function _recordDeployment(
        string memory journal,
        string memory role,
        string memory name,
        bytes memory args,
        address addr,
        address recorded,
        address deployer,
        uint256 nonce,
        bool sent,
        bool dirty
    ) internal returns (uint256) {
        if (recorded != address(0)) {
            _recordReceipt(journal, role, addr);
            return nonce;
        }
        if (sent) _recordIntent(role, name, args);
        // The address goes last. `_reusableAddress` takes it as the sign that a record exists, and
        // needs the deployer and nonce to be there already.
        _recordBuild(role, addr, name);
        _recordDirty(role, dirty);
        _recordSender(role, addr, deployer, nonce);
        _put(string.concat(".", role), vm.toString(addr));
        return nonce + 1;
    }

    /// @dev Writes `<role>Dirty` beside the `pending` commit, so that it describes the working tree
    ///      at the send and not at a later recovery. `sprue run` sets the variable only for an
    ///      attended step, and only when its tree had a change at the step's dry run. So a role of a
    ///      clean run, or of a plain `forge script` without that variable in the environment, has no
    ///      such key. A clean send over a key that a replaced intent left sets it to `false`.
    ///      Call it only where a transaction is created.
    function _recordDirty(string memory role, bool dirty) internal {
        string memory key = string.concat(".", role, "Dirty");
        if (dirty) {
            _put(key, "true");
        } else if (_has(_journal(), key)) {
            _put(key, "false");
        }
    }

    function _create2Pre(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        bytes32 salt,
        address at
    ) internal view returns (bool journaled, bool landed) {
        string memory key = string.concat(".", role);
        journaled = _has(journal, key);
        landed = at.code.length != 0;
        if (journaled) {
            require(
                _addr(journal, key) == at,
                string.concat(
                    _unit(), ".json's ", role, " is not the input's create2.address: a person must resolve it"
                )
            );
            require(
                _has(journal, string.concat(key, "Salt"))
                    && vm.parseJsonBytes32(journal, string.concat(key, "Salt")) == salt,
                string.concat("the input's create2.salt differs from ", _unit(), ".json's")
            );
            if (!landed) _requireNoLandedRecord(journal, role);
        } else {
            _requireNoStray(journal, role, artifact, at);
        }
        if (journaled && landed) {
            _requireRecordedCode(journal, role);
            _requireCreate2Record(journal, role, args, true);
        } else {
            // A new salt for a landed role would deploy a second one.
            require(
                !landed || vm.computeCreate2Address(salt, _initcodeHash(artifact, args), CREATE2_FACTORY) == at,
                string.concat(
                    "the input's create2.address holds a ",
                    role,
                    " that another build or input made: restore the journal, and never mine a new salt"
                )
            );
            _requireCreate2Address(salt, artifact, args, at);
        }
    }

    /// @dev What `_deployRoleCreate2` journals once the role exists, after the unit's hook for a first journal.
    function _create2Record(
        string memory role,
        string memory artifact,
        bytes memory args,
        bytes32 salt,
        address at,
        bool journaled,
        bool sent,
        bool dirty
    ) internal {
        string memory key = string.concat(".", role);
        if (!journaled) {
            _put(string.concat(key, "Salt"), vm.toString(salt));
            _recordIntent(role, artifact, args);
            _recordBuild(role, at, artifact);
            _put(key, vm.toString(at));
        }
        if (sent) _recordDirty(role, dirty);
        else _recordReceipt(_journal(), role, at, true);
    }

    /// @notice The first call of a unit step. `network` names a directory under the deployments path.
    ///         Reverts unless the selected chain is the network's default chain (`sprue.json`'s
    ///         `chains.default`, else the network's only chain), before it reads the unit's own
    ///         journal. Returns that journal.
    function _enter() internal returns (string memory journal) {
        string memory path = string.concat(_dir(), "/network.json");
        require(vm.exists(path), string.concat(path, " is missing: name a network under ", _deployments(), "/"));
        string memory file = vm.readFile(path);
        require(
            block.chainid == chainId(file, _defaultChain(file)),
            string.concat("the RPC's chain is not ", _networkName(), "'s default chain")
        );
        _requireClient();
        journal = _journal();
        string memory stamp = _stampKey(file);
        if (_has(journal, stamp)) require(_uint(journal, stamp) == block.chainid, "the journal is another chain's");
    }

    function _putChainStamp() internal {
        _put(_selectedStampKey(), vm.toString(block.chainid));
    }

    /// @notice The last call of a unit step. It logs what happened (nothing to send, simulated, or
    ///         sent), the `git add` command for the files to commit, and the `plan` command to run
    ///         next, which it returns. The graph owns the order, so a step never names its
    ///         successor.
    function _leave(bool sends) internal returns (string memory command) {
        if (_inProbe()) return "";
        if (!sends) console.log("nothing to send");
        else if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) console.log("broadcasting");
        else console.log("simulated: rerun with --broadcast to send");
        console.log(string.concat("git add ", _dir(), " broadcast"));
        command = string.concat(
            isRehearsalNetworkIn(rehearsalPrefixIn(_project()), _networkName()) ? outputsEnv(_dir()) : "",
            "forge script ",
            _graphScript(),
            " --sig 'plan(string,string)' ",
            _networkName(),
            " <node> --rpc-url ",
            planRpcIn(_project(), _networkJson())
        );
        console.log(string.concat("next: ", command));
    }

    /// @dev The address of `unit`'s `role`, as that unit's `check` step certified it. Reverts unless
    ///      the journal holds `checked`, it was made on the selected chain, and the code at the
    ///      address still has the certified hash. A unit should read the contracts it depends on
    ///      through this and not from another unit's uncertified keys. The certificate's chain is
    ///      `checked.<role>ChainId` if present, else the default chain's `checked.<chain>ChainId`.
    function _checked(string memory unit, string memory role) internal view returns (address addr) {
        string memory record = _checkedRecord(unit, role);
        addr = _addr(record, string.concat(".checked.", role));
        _requireCode(addr, role);
        require(
            addr.codehash == vm.parseJsonBytes32(record, string.concat(".checked.", role, "CodeHash")),
            string.concat(role, "'s code differs from ", unit, ".json's check")
        );
    }

    /// @dev The address `unit`'s journal records for `role`, before that unit's `check`: on the chain the
    ///      journal is stamped with, with the code hash it records. Unlike `_checked`, nothing vouches for
    ///      the role's configuration, so read through it only what the role's code fixes.
    function _recorded(string memory unit, string memory role) internal view returns (address addr) {
        string memory record = _journalOf(unit);
        string memory key = string.concat(".", role);
        require(_has(record, key), string.concat(unit, ".json records no ", role));
        addr = _addr(record, key);
        _requireCode(addr, role);
        require(
            _has(record, string.concat(key, "CodeHash"))
                && addr.codehash == vm.parseJsonBytes32(record, string.concat(key, "CodeHash")),
            string.concat(role, "'s code differs from ", unit, ".json")
        );
    }

    /// @dev `unit`'s journal on this network, refused unless it is stamped with this chain.
    function _journalOf(string memory unit) internal view returns (string memory record) {
        string memory path = string.concat(_dir(), "/", unit, ".json");
        require(vm.exists(path), string.concat(unit, ".json is missing"));
        record = vm.readFile(path);
        string memory stamp = _stampKey(_networkJson());
        require(
            _has(record, stamp) && _uint(record, stamp) == block.chainid,
            string.concat(unit, ".json is not this chain's")
        );
    }

    /// @dev `_checked` for a role that may not exist on this chain: `(false, address(0))` where the
    ///      check recorded the role absent with `_recordAbsent`, while its address still has no code.
    ///      Code there since the check reverts, so a dependent never builds on a stale absence.
    function _checkedOptional(string memory unit, string memory role)
        internal
        view
        returns (bool present, address addr)
    {
        string memory record = _checkedRecord(unit, role);
        string memory absent = string.concat(".checked.", role, "Absent");
        if (!_has(record, absent) || !vm.parseJsonBool(record, absent)) return (true, _checked(unit, role));
        require(
            _addr(record, string.concat(".checked.", role)).code.length == 0,
            string.concat(role, " has code since ", unit, ".json recorded it absent: a person must resolve it")
        );
    }

    function _checkedRecord(string memory unit, string memory role) private view returns (string memory record) {
        string memory path = string.concat(_dir(), "/", unit, ".json");
        record = vm.exists(path) ? vm.readFile(path) : "{}";
        require(_has(record, ".checked"), string.concat(unit, ".json is unchecked: run its check step"));
        string memory chainKey = string.concat(".checked.", role, "ChainId");
        require(
            _uint(record, _has(record, chainKey) ? chainKey : string.concat(".checked", _stampKey(_networkJson())))
                == block.chainid,
            string.concat(unit, ".json was checked on another chain")
        );
    }

    /// @dev Writes `checked` when `_writing()` and the journal does not already hold an equal one.
    ///      Equality ignores the values of the fixed keys `evmBlock`, `l1Block` and `l2Block`: a block
    ///      records where the role was first certified, so a rerun leaves the journal byte for byte.
    function _certify(string memory checked) internal {
        if (!_writing()) return;
        string memory journal = _journal();
        if (_has(journal, ".checked") && _sameIdentity(journal, checked)) return;
        if (_inProbe()) revert StepDue();
        vm.writeJson(checked, _path(), ".checked");
    }

    /// @dev Starts the certificate object for `role` at `at` with `evmBlock`, the default chain's
    ///      id, the role's address and, when the unit has an input file, `inputHash`
    ///      (`unitInputHash`): a plan judges a certificate of other inputs stale. The caller adds its own
    ///      keys and ends with `_certify`. Forge keeps a serialized object for the whole run, so it starts
    ///      empty: no key of an earlier check in the same run survives into this certificate.
    function _beginChecked(string memory role, address addr) internal returns (string memory obj) {
        obj = string.concat(role, "-checked");
        vm.serializeJson(obj, "{}");
        vm.serializeUint(obj, "evmBlock", block.number);
        vm.serializeUint(obj, string.concat(_defaultChain(_networkJson()), "ChainId"), block.chainid);
        bytes32 input = unitInputHash(_networkName(), _unit());
        if (input != 0) vm.serializeBytes32(obj, "inputHash", input);
        vm.serializeAddress(obj, role, addr);
    }

    /// @dev The script that a refusal's recovery command names: the one `Deploy*.s.sol` in the
    ///      unit's directory. A broadcast record may come from any script that sent the CREATE, so
    ///      the command cannot take the script from the record.
    function _defaultDeployScript() internal view returns (string memory script) {
        string memory dir = string.concat(pathIn(_project(), "units"), "/", _unit(), "/");
        VmSafe.DirEntry[] memory files = vm.readDir(dir);
        uint256 found;
        for (uint256 i; i < files.length; ++i) {
            string[] memory parts = vm.split(slashed(files[i].path), "/");
            string memory name = parts[parts.length - 1];
            if (vm.indexOf(name, "Deploy") == 0 && _endsWith(name, ".s.sol")) {
                script = string.concat(dir, name);
                ++found;
            }
        }
        require(found == 1, string.concat(dir, " must hold exactly one Deploy*.s.sol"));
    }

    /// @dev Reads only the environment, which cannot see `foundry.toml`: the runner checks
    ///      `forge config` too.
    function _requireOutput(string memory label, string memory variable, string memory unset, string memory expected)
        internal
        view
    {
        string memory actual = vm.envOr(variable, unset);
        require(
            keccak256(bytes(actual)) == keccak256(bytes(expected)),
            string.concat(
                "forge would keep this run's ", label, " in ", actual, ", not ", expected, ": run it as plan prints"
            )
        );
    }

    /// @dev The RPC server this forge script sends to, however forge resolved it (a `FOUNDRY_*` variable
    ///      beats `--rpc-url`), is Anvil exactly when the network is a rehearsal one, unless the chain is
    ///      local. The runner checks the server it resolves; this checks the one the sends reach. Only a
    ///      broadcast sends: a dry run, or a simulated rehearsal against a server other than Anvil, stays
    ///      legitimate. `--resume` sends the cached transactions without this check.
    function _requireClient() internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;
        if (keccak256(bytes(chainKindIn(_project(), block.chainid))) == keccak256("local")) return;
        bool anvil = vm.indexOf(abi.decode(vm.rpc("web3_clientVersion", "[]"), (string)), "anvil/") == 0;
        bool rehearsal = isRehearsalNetworkIn(rehearsalPrefixIn(_project()), _networkName());
        string memory why = rehearsal
            ? " is not served by Anvil, which a rehearsal network requires"
            : " is served by Anvil, a development node: rehearse on a rehearsal network";
        require(anvil == rehearsal, string.concat("chain ", vm.toString(block.chainid), why));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {chainId, chainKind, defaultChain, deploymentsDir, planRpc, rehearsalPrefix} from "./Chains.sol";
import {cheats} from "./DeployChecks.sol";
import {IProbe} from "./graph/Step.sol";

/// @dev The unit's own parameters, `<root>/<network>/<unit>.input.json`.
function inputPath(string memory root, string memory network, string memory unit) pure returns (string memory) {
    return string.concat(root, "/", network, "/", unit, ".input.json");
}

/// @dev True for the rehearsal prefix itself and for `<prefix>-<suffix>`. A name that merely starts
///      with the prefix, such as `<prefix>ing`, is a real network.
function isRehearsalNetwork(string memory network) view returns (bool) {
    bytes memory name = bytes(network);
    bytes memory test = bytes(rehearsalPrefix());
    if (name.length < test.length || (name.length > test.length && name[test.length] != "-")) return false;
    for (uint256 i; i < test.length; ++i) {
        if (name[i] != test[i]) return false;
    }
    return true;
}

/// @dev The assignments that keep forge's records and resume data under a rehearsal network's `dir`:
///      a fork can keep a live chain id, and a live `--resume` publishes whatever snapshot
///      `<cache_path>/<script>/<chain id>/` holds as the live records. The trailing space lets a caller
///      prepend the assignments to a command.
function outputsEnv(string memory dir) pure returns (string memory) {
    return string.concat("FOUNDRY_BROADCAST=", dir, "/broadcast FOUNDRY_CACHE_PATH=", dir, "/cache ");
}

function unitInputPath(string memory network, string memory unit) view returns (string memory) {
    return inputPath(deploymentsDir(), network, unit);
}

/// @dev The hash a certificate records of `unit`'s input on `network`, read where the graph reads it: of the
///      parsed JSON, whose keys forge orders, so that a formatting edit leaves it. Zero without the file.
function unitInputHash(string memory network, string memory unit) view returns (bytes32) {
    string memory path = unitInputPath(network, unit);
    return cheats.exists(path) ? keccak256(cheats.parseJson(cheats.readFile(path))) : bytes32(0);
}

/// @dev A `vm.readDir` entry's path with `/` throughout. On Windows readDir joins each name below the root
///      with `\`; on Unix a `\` is a name's own character, so the path stays as it is.
function slashed(string memory path) view returns (string memory) {
    return bytes(cheats.projectRoot())[0] == "/" ? path : cheats.replace(path, "\\", "/");
}

/// @dev Replaces the deployments directory's `<to>` with a copy of the files of its `<from>`, inputs
///      included. Subdirectories are not copied.
function stageInputs(string memory from, string memory to) {
    require(isRehearsalNetwork(to), "only a git-ignored rehearsal network is staged");
    string memory root = deploymentsDir();
    string memory dir = string.concat(root, "/", to);
    if (cheats.exists(dir)) cheats.removeDir(dir, true);
    cheats.createDir(dir, true);
    VmSafe.DirEntry[] memory files = cheats.readDir(string.concat(root, "/", from));
    for (uint256 i; i < files.length; ++i) {
        string[] memory path = cheats.split(slashed(files[i].path), "/");
        if (!files[i].isDir) cheats.copyFile(files[i].path, string.concat(dir, "/", path[path.length - 1]));
    }
}

/// @dev An input file's JSON and the unit it belongs to, which a refusal names.
struct Input {
    string json;
    string unit;
}

/// @dev A certificate a `check` step builds: `Deployment._certificate` starts it for its role, each
///      `with...` adds a key, and `Deployment._certify` writes it.
struct Certificate {
    string obj;
    string role;
    address addr;
}

using {withAddress, withCode, withUint, withBytes32, withString} for Certificate global;

function withAddress(Certificate memory c, string memory key, address value) returns (Certificate memory) {
    cheats.serializeAddress(c.obj, key, value);
    return c;
}

/// @dev `key` and `<key>CodeHash`, which `Journal._checked` compares for the address it returns.
function withCode(Certificate memory c, string memory key, address value) returns (Certificate memory) {
    cheats.serializeAddress(c.obj, key, value);
    cheats.serializeBytes32(c.obj, string.concat(key, "CodeHash"), value.codehash);
    return c;
}

function withUint(Certificate memory c, string memory key, uint256 value) returns (Certificate memory) {
    cheats.serializeUint(c.obj, key, value);
    return c;
}

function withBytes32(Certificate memory c, string memory key, bytes32 value) returns (Certificate memory) {
    cheats.serializeBytes32(c.obj, key, value);
    return c;
}

function withString(Certificate memory c, string memory key, string memory value) returns (Certificate memory) {
    cheats.serializeString(c.obj, key, value);
    return c;
}

/// @dev A unit's journal `<unit>.json` records what the unit deployed and certified. The unit's
///      inputs, `<unit>.input.json`, and the network's `network.json` sit beside it.
abstract contract Journal is Script, IProbe {
    string internal _usedNetwork;
    /// @dev Set only inside `probe`, whose revert clears it.
    bool private _probing;

    /// @dev The step's first broadcast (`_startBroadcast`) or journal write (`_put`, `_certify`) reverts
    ///      with `StepDue`. While the prank is active forge refuses `vm.startBroadcast` and
    ///      `vm.broadcast`, so a step that calls them directly cannot queue a transaction: forge keeps
    ///      the transactions of a reverted call in the dry run, which `--resume` would send.
    function probe(bytes calldata step, address sender) external {
        _probing = true;
        vm.startPrank(sender, sender);
        (bool returned, bytes memory result) = address(this).call(step);
        vm.stopPrank();
        revert Probed(returned, result);
    }

    function probes() external pure returns (bytes4) {
        return IProbe.probe.selector;
    }

    function _inProbe() internal view returns (bool) {
        return _probing;
    }

    /// @dev The journal's name without `.json`; also the prefix of the unit's input file.
    function _unit() internal pure virtual returns (string memory);

    function unitName() external pure returns (string memory) {
        return _unit();
    }

    /// @dev The directory that holds one subdirectory per network. An override changes where the unit
    ///      reads and writes (`_dir`, `_unitInput`). It does not change `unitInputPath`,
    ///      `stageInputs` or the graph's input reads, which always use `paths.deployments`.
    function _deployments() internal view virtual returns (string memory);

    /// @dev The graph script that the `next:` line printed by `_done` names.
    function _graphScript() internal view virtual returns (string memory);

    /// @dev The chain whose id stamps the journal (`<chain>ChainId`). Virtual so that a test can
    ///      choose its own rule.
    function _defaultChain(string memory network) internal view virtual returns (string memory) {
        return defaultChain(network);
    }

    function _networkName() internal view virtual returns (string memory) {
        return _usedNetwork;
    }

    /// @dev Sets the network the unit works on. Reverts on an empty name, and on a send or dry run
    ///      whose environment puts forge's records (on a rehearsal network, also its resume data)
    ///      elsewhere than the network's.
    function _adopt(string memory network) internal {
        require(bytes(network).length != 0, string.concat("name the network: a directory under ", _deployments(), "/"));
        _usedNetwork = network;
        // Here and not in `_use`: a step that selects its own forks never calls `_use`. A dry run too, the
        // graph's plan and rehearse included: `--resume` sends a saved dry run when no broadcast was
        // saved, and no caller tells a `Due` view from a step that broadcasts. A probe queues no
        // transaction, and the runner checks the step's own command.
        if (
            !_probing
                && (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptDryRun))
        ) {
            _requireOutput("records", "FOUNDRY_BROADCAST", "broadcast", _records());
            if (_rehearsal()) {
                _requireOutput("resume data", "FOUNDRY_CACHE_PATH", "cache", string.concat(_dir(), "/cache"));
            }
        }
    }

    /// @notice The first call of a unit step. `network` names a directory under the deployments path.
    ///         Reverts unless the selected chain is the network's default chain (`sprue.json`'s
    ///         `chains.default`, else the network's only chain), before it reads the unit's own
    ///         journal. Returns that journal.
    function _use(string memory network) internal returns (string memory journal) {
        _adopt(network);
        string memory path = string.concat(_dir(), "/network.json");
        require(vm.exists(path), string.concat(path, " is missing: name a network under ", _deployments(), "/"));
        string memory file = vm.readFile(path);
        require(
            block.chainid == chainId(file, _defaultChain(file)),
            string.concat("the RPC's chain is not ", network, "'s default chain")
        );
        _requireClient();
        journal = _journal();
        string memory stamp = _stampKey(file);
        if (_has(journal, stamp)) require(_uint(journal, stamp) == block.chainid, "the journal is another chain's");
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
        if (keccak256(bytes(chainKind(block.chainid))) == keccak256("local")) return;
        bool anvil = vm.indexOf(abi.decode(vm.rpc("web3_clientVersion", "[]"), (string)), "anvil/") == 0;
        bool rehearsal = isRehearsalNetwork(_networkName());
        string memory why = rehearsal
            ? " is not served by Anvil, which a rehearsal network requires"
            : " is served by Anvil, a development node: rehearse on a rehearsal network";
        require(anvil == rehearsal, string.concat("chain ", vm.toString(block.chainid), why));
    }

    /// @dev The journal's chain stamp is `<default chain>ChainId`, the key `_selectChain` checks for that chain.
    function _stampKey(string memory network) internal view returns (string memory) {
        return string.concat(".", _defaultChain(network), "ChainId");
    }

    /// @dev The chain a step has selected, which a deployment's stamp names. A unit that selects
    ///      other chains tracks the last one.
    function _selectedChain() internal view virtual returns (string memory) {
        return _defaultChain(_networkJson());
    }

    function _selectedStampKey() internal view returns (string memory) {
        return string.concat(".", _selectedChain(), "ChainId");
    }

    function _putChainStamp() internal {
        _put(_selectedStampKey(), vm.toString(block.chainid));
    }

    /// @notice The last call of a unit step. It logs what happened (nothing to send, simulated, or
    ///         sent), the `git add` command for the files to commit, and the `plan` command to run
    ///         next, which it returns. The graph owns the order, so a step never names its
    ///         successor.
    function _done(bool sends) internal returns (string memory command) {
        _stepEnded();
        if (_probing) return "";
        if (!sends) console.log("nothing to send");
        else if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) console.log("broadcasting");
        else console.log("simulated: rerun with --broadcast to send");
        console.log(string.concat("git add ", _dir(), " broadcast"));
        command = string.concat(
            isRehearsalNetwork(_networkName()) ? outputsEnv(_dir()) : "",
            "forge script ",
            _graphScript(),
            " --sig 'plan(string,string)' ",
            _networkName(),
            " <node> --rpc-url ",
            planRpc(_networkJson())
        );
        console.log(string.concat("next: ", command));
    }

    /// @dev Called by `_done`, so that the next step of a run starts afresh.
    function _stepEnded() internal virtual {}

    // ==== Files ====

    function _networkJson() internal view returns (string memory) {
        return vm.readFile(string.concat(_dir(), "/network.json"));
    }

    /// @dev The unit's own parameters, `_deployments()/<network>/<unit>.input.json`.
    function _unitInput() internal view returns (string memory) {
        return vm.readFile(inputPath(_deployments(), _networkName(), _unit()));
    }

    /// @dev `unit`'s input file on this network, for the readers below, whose refusals then name it.
    function _inputFile(string memory unit) internal view returns (Input memory) {
        return Input(vm.readFile(inputPath(_deployments(), _networkName(), unit)), unit);
    }

    /// @dev Reads a string field of `json`. Reverts if it is empty or a placeholder, a value that
    ///      starts with `<` in an input file waiting to be filled in.
    function _decided(string memory json, string memory key) internal pure returns (string memory) {
        return _decided(Input(json, _unit()), key);
    }

    function _decided(Input memory input, string memory key) internal pure returns (string memory v) {
        v = vm.parseJsonString(input.json, string.concat(".", key));
        require(
            bytes(v).length != 0 && bytes(v)[0] != "<",
            string.concat(input.unit, ".input.json's ", key, " is a placeholder: fill it in and commit it")
        );
    }

    function _inputUint(string memory json, string memory key, uint256 min, uint256 max)
        internal
        pure
        returns (uint256)
    {
        return _inputUint(Input(json, _unit()), key, min, max);
    }

    function _inputUint(Input memory input, string memory key, uint256 min, uint256 max)
        internal
        pure
        returns (uint256 v)
    {
        v = vm.parseUint(_decided(input, key));
        require(v >= min && v <= max, string.concat(input.unit, ".input.json's ", key, " is out of range"));
    }

    /// @dev `key` may be a path such as `creators[0]`. The zero address is never a valid input.
    function _requiredAddress(string memory json, string memory key) internal pure returns (address) {
        return _requiredAddress(Input(json, _unit()), key);
    }

    function _requiredAddress(Input memory input, string memory key) internal pure returns (address a) {
        a = vm.parseAddress(_decided(input, key));
        require(
            a != address(0),
            string.concat(input.unit, ".input.json's ", key, " is the zero placeholder: supply the required address")
        );
    }

    function _dir() internal view returns (string memory) {
        return string.concat(_deployments(), "/", _networkName());
    }

    /// @dev The directory of broadcast records, with `<script>/<chain id>/<step>-latest.json`
    ///      beneath it. A rehearsal network keeps its own, so that a fork keeping a public chain id
    ///      never reads or writes that chain's. `forge test` writes none, so a test keeps its own
    ///      too, where no local run's record can reach it. `_adopt` refuses a send or dry run whose
    ///      records forge would write elsewhere.
    function _records() internal view returns (string memory) {
        return
            vm.isContext(VmSafe.ForgeContext.Test) || _rehearsal() ? string.concat(_dir(), "/broadcast") : "broadcast";
    }

    function _path() internal view returns (string memory) {
        return string.concat(_dir(), "/", _unit(), ".json");
    }

    /// @dev A missing journal reads as empty; the first `_put` creates it.
    function _journal() internal view returns (string memory) {
        string memory p = _path();
        return vm.exists(p) ? vm.readFile(p) : "{}";
    }

    function _put(string memory key, string memory value) internal virtual {
        if (_probing) revert StepDue();
        string memory p = _path();
        if (!vm.exists(p)) {
            vm.createDir(_dir(), true);
            vm.writeFile(p, "{}");
        }
        vm.writeJson(value, p, key);
    }

    function _has(string memory json, string memory key) internal view returns (bool) {
        return vm.keyExistsJson(json, key);
    }

    function _addr(string memory json, string memory key) internal pure returns (address) {
        return vm.parseJsonAddress(json, key);
    }

    function _uint(string memory json, string memory key) internal pure returns (uint256) {
        return vm.parseJsonUint(json, key);
    }

    /// @dev Whether `_networkName()` is a rehearsal network, whose journals simulated runs write too.
    function _rehearsal() internal view virtual returns (bool);

    /// @dev Whether this run records deployments in the journal: a broadcast, a resumed broadcast,
    ///      or any run on a rehearsal network. `_certify` consults it. True in a probe, which judges the
    ///      step as its send would run, and refuses the write itself.
    function _writing() internal view virtual returns (bool) {
        return _probing || vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            || vm.isContext(VmSafe.ForgeContext.ScriptResume) || _rehearsal();
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

    /// @dev Checked before the code hash: an RPC that lags behind the node that took the send shows no
    ///      code, which is not other code.
    function _requireCode(address addr, string memory role) internal view {
        require(
            addr.code.length != 0,
            string.concat(
                role,
                " at ",
                vm.toString(addr),
                " has no code: if the RPC lags behind the chain, run again once it shows the deployment"
            )
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

    /// @dev Adds to the certificate `obj` that `role` is absent: `at`, where it would be, has no code.
    ///      Returns the object's JSON so far. `_checked` refuses the role; `_checkedOptional` reads it.
    function _recordAbsent(string memory obj, string memory role, address at) internal returns (string memory) {
        require(at.code.length == 0, string.concat(role, " has code: certify it instead"));
        vm.serializeAddress(obj, role, at);
        return vm.serializeBool(obj, string.concat(role, "Absent"), true);
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
        if (_probing) revert StepDue();
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

    /// @dev Ends the certificate `obj` of a unit that certifies one role, on that role's code hash.
    function _certifyRole(string memory obj, string memory role, address addr) internal returns (string memory) {
        _certify(vm.serializeBytes32(obj, string.concat(role, "CodeHash"), addr.codehash));
        return _done(false);
    }

    function _isBlockKey(string memory key) private pure returns (bool) {
        bytes32 h = keccak256(bytes(key));
        return h == keccak256("evmBlock") || h == keccak256("l1Block") || h == keccak256("l2Block");
    }

    function _sameIdentity(string memory journal, string memory checked) private view returns (bool) {
        string[] memory keys = vm.parseJsonKeys(checked, "$");
        if (vm.parseJsonKeys(journal, ".checked").length != keys.length) return false;
        for (uint256 i; i < keys.length; ++i) {
            string memory key = string.concat(".", keys[i]);
            string memory recorded = string.concat(".checked", key);
            if (!_has(journal, recorded)) return false;
            if (_isBlockKey(keys[i])) continue;
            if (keccak256(vm.parseJson(journal, recorded)) != keccak256(vm.parseJson(checked, key))) return false;
        }
        return true;
    }
}

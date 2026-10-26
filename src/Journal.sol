// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {
    chainId,
    chainKind,
    defaultChain,
    deploymentsDir,
    planRpc,
    rehearsalPrefix,
    rememberProject
} from "./Chains.sol";
import {cheats} from "./DeployChecks.sol";
import {IProbe} from "./graph/Step.sol";

/// @dev The unit's own parameters, `<root>/<network>/<unit>.input.json`.
function inputPath(string memory root, string memory network, string memory unit) pure returns (string memory) {
    return string.concat(root, "/", network, "/", unit, ".input.json");
}

/// @dev True for the rehearsal prefix itself and for `<prefix>-<suffix>`. A name that merely starts
///      with the prefix, such as `<prefix>ing`, is a real network.
function isRehearsalNetwork(string memory network) view returns (bool) {
    return isRehearsalNetworkIn(rehearsalPrefix(), network);
}

function isRehearsalNetworkIn(string memory prefix, string memory network) pure returns (bool) {
    bytes memory name = bytes(network);
    bytes memory test = bytes(prefix);
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
    /// @dev From `_adopt` to `_done`: what a step learned is valid only inside it.
    bool internal _stepOpen;
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

    function _inProbe() internal view virtual returns (bool) {
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
    function _defaultChain(string memory network) internal view virtual returns (string memory);

    function _networkName() internal view virtual returns (string memory) {
        return _usedNetwork;
    }

    /// @dev Sets the network the unit works on. Reverts on an empty name, and on a send or dry run
    ///      whose environment puts forge's records (on a rehearsal network, also its resume data)
    ///      elsewhere than the network's.
    function _adopt(string memory network) internal {
        rememberProject();
        require(bytes(network).length != 0, string.concat("name the network: a directory under ", _deployments(), "/"));
        _usedNetwork = network;
        _stepOpen = true;
        // Here and not in `_use`: a step that selects its own forks never calls `_use`. A dry run too, the
        // graph's plan and rehearse included: `--resume` sends a saved dry run when no broadcast was
        // saved, and no caller tells a `Due` view from a step that broadcasts. A probe queues no
        // transaction, and the runner checks the step's own command.
        if (
            !_inProbe()
                && (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptDryRun))
        ) _checkOutputs();
    }

    /// @dev The refusal of a send or dry run whose forge would keep its records elsewhere than the network's.
    function _checkOutputs() internal virtual;

    /// @dev The journal's chain stamp is `<default chain>ChainId`, the key `_selectChain` checks for that chain.
    function _stampKey(string memory network) internal view returns (string memory) {
        return string.concat(".", _defaultChain(network), "ChainId");
    }

    /// @dev The chain a step has selected, which a deployment's stamp names. A unit that selects
    ///      other chains tracks the last one.
    function _selectedChain() internal view virtual returns (string memory) {
        return "";
    }

    function _selectedStampKey() internal view returns (string memory) {
        return string.concat(".", _selectedChain(), "ChainId");
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
        if (_inProbe()) revert StepDue();
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
        return _inProbe() || vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            || vm.isContext(VmSafe.ForgeContext.ScriptResume) || _rehearsal();
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

    /// @dev Adds to the certificate `obj` that `role` is absent: `at`, where it would be, has no code.
    ///      Returns the object's JSON so far. `_checked` refuses the role; `_checkedOptional` reads it.
    function _recordAbsent(string memory obj, string memory role, address at) internal returns (string memory) {
        require(at.code.length == 0, string.concat(role, " has code: certify it instead"));
        vm.serializeAddress(obj, role, at);
        return vm.serializeBool(obj, string.concat(role, "Absent"), true);
    }

    function _isBlockKey(string memory key) internal pure returns (bool) {
        bytes32 h = keccak256(bytes(key));
        return h == keccak256("evmBlock") || h == keccak256("l1Block") || h == keccak256("l2Block");
    }

    function _sameIdentity(string memory journal, string memory checked) internal view returns (bool) {
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

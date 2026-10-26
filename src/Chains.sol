// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {cheats} from "./DeployChecks.sol";
import {engine} from "./SprueEngine.sol";

// A network's chains by name, from the `chains` map of its `network.json`. Each chain names its RPC by a
// `foundry.toml` `[rpc_endpoints]` alias, never a URL, which may carry an API key. Only a rehearsal copy
// holds URLs: the loopback URLs of the forks that `rehearse` started.

function chainId(string memory network, string memory chain) view returns (uint256) {
    return cheats.parseJsonUint(network, string.concat(".chains.", chain, ".id"));
}

/// @dev The `rpc` a chain names, or empty.
function chainAlias(string memory network, string memory chain) view returns (string memory) {
    string memory key = string.concat(".chains.", chain, ".rpc");
    return cheats.keyExistsJson(network, key) ? cheats.parseJsonString(network, key) : "";
}

/// @dev The RPC URL of `chain`, resolved from its `rpc` through `foundry.toml`. A chain the network
///      lacks is empty if `optional`; a chain without `rpc` always reverts.
function chainRpc(string memory network, string memory chain, bool optional) view returns (string memory) {
    if (!cheats.keyExistsJson(network, string.concat(".chains.", chain))) {
        require(optional, string.concat("network.json lacks chain ", chain));
        return "";
    }
    string memory rpc = chainAlias(network, chain);
    require(bytes(rpc).length != 0, noRpc(chain));
    return cheats.rpcUrl(rpc);
}

/// @dev The `rpc` that `plan` reads: the default chain's, else the first chain's. Never
///      reverts: a step prints it after it sends.
function planRpc(string memory network) view returns (string memory) {
    return planRpcIn(projectJson(), network);
}

function planRpcIn(string memory project, string memory network) view returns (string memory rpc) {
    string memory chain =
        cheats.keyExistsJson(project, ".chains.default") ? cheats.parseJsonString(project, ".chains.default") : "";
    if (bytes(chain).length == 0 || !cheats.keyExistsJson(network, string.concat(".chains.", chain))) {
        string[] memory chains =
            cheats.keyExistsJson(network, ".chains") ? cheats.parseJsonKeys(network, ".chains") : new string[](0);
        chain = chains.length == 0 ? "" : chains[0];
    }
    rpc = bytes(chain).length == 0 ? "" : chainAlias(network, chain);
}

function noRpc(string memory chain) pure returns (string memory) {
    return string.concat(
        "network.json's chain ", chain, " names no rpc: give it an alias from foundry.toml's [rpc_endpoints]"
    );
}

/// @dev The chain a step without `.on` sends on: `chains.default` of `sprue.json`, which the network
///      must have, else the network's only chain. Empty when there is neither, as in a network of
///      several chains with no `chains.default`.
function defaultChainOrNone(string memory network) view returns (string memory) {
    return defaultChainIn(projectJson(), network);
}

/// @dev As `defaultChainOrNone`, but reverts when there is none.
function defaultChain(string memory network) view returns (string memory) {
    string memory chain = defaultChainOrNone(network);
    require(bytes(chain).length != 0, "network.json has several chains and sprue.json sets no chains.default");
    return chain;
}

function defaultChainIn(string memory json, string memory network) view returns (string memory) {
    if (cheats.keyExistsJson(json, ".chains.default")) {
        string memory chain = cheats.parseJsonString(json, ".chains.default");
        require(
            cheats.keyExistsJson(network, string.concat(".chains.", chain)),
            string.concat("network.json lacks sprue.json's default chain ", chain)
        );
        return chain;
    }
    string[] memory chains =
        cheats.keyExistsJson(network, ".chains") ? cheats.parseJsonKeys(network, ".chains") : new string[](0);
    return chains.length == 1 ? chains[0] : "";
}

string constant PROJECT_FILE = "sprue.json";

/// @dev Whether the selected chain is a test chain or a local one, where test-only units may run.
function isTestChain() view returns (bool) {
    return isTestChainId(block.chainid);
}

function isTestChainId(uint256 id) view returns (bool) {
    string memory json = projectJson();
    return _listed(json, ".chains.local", id) || _listed(json, ".chains.test", id);
}

/// @dev True for a live chain with no entry in `chains.unrecordedDeploys`. An entry marks a live
///      chain where some CREATE of the deploy key has no record, and its value says why. Test and
///      local chains are never fenced.
function isFencedChainId(uint256 id) view returns (bool) {
    return !isTestChainId(id)
        && !cheats.keyExistsJson(
        projectJson(), string.concat(".chains.unrecordedDeploys[\"", cheats.toString(id), "\"]")
    );
}

/// @dev Derived from `sprue.json` by chain id and never stored, so no edit to a journal changes it.
function chainKind(uint256 id) view returns (string memory) {
    return chainKindIn(projectJson(), id);
}

function chainKindIn(string memory json, uint256 id) pure returns (string memory) {
    if (_listed(json, ".chains.local", id)) return "local";
    return _listed(json, ".chains.test", id) ? "test" : "live";
}

/// @dev Where the project keeps its journals: a directory with one subdirectory per network.
function deploymentsDir() view returns (string memory) {
    return pathIn(projectJson(), "deployments");
}

function unitsDir() view returns (string memory) {
    return pathIn(projectJson(), "units");
}

/// @dev The project's graph script, which a unit's `next:` line names.
function graphScript() view returns (string memory) {
    return pathIn(projectJson(), "graph");
}

/// @dev A rehearsal network is `<prefix>` or `<prefix>-<suffix>`: the only names `stageInputs`
///      writes to. `paths.rehearsal` is `<deployments>/<prefix>`.
function rehearsalPrefix() view returns (string memory) {
    return rehearsalPrefixIn(projectJson());
}

function pathIn(string memory json, string memory key) pure returns (string memory) {
    return cheats.parseJsonString(json, string.concat(".paths.", key));
}

/// @dev Does not validate. Call it only on JSON that `validatedProject` accepted.
function rehearsalPrefixIn(string memory json) pure returns (string memory) {
    bytes memory path = bytes(pathIn(json, "rehearsal"));
    bytes memory name = new bytes(path.length - bytes(pathIn(json, "deployments")).length - 1);
    for (uint256 i; i < name.length; ++i) {
        name[i] = path[path.length - name.length + i];
    }
    return string(name);
}

/// @dev Reads `sprue.json` and reverts unless its shape is exactly the one validated here, so that a
///      malformed policy never opens a send path. An `unrecordedDeploys` reason may not start with
///      `0x`: Foundry would read it as bytes. `sprue` validates `paths` itself, because it needs
///      them before forge can run; this is the only full check of `chains`.
///      A contract that called `rememberProject` skips the check while the file's bytes are the ones it
///      validated.
function projectJson() view returns (string memory json) {
    json = cheats.readFile(PROJECT_FILE);
    bytes32 slot = PROJECT_CHECKED_SLOT;
    bytes32 checked;
    assembly ("memory-safe") {
        checked := sload(slot)
    }
    if (checked != keccak256(bytes(json))) engine().validateProject(PROJECT_FILE);
}

/// @dev Where a contract keeps the hash of the `sprue.json` it validated. Each step validates it once:
///      a full check costs dozens of cheatcodes, and a step reads the file in nearly every journal access.
bytes32 constant PROJECT_CHECKED_SLOT = keccak256("sprue.project.checked");

/// @dev The hash a contract remembered, which a call to the engine carries so that the engine does not validate
///      the file again.
function checkedProject() view returns (bytes32 checked) {
    bytes32 slot = PROJECT_CHECKED_SLOT;
    assembly ("memory-safe") {
        checked := sload(slot)
    }
}

function rememberProject() {
    bytes32 hash = keccak256(bytes(engine().validateProject(PROJECT_FILE)));
    bytes32 slot = PROJECT_CHECKED_SLOT;
    assembly ("memory-safe") {
        sstore(slot, hash)
    }
}

function validatedProject(string memory path) view returns (string memory json) {
    json = cheats.readFile(path);
    require(
        cheats.parseJsonKeys(json, ".").length == 2 && cheats.keyExistsJson(json, ".paths")
            && cheats.keyExistsJson(json, ".chains"),
        "sprue.json is not exactly paths and chains"
    );
    require(
        cheats.parseJsonKeys(json, ".paths").length == 4
            && cheats.parseJsonKeys(json, ".chains").length == (cheats.keyExistsJson(json, ".chains.default") ? 4 : 3)
            && cheats.keyExistsJson(json, ".chains.local") && cheats.keyExistsJson(json, ".chains.test")
            && cheats.keyExistsJson(json, ".chains.unrecordedDeploys"),
        "sprue.json: unknown or missing key under paths or chains"
    );
    string[4] memory keys = ["graph", "units", "deployments", "rehearsal"];
    for (uint256 i; i < keys.length; ++i) {
        string memory key = string.concat(".paths.", keys[i]);
        string memory path = cheats.keyExistsJson(json, key) ? pathIn(json, keys[i]) : "";
        require(
            bytes(path).length != 0 && _encodes(json, key, abi.encode(path)) && _shellSafe(path),
            "sprue.json: paths must be nonempty strings using only A-Z a-z 0-9 _ . / -"
        );
    }
    string memory prefix = pathIn(json, "deployments");
    require(
        bytes(pathIn(json, "rehearsal")).length > bytes(prefix).length + 1
            && cheats.indexOf(pathIn(json, "rehearsal"), string.concat(prefix, "/")) == 0
            && _plainName(rehearsalPrefixIn(json)),
        "sprue.json: paths.rehearsal is not <paths.deployments>/<lower-case name>"
    );
    if (cheats.keyExistsJson(json, ".chains.default")) {
        string memory chain = cheats.parseJsonString(json, ".chains.default");
        require(
            _encodes(json, ".chains.default", abi.encode(chain)) && _plainName(chain)
                && cheats.indexOf(chain, "-") == type(uint256).max,
            "sprue.json: chains.default is not a chain name"
        );
    }
    // The typed readers coerce "31337" and false into numbers. Comparing the raw encoding with the
    // typed one rejects a value of the wrong JSON type.
    require(
        _encodes(json, ".chains.local", abi.encode(cheats.parseJsonUintArray(json, ".chains.local")))
            && _encodes(json, ".chains.test", abi.encode(cheats.parseJsonUintArray(json, ".chains.test")))
            && !_listed(json, ".chains.local", 0) && !_listed(json, ".chains.test", 0),
        "sprue.json: a chain list holds a non-number or 0"
    );
    string[] memory ids = cheats.parseJsonKeys(json, ".chains.unrecordedDeploys");
    for (uint256 i; i < ids.length; ++i) {
        require(
            bytes(ids[i]).length != 0 && bytes(ids[i])[0] != "0"
                && keccak256(bytes(cheats.toString(cheats.parseUint(ids[i])))) == keccak256(bytes(ids[i])),
            "sprue.json: an exemption is not a decimal id"
        );
        string memory key = string.concat(".chains.unrecordedDeploys[\"", ids[i], "\"]");
        string memory reason = cheats.parseJsonString(json, key);
        require(
            bytes(reason).length != 0 && _encodes(json, key, abi.encode(reason)),
            "sprue.json: an exemption has no reason, or it starts with 0x"
        );
    }
}

/// @dev Plan lines carry paths unquoted, so a path holds no character that a shell acts on.
function _shellSafe(string memory path) pure returns (bool) {
    bytes memory b = bytes(path);
    for (uint256 i; i < b.length; ++i) {
        bytes1 c = b[i];
        if (!(c == "_" || c == "." || c == "/" || c == "-" || (c >= "0" && c <= "9") || (c >= "a" && c <= "z")
                    || (c >= "A" && c <= "Z"))) return false;
    }
    return true;
}

/// @dev What the runner accepts of a network name: `[a-z0-9-]`, not starting with `-`.
function _plainName(string memory name) pure returns (bool) {
    bytes memory b = bytes(name);
    if (b.length == 0 || b[0] == "-") return false;
    for (uint256 i; i < b.length; ++i) {
        bytes1 c = b[i];
        if (!(c == "-" || (c >= "0" && c <= "9") || (c >= "a" && c <= "z"))) return false;
    }
    return true;
}

function _encodes(string memory json, string memory key, bytes memory typed) pure returns (bool) {
    return keccak256(cheats.parseJson(json, key)) == keccak256(typed);
}

function _listed(string memory json, string memory key, uint256 id) pure returns (bool) {
    uint256[] memory ids = cheats.parseJsonUintArray(json, key);
    for (uint256 i; i < ids.length; ++i) {
        if (ids[i] == id) return true;
    }
    return false;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {console} from "forge-std/console.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {
    chainAlias,
    chainId,
    chainKind,
    defaultChainOrNone,
    deploymentsDir,
    isTestChain,
    noRpc,
    rehearsalPrefix
} from "./Chains.sol";
import {isRehearsalNetwork, outputsEnv, slashed, stageInputs, unitInputPath} from "./Journal.sol";
import {Graph} from "./graph/Graph.sol";

/// @notice Implements `Graph`'s hooks from the files in `<paths.deployments>/<network>/`. A project's
///         graph script inherits it.
abstract contract FileGraph is Graph {
    /// @dev `ref` is `<input file>.<key>` in `net`'s inputs, or `network.<key>` for `network.json`.
    ///      Reverts on a placeholder, a value that starts with `<`.
    function _input(string memory net, string memory ref) internal view virtual override returns (string memory value) {
        string[] memory parts = vm.split(ref, ".");
        string memory path = _same(parts[0], "network")
            ? string.concat(deploymentsDir(), "/", net, "/network.json")
            : unitInputPath(net, parts[0]);
        value = vm.parseJsonString(vm.readFile(path), string.concat(".", parts[1]));
        require(
            bytes(value).length == 0 || bytes(value)[0] != "<",
            string.concat(path, "'s ", parts[1], " is a placeholder: fill it in and commit it")
        );
    }

    function _isTestChain() internal view override returns (bool) {
        return isTestChain();
    }

    /// @dev The default chain of a network file, empty when there is none. Virtual so that a test can
    ///      choose its own rule.
    function _homeChain(string memory file) internal view virtual returns (string memory) {
        return defaultChainOrNone(file);
    }

    /// @dev Empty when `chain` is empty and the network has no default chain.
    function _rpcFlag(string memory net, string memory chain) internal view override returns (string memory rpc) {
        string memory file = _networkFile(net);
        string memory named = bytes(chain).length == 0 ? _homeChain(file) : chain;
        if (bytes(named).length == 0) return "";
        rpc = chainAlias(file, named);
        require(bytes(rpc).length != 0, noRpc(named));
    }

    function _commandEnv(string memory net) internal view override returns (string memory) {
        return isRehearsalNetwork(net) ? outputsEnv(string.concat(deploymentsDir(), "/", net)) : "";
    }

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _chainLines(string memory net) internal view override returns (string[] memory lines) {
        require(
            vm.exists(string.concat(deploymentsDir(), "/", net, "/network.json")),
            string.concat("unknown network ", net, ": ", deploymentsDir(), "/", net, "/network.json is missing")
        );
        string memory file = _networkFile(net);
        _homeChain(file);
        if (!vm.keyExistsJson(file, ".chains")) return lines;
        string[] memory chains = vm.parseJsonKeys(file, ".chains");
        lines = new string[](chains.length);
        for (uint256 i; i < chains.length; ++i) {
            uint256 id = chainId(file, chains[i]);
            _requireChain(chains[i], id);
            lines[i] = string.concat("# chain ", chains[i], " ", vm.toString(id), " ", chainKind(id));
        }
    }

    /// @dev One per role whose journaled creation code this build does not make: the role keeps its
    ///      deployment, which a later source edit must not orphan.
    function _warningLines(string memory net, string[] memory units)
        internal
        view
        override
        returns (string[] memory lines)
    {
        lines = new string[](0);
        for (uint256 u; u < units.length; ++u) {
            bool seen;
            for (uint256 v; v < u && !seen; ++v) {
                seen = keccak256(bytes(units[v])) == keccak256(bytes(units[u]));
            }
            if (!seen) lines = _olderRoles(lines, net, units[u]);
        }
    }

    /// @dev `lines` and a line for each role of `unit`'s journal whose code is older than this build.
    function _olderRoles(string[] memory lines, string memory net, string memory unit)
        private
        view
        returns (string[] memory)
    {
        string memory path = string.concat(deploymentsDir(), "/", net, "/", unit, ".json");
        if (!vm.exists(path)) return lines;
        string memory journal = vm.readFile(path);
        // A journal a person edited by hand may not parse: a warning never stops a plan.
        string[] memory keys;
        try vm.parseJsonKeys(journal, "$") returns (string[] memory parsed) {
            keys = parsed;
        } catch {
            return lines;
        }
        for (uint256 k; k < keys.length; ++k) {
            uint256 at = vm.indexOf(keys[k], "CreationCodeHash");
            if (at == type(uint256).max || at + 16 != bytes(keys[k]).length) continue;
            string memory older = _olderCode(journal, unit, vm.replace(keys[k], "CreationCodeHash", ""));
            if (bytes(older).length == 0) continue;
            string[] memory grown = new string[](lines.length + 1);
            for (uint256 i; i < lines.length; ++i) {
                grown[i] = lines[i];
            }
            grown[lines.length] = older;
            lines = grown;
        }
        return lines;
    }

    /// @dev Empty unless `role`'s recorded creation code differs from this build's artifact, which the role's
    ///      `<role>Metadata` file names.
    function _olderCode(string memory journal, string memory unit, string memory role)
        private
        view
        returns (string memory)
    {
        string memory key = string.concat(".", role, "Metadata");
        if (!vm.keyExistsJson(journal, key)) return "";
        string memory metadata;
        bytes32 recorded;
        try vm.parseJsonString(journal, key) returns (string memory value) {
            metadata = value;
        } catch {
            return "";
        }
        try vm.parseJsonBytes32(journal, string.concat(".", role, "CreationCodeHash")) returns (bytes32 value) {
            recorded = value;
        } catch {
            return "";
        }
        string[] memory path = vm.split(metadata, "/");
        string memory artifact = vm.replace(path[path.length - 1], ".metadata.json", "");
        try vm.getCode(string.concat(artifact, ".sol:", artifact)) returns (bytes memory code) {
            if (keccak256(code) == recorded) return "";
        } catch {}
        return string.concat(
            unit,
            ".json's ",
            role,
            " runs code that this build of ",
            artifact,
            " does not make; it stays deployed, and no step replaces it"
        );
    }

    /// @dev Reverts if the step has no chain to send on, or names a chain that `network.json` lacks.
    ///      A step that creates its own forks needs every chain it reads in `network.json`. Any other
    ///      step's script may skip a read chain that a network omits, such as a local one.
    function _requireChains(string memory net, Node storage n) internal view override {
        string memory file = _networkFile(net);
        if (bytes(n.on).length == 0 && bytes(_homeChain(file)).length == 0) {
            revert(string.concat(n.id, " has no chain: add .on(...) to it or set chains.default in sprue.json"));
        }
        if (bytes(n.on).length != 0 && !vm.keyExistsJson(file, string.concat(".chains.", n.on))) {
            revert(string.concat(n.id, " sends on ", n.on, ", which ", net, "'s network.json lacks"));
        }
        for (uint256 i; n.ownForks && i < n.reads.length; ++i) {
            string memory chain = bytes(n.reads[i]).length == 0 ? _homeChain(file) : n.reads[i];
            require(bytes(chain).length != 0, "a step reads the default chain, and sprue.json sets no chains.default");
            if (!vm.keyExistsJson(file, string.concat(".chains.", chain))) {
                revert(string.concat(n.id, " reads ", chain, ", which ", net, "'s network.json lacks"));
            }
        }
    }

    /// @dev A hook for a project's own constraint on a chain's id. Runs for each chain `plan` lists,
    ///      and reverts to refuse. The default accepts every chain.
    function _requireChain(string memory chain, uint256 id) internal view virtual {}

    /// @dev Returns `{}` when `network.json` is missing, so that the lookups that follow do not
    ///      revert first. `_chainLines` reports the missing file.
    function _networkFile(string memory net) private view returns (string memory) {
        string memory path = string.concat(deploymentsDir(), "/", net, "/network.json");
        return vm.exists(path) ? vm.readFile(path) : "{}";
    }

    /// @dev Copies `network`'s files into the rehearsal network `<prefix>-rehearse-<network>` and
    ///      returns its name. The copy is rebuilt every run, because the fork does not keep what the
    ///      previous simulation did. The name falls under `paths.rehearsal`, which version control
    ///      must ignore.
    function _stage(string calldata network) internal override returns (string memory net) {
        net = _stagedAs(network, "-rehearse-");
    }

    /// @dev As `_stage`, in `<paths.rehearsal>-plan-<network>`: a plan must not restage the copy that a
    ///      kept rehearsal still uses. `sprue plan --simulate` names the same directory.
    function _stageSimulation(string memory network) internal override returns (string memory net) {
        net = _stagedAs(network, "-plan-");
    }

    function _stagedAs(string memory network, string memory infix) private returns (string memory net) {
        require(
            bytes(network).length != 0 && !vm.contains(network, "/") && !vm.contains(network, ".."),
            "the network is a directory under paths.deployments"
        );
        net = string.concat(rehearsalPrefix(), infix, network);
        stageInputs(network, net);
    }

    /// @dev Every top-level entry of every journal `<unit>.json` in `net` whose value is an address, as
    ///      `<unit>.<key>` and the address. The other entries are the journal's bookkeeping (hashes,
    ///      nonces), and a balance or a role no journal holds cannot be seen here.
    function _journalState(string memory net) internal view override returns (string[] memory keys, string[] memory values) {
        string memory dir = string.concat(deploymentsDir(), "/", net);
        VmSafe.DirEntry[] memory files = vm.readDir(dir);
        keys = new string[](0);
        values = new string[](0);
        for (uint256 f; f < files.length; ++f) {
            if (files[f].isDir) continue;
            string[] memory path = vm.split(slashed(files[f].path), "/");
            string memory name = path[path.length - 1];
            if (vm.indexOf(name, ".json") + 5 != bytes(name).length || _same(name, "network.json")) continue;
            string memory unit = vm.replace(name, ".json", "");
            // A journal is `<unit>.json`; `<unit>.input.json` and `<Role>.metadata.json` are not.
            if (vm.indexOf(unit, ".") != type(uint256).max) continue;
            string memory json = vm.readFile(files[f].path);
            string[] memory names;
            try vm.parseJsonKeys(json, "$") returns (string[] memory parsed) {
                names = parsed;
            } catch {
                continue;
            }
            for (uint256 k; k < names.length; ++k) {
                string memory value;
                try vm.parseJsonString(json, string.concat(".", names[k])) returns (string memory text) {
                    value = text;
                } catch {
                    continue;
                }
                if (bytes(value).length != 42 || bytes(value)[0] != "0" || bytes(value)[1] != "x") continue;
                keys = _push(keys, string.concat(unit, ".", names[k]));
                values = _push(values, value);
            }
        }
    }

    function _push(string[] memory list, string memory item) private pure returns (string[] memory grown) {
        grown = new string[](list.length + 1);
        for (uint256 i; i < list.length; ++i) {
            grown[i] = list[i];
        }
        grown[list.length] = item;
    }

    function _prepareSender(string memory network, uint256 nodeIndex) internal virtual override returns (bool) {
        Node storage n = _nodes[nodeIndex];
        if (bytes(n.sender).length == 0) return true;
        address sender = _senderAddress(network, n.sender);
        if (sender == msg.sender) return true;
        console.log(_cannotReach(n.id, string.concat("it is sent by ", vm.toString(sender))));
        return false;
    }

    function _unmetPredicate(uint256 nodeIndex) internal virtual override returns (bool) {
        console.log(_cannotReach(_nodes[nodeIndex].id, "its condition is not met"));
        return false;
    }
}

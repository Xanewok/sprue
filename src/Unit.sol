// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {VmSafe} from "forge-std/Vm.sol";

import {chainId, chainRpc, deploymentsDir, graphScript, isFencedChainId, isTestChain, unitsDir} from "./Chains.sol";
import {Roles} from "./Roles.sol";
import {isRehearsalNetwork, slashed} from "./Journal.sol";
import {Declares} from "./graph/Step.sol";

/// @notice The base of a deploy unit. It reads the network's `network.json`, keeps the unit's journal
///         `<unit>.json` beside it, and records the build that the unit's `check` step authenticates.
abstract contract Unit is Roles, Declares {
    function _deployments() internal view override returns (string memory) {
        return deploymentsDir();
    }

    function _graphScript() internal view override returns (string memory) {
        return graphScript();
    }

    /// @dev The script that a refusal's recovery command names: the one `Deploy*.s.sol` in the
    ///      unit's directory. A broadcast record may come from any script that sent the CREATE, so
    ///      the command cannot take the script from the record.
    function _deployScript() internal view virtual override returns (string memory script) {
        string memory dir = string.concat(unitsDir(), "/", _unit(), "/");
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

    function _fenced() internal view override returns (bool) {
        return isFencedChainId(block.chainid);
    }

    /// @dev A rehearsal network's journal is also written by simulated runs, so that later steps of
    ///      a rehearsal see what earlier simulated steps recorded.
    function _rehearsal() internal view override returns (bool) {
        return isRehearsalNetwork(_networkName());
    }

    function _requireTestChain() internal view {
        require(isTestChain(), "a test-only unit: name a test chain's network");
    }

    /// @dev This unit forks each chain it selects once per run, so that a step's effects on a chain
    ///      stay visible to the unit's next step. Both maps are keyed by the hash of the chain name.
    ///      `_forkOf` holds the fork id plus one, so zero means not forked yet. `_headOf` holds the
    ///      block the fork is pinned at.
    mapping(bytes32 => uint256) private _forkOf;
    mapping(bytes32 => uint256) private _headOf;
    string private _selected;

    function _selectedChain() internal view override returns (string memory) {
        return bytes(_selected).length == 0 ? super._selectedChain() : _selected;
    }

    /// @dev The RPC URL of `chain`'s `rpc`. A test that needs another RPC overrides this.
    function _rpc(string memory chain) internal view virtual returns (string memory) {
        return chainRpc(_networkJson(), chain, false);
    }

    /// @dev Selects `chain`'s fork. Reverts if the RPC serves another chain id than `network.json`
    ///      gives for `chain`, or than the journal's `<chain>ChainId` when it has one. Returns the
    ///      journal.
    function _selectChain(string memory chain) internal virtual returns (string memory journal) {
        bytes32 id = keccak256(bytes(chain));
        if (_forkOf[id] == 0) {
            string memory url = _rpc(chain);
            bytes memory head = vm.rpc(url, "eth_blockNumber", "[]");
            _headOf[id] = uint256(bytes32(head)) >> (8 * (32 - head.length));
            _forkOf[id] = _createForkAt(url, _headOf[id]) + 1;
        }
        vm.selectFork(_forkOf[id] - 1);
        _selected = chain;
        require(
            block.chainid == chainId(_networkJson(), chain),
            string.concat("chain ", chain, "'s rpc serves another chain id than network.json's")
        );
        _requireClient();
        journal = _journal();
        string memory key = string.concat(".", chain, "ChainId");
        if (_has(journal, key)) {
            require(
                block.chainid == _uint(journal, key),
                string.concat("chain ", chain, "'s rpc serves another chain id than the journal's")
            );
        }
    }

    /// @dev The chain's own head block, as the node reported it when the fork was made (zero if
    ///      `chain` was not forked). On a rollup whose `block.number` reports its parent chain's
    ///      number, a check needs this to record the right block.
    function _forkHead(string memory chain) internal view returns (uint256) {
        return _headOf[keccak256(bytes(chain))];
    }

    /// @dev A load-balanced RPC can answer `eth_blockNumber` from a node that is ahead of the one
    ///      that serves the fork, which then cannot find that block yet. So it tries up to five
    ///      times, sleeping a second after each failure but the last.
    ///
    ///      The fork stays at the head, not a block behind it. On a chain that makes blocks only for
    ///      transactions, an older block can miss this deployer's last step, and a resumed run
    ///      would repeat it.
    function _createForkAt(string memory url, uint256 blockNumber) private returns (uint256) {
        for (uint256 attempt = 1; attempt < 5; ++attempt) {
            try vm.createFork(url, blockNumber) returns (uint256 id) {
                return id;
            } catch {
                vm.sleep(1000);
            }
        }
        return vm.createFork(url, blockNumber);
    }
}

/// @notice A unit's `recover` step, which rebuilds a lost journal from its `_roles()`: `contract X is Unit,
///         Recovers`. Opt-in, because the recovery code it compiles costs every unit that carries it.
/// @dev A unit whose journal holds more than its roles adds it in `_onRecover`.
abstract contract Recovers is Unit {
    function recover(string calldata network) external returns (string memory) {
        return _recoverRoles(network);
    }
}

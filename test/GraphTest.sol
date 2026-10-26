// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {deploymentsDir, rehearsalPrefix} from "../src/Chains.sol";
import {Deployment} from "../src/Deployment.sol";
import {stageInputs} from "../src/Journal.sol";
import {Graph, IFixtureHost} from "../src/graph/Graph.sol";
import {IProbe} from "../src/graph/Step.sol";

/// @notice Runs a project's real graph in process, under `forge test`, as the graph's commands would
///         run it: each step is sent by its own account and every send is counted from the state diff.
/// @dev Guarantees: a step that sends anything outside the graph's helpers, such as a raw `vm.broadcast`,
///      is in the transcript. The sender's nonce must move by exactly its transcript entries; it counts
///      a send that was reverted at top level too, and a mismatch reverts. Relies on: Foundry naming the
///      broadcaster as the accessor of a send, and no contract at the broadcaster's address
///      (`test/FoundryFacts.t.sol`). A send from an account that no node names and that is not forge's
///      default sender is in the transcript but has no nonce check.
abstract contract GraphTest is Test, IFixtureHost {
    struct Sent {
        uint256 chainId;
        address from;
        uint64 nonce;
        bool create;
        address to;
        uint256 value;
        bytes data;
    }

    Graph private _graph;
    string private _net;
    address[] private _units;
    Sent[] private _sent;
    /// @dev The depth of the graph's own calls, from the `fixtureRun` call in the diff.
    uint256 private _floor;

    /// @dev Copies `source`'s files into the session's rehearsal network, so that tests of one project
    ///      run in parallel, each on its own journals. `session` is unique per test function.
    function _useGraph(Graph g, string memory source, string memory session) internal {
        _graph = g;
        _net = string.concat(rehearsalPrefix(), "-", session);
        stageInputs(source, _net);
        delete _units;
        for (uint256 i; i < g.nodeCount(); ++i) {
            address unit = g.node(i).unit;
            bool seen;
            for (uint256 j; j < _units.length && !seen; ++j) {
                seen = _units[j] == unit;
            }
            if (!seen) _units.push(unit);
        }
    }

    /// @dev Runs `node` and what it needs, in graph order, with the warps and predicate drives the
    ///      graph would make. Returns what it sent.
    function upTo(string memory node) internal returns (Sent[] memory) {
        return _run(node, false);
    }

    /// @dev `upTo` for each need of `node`.
    function needsOf(string memory node) internal returns (Sent[] memory sent) {
        string[] memory deps = _graph.node(_indexOf(node)).deps;
        for (uint256 i; i < deps.length; ++i) {
            sent = _join(sent, upTo(deps[i]));
        }
    }

    /// @dev `node`'s step alone, whether or not it is done: its needs count as done.
    function runNode(string memory node) internal returns (Sent[] memory) {
        return _run(node, true);
    }

    /// @dev The address `unit`'s journal holds at `key`, such as `.owner`.
    function role(string memory unit, string memory key) internal view returns (address) {
        string memory path = string.concat(deploymentsDir(), "/", _net, "/", unit, ".json");
        return vm.parseJsonAddress(vm.readFile(path), key);
    }

    /// @dev Reverts unless a rerun of every step `target` needs sends nothing. Run it after `upTo(target)`.
    function quiet(string memory target) internal {
        bool[] memory needed = _closure(target);
        for (uint256 i; i < needed.length; ++i) {
            Graph.Node memory n = _graph.node(i);
            if (!needed[i] || bytes(n.step).length == 0) continue;
            require(runNode(n.id).length == 0, string.concat(n.id, " sends on a rerun"));
        }
    }

    /// @dev Makes the predicate node `node` true, as the person or system outside the graph would.
    function _meet(string memory) internal virtual returns (bool) {
        return false;
    }

    function meet(string calldata id) external returns (bool) {
        require(msg.sender == address(_graph), "only the graph asks");
        return _meet(id);
    }

    function stepped(string calldata) external {
        require(msg.sender == address(_graph), "only the graph reports");
        _absorb();
        vm.startStateDiffRecording();
    }

    function _run(string memory id, bool alone) private returns (Sent[] memory sent) {
        address[] memory who = _senders();
        uint256[] memory before = new uint256[](who.length);
        for (uint256 i; i < who.length; ++i) {
            before[i] = vm.getNonce(who[i]);
        }
        delete _sent;
        vm.startStateDiffRecording();
        bool reached = _graph.fixtureRun(_net, id, alone);
        _absorb();
        require(reached, string.concat("the fixture cannot reach ", id));
        sent = _sent;
        for (uint256 i; i < who.length; ++i) {
            uint256 count;
            for (uint256 j; j < sent.length; ++j) {
                if (sent[j].from == who[i]) ++count;
            }
            require(
                vm.getNonce(who[i]) == before[i] + count,
                string.concat(vm.toString(who[i]), " sent a different number of transactions than the transcript holds")
            );
        }
        for (uint256 i; i < sent.length; ++i) {
            uint256 earlier;
            uint256 total;
            for (uint256 j; j < sent.length; ++j) {
                if (sent[j].from != sent[i].from) continue;
                if (j < i) ++earlier;
                ++total;
            }
            sent[i].nonce = uint64(vm.getNonce(sent[i].from) - total + earlier);
        }
    }

    /// @dev Appends the sends in the state diff recorded so far and vouches for each CREATE to every unit,
    ///      so that a unit reads a role another unit created. The graph's own calls (depth `_floor` and
    ///      above) are not sends; of those, a probe and a callback to this test are skipped with their
    ///      subtrees, by who calls and who is called, never by calldata: a probe's self-call reverts.
    function _absorb() private {
        VmSafe.AccountAccess[] memory log = vm.stopAndReturnStateDiff();
        uint256 inside = type(uint256).max;
        for (uint256 i; i < log.length; ++i) {
            VmSafe.AccountAccess memory a = log[i];
            if (a.depth > inside) continue;
            inside = type(uint256).max;
            bool call = a.kind == VmSafe.AccountAccessKind.Call;
            if (call && a.accessor == address(this) && a.account == address(_graph)) {
                _floor = a.depth + 1;
                continue;
            }
            if (a.depth <= _floor) {
                if (call && (a.account == address(this) || (_isUnit(a.account) && _isProbe(a.data)))) {
                    inside = a.depth;
                }
                continue;
            }
            if (!call && a.kind != VmSafe.AccountAccessKind.Create) continue;
            if (a.accessor.code.length != 0) continue;
            _sent.push(Sent(a.chainInfo.chainId, a.accessor, 0, !call, a.account, a.value, a.data));
            if (call || a.reverted) continue;
            for (uint256 u; u < _units.length; ++u) {
                Deployment(_units[u]).trustTestCreationAt(a.account, a.data);
            }
        }
    }

    function _isUnit(address account) private view returns (bool) {
        for (uint256 i; i < _units.length; ++i) {
            if (_units[i] == account) return true;
        }
        return false;
    }

    function _isProbe(bytes memory data) private pure returns (bool) {
        return data.length >= 4 && bytes4(data) == IProbe.probe.selector;
    }

    function _senders() private view returns (address[] memory who) {
        who = new address[](_graph.nodeCount() + 1);
        uint256 count;
        who[count++] = DEFAULT_SENDER;
        for (uint256 i; i < _graph.nodeCount(); ++i) {
            Graph.Node memory n = _graph.node(i);
            if (bytes(n.step).length == 0) continue;
            address sender = _graph.fixtureSender(_net, n.id);
            bool seen;
            for (uint256 j; j < count && !seen; ++j) {
                seen = who[j] == sender;
            }
            if (!seen) who[count++] = sender;
        }
        // SAFETY: `count <= who.length`, so the shortened array lies within its allocation.
        assembly ("memory-safe") {
            mstore(who, count)
        }
    }

    function _closure(string memory target) private view returns (bool[] memory needed) {
        needed = new bool[](_graph.nodeCount());
        needed[_indexOf(target)] = true;
        for (uint256 i = needed.length; i > 0; --i) {
            if (!needed[i - 1]) continue;
            string[] memory deps = _graph.node(i - 1).deps;
            for (uint256 d; d < deps.length; ++d) {
                needed[_indexOf(deps[d])] = true;
            }
        }
    }

    function _indexOf(string memory id) private view returns (uint256) {
        for (uint256 i; i < _graph.nodeCount(); ++i) {
            if (keccak256(bytes(_graph.node(i).id)) == keccak256(bytes(id))) return i;
        }
        revert(string.concat("unknown node ", id));
    }

    function _join(Sent[] memory a, Sent[] memory b) private pure returns (Sent[] memory out) {
        out = new Sent[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            out[i] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            out[a.length + i] = b[i];
        }
    }
}

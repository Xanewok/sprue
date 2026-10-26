// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {VmSafe} from "forge-std/Vm.sol";

import {deploymentsDir, rehearsalPrefix} from "../src/Chains.sol";
import {Deployment} from "../src/Deployment.sol";
import {stageInputs} from "../src/Journal.sol";
import {Graph, IFixtureHost} from "../src/graph/Graph.sol";
import {IProbe} from "../src/graph/Step.sol";
import {ForgeTranscript} from "./ForgeTranscript.sol";

/// @notice Runs a project's real graph in process, under `forge test`, as the graph's commands would
///         run it: each step is sent by its own account and every send is counted from the state diff.
/// @dev Guarantees: every send a step's call makes, including a raw `vm.broadcast`, is in the transcript, and a
///      send made anywhere else in the run, such as by a `Due` view, fails the nonce check of a watched sender.
///      The watched senders are the nodes' senders and forge's default sender; a send from any other account is
///      in the transcript but has no nonce check. A body is entered from the graph, not from `--sender`; `quiet`
///      catches a body that branches on its caller by requiring the planner's `Done`.
abstract contract GraphTest is ForgeTranscript, IFixtureHost {
    Graph private _graph;
    string private _net;
    address[] private _units;
    bool private _running;

    /// @dev A run or a judgment keeps one transcript, one recording and the graph's `_fixture`: nothing it calls
    ///      back into, such as a `_meet`, may start another.
    modifier exclusive() {
        require(!_running, "a fixture run is already running");
        _running = true;
        _;
        _running = false;
    }

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

    /// @dev Reverts unless the planner calls every step `target` needs done, a rerun of its body sends nothing,
    ///      and a probe of its body as its sender finds nothing due. Run it after `upTo(target)`. The rerun enters the
    ///      body from the graph, the probe as the step's sender, so a body that branches on `msg.sender` fails the
    ///      probe. The probe sees only what the body does before its first send, and a body that catches the
    ///      probe's `StepDue` revert is outside what it judges (DESIGN.md, "The steps the fixture judges").
    function quiet(string memory target) internal {
        bool[] memory needed = _closure(target);
        for (uint256 i; i < needed.length; ++i) {
            Graph.Node memory n = _graph.node(i);
            if (!needed[i] || bytes(n.step).length == 0) continue;
            require(_judge(n.id) == Graph.Status.Done, string.concat(n.id, " is not done by the planner"));
            require(runNode(n.id).length == 0, string.concat(n.id, " sends on a rerun"));
            require(
                !_dueAs(n.unit, _graph.stepCalldata(_net, n.id), _graph.fixtureSender(_net, n.id)),
                string.concat(n.id, " would send as its sender")
            );
        }
    }

    /// @dev Makes the predicate node `node` true, as the person or system outside the graph would.
    function _meet(string memory) internal virtual returns (bool) {
        return false;
    }

    /// @dev The test's own act, outside the recording: it is the world's, not the graph's.
    function meet(string calldata id) external returns (bool met) {
        require(msg.sender == address(_graph), "only the graph asks");
        _noSendOutside();
        met = _meet(id);
        _recordStart();
    }

    /// @dev Sets the step's sender on its unit, then records the step's call.
    function stepping(string calldata id) external {
        require(msg.sender == address(_graph), "only the graph reports");
        _noSendOutside();
        Deployment(_graph.node(_indexOf(id)).unit).setTestSender(_graph.fixtureSender(_net, id));
        _recordStart();
    }

    /// @dev Vouches for each CREATE to every unit, so that a unit reads a role another unit created.
    function stepped(string calldata) external {
        require(msg.sender == address(_graph), "only the graph reports");
        (Sent[] memory sent, Created[] memory created) = _recordDrain();
        _transcriptAdd(sent);
        for (uint256 i; i < created.length; ++i) {
            for (uint256 u; u < _units.length; ++u) {
                Deployment(_units[u]).trustTestCreationAt(created[i].at, created[i].initcode);
            }
        }
        _recordStart();
    }

    /// @dev The recording runs through the whole call: what it holds between steps was sent by a judgment of
    ///      the planner or by the graph itself, and the graph sends nothing.
    function _run(string memory id, bool alone) private exclusive returns (Sent[] memory) {
        _transcriptBegin(_senders());
        _recordStart();
        require(_graph.fixtureRun(_net, id, alone), string.concat("the fixture cannot reach ", id));
        _noSendOutside();
        return _transcriptEnd();
    }

    /// @dev The planner's verdict, with the senders' nonces and the recording watching the judgment.
    function _judge(string memory id) private exclusive returns (Graph.Status verdict) {
        _transcriptBegin(_senders());
        _recordStart();
        verdict = _graph.status(_net, id);
        _noSendOutside();
        _transcriptEnd();
    }

    function _noSendOutside() private {
        (Sent[] memory sent,) = _recordDrain();
        require(
            sent.length == 0,
            string.concat(vm.toString(sent.length == 0 ? address(0) : sent[0].from), " sent outside a step's call")
        );
    }

    /// @dev Whether `unit`'s probe of `step`, pranked as `sender`, finds the step due. Not `Probes.due`: a
    ///      library call deploys the library from inside the recording.
    function _dueAs(address unit, bytes memory step, address sender) private returns (bool) {
        (, bytes memory ret) = unit.call(abi.encodeCall(IProbe.probe, (step, sender)));
        require(bytes4(ret) == IProbe.Probed.selector, "the unit does not answer a probe");
        bytes memory data = new bytes(ret.length - 4);
        for (uint256 i; i < data.length; ++i) {
            data[i] = ret[i + 4];
        }
        (bool returned, bytes memory result) = abi.decode(data, (bool, bytes));
        if (returned) return false;
        require(bytes4(result) == IProbe.StepDue.selector, "the step refuses as its sender");
        return true;
    }

    function _isProbe(VmSafe.AccountAccess memory frame) internal view override returns (bool) {
        if (frame.accessor != address(_graph) || frame.kind != VmSafe.AccountAccessKind.Call) return false;
        if (frame.data.length < 4 || bytes4(frame.data) != IProbe.probe.selector) return false;
        for (uint256 i; i < _units.length; ++i) {
            if (_units[i] == frame.account) return true;
        }
        return false;
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

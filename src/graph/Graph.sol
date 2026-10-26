// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {IProbe, Registration, IUnitSteps, Step, StepKind} from "./Step.sol";

/// @notice A fixed graph of deploy steps (nodes). `plan` prints the commands that reach a target;
///         `rehearse` simulates them.
/// @dev Nodes are stored in the order `_order` derives: dependencies first, then unit registration
///      order. The virtual hooks below supply journals, inputs, rehearsal staging, chain policy and
///      step execution; `FileGraph` implements them from files.
abstract contract Graph is Script {
    enum Status {
        NotJudged,
        Done,
        Due,
        Waiting
    }

    struct Node {
        string id;
        address unit;
        string script;
        /// @dev `step` or `until` holds `Step.fn`, by `Step.kind`.
        string step;
        string[] deps;
        /// @dev Reference `<input file>.<key>` to the account that must send the step. Empty: any
        ///      sender.
        string sender;
        /// @dev Why the sender may be an account no run signs as; see `StepLib.prepared`. Empty: not prepared.
        string prepared;
        /// @dev The earliest time the step may run. With a dot, an input reference
        ///      `<input file>.<key>` holding a unix timestamp. Without a dot, the name of a view on
        ///      the unit that returns the timestamp, called with the step's arguments. Empty: no
        ///      gate.
        string gate;
        /// @dev The chain the step sends on, as named in its command and in the `# not before`
        ///      line. Empty: the default chain.
        string on;
        string[] reads;
        bool slow;
        bool testOnly;
        string arg;
        /// @dev The unit has a function `<step>Due`. It returns true while the step still has work and
        ///      false once the step is done. It reverts while the step would refuse to run.
        bool due;
        /// @dev The step creates its own forks, so `plan` prints its command without `--rpc-url`.
        bool ownForks;
        /// @dev Done once the unit's journal holds `checked`. `plan` reads that file and does not
        ///      call the step.
        bool certified;
        /// @dev The `check` nodes whose certificate makes this node done. Empty unless `certified`.
        string[] certifiedBy;
        /// @dev A step of a unit that answers `IProbe.probe`, with no `Due` view, not certified: once its
        ///      needs are done, the plan judges it by running it there.
        bool probed;
        /// @dev Makes this a predicate node, which sends nothing. It names a view on the unit that
        ///      returns true once the chain meets a condition, called with the step's arguments.
        ///      Something outside the graph, such as a person's transaction, makes it true.
        string until;
    }

    struct Visit {
        uint256 node;
        Status status;
        uint256 notBefore;
        string reason;
    }

    error EmptyStep(uint256 slot);
    error DuplicateId(string id);
    error MissingDependency(string id, string dependency);
    error Cycle(string path);
    error UnlistedUnit(string id);
    error ProductionDependency(string id, string dependency);
    error SelectorMismatch(string id, bytes4 expected, bytes4 actual);
    error MissingDoneRule(string id);
    error UnsafeName(string name);

    uint256 private constant NONE = type(uint256).max;

    Node[] internal _nodes;
    /// @dev The fork selected when `plan` or `rehearse` began: the chain input dates are read on.
    uint256 private _home;
    /// @dev Units in registration order. `_order` sorts nodes by their unit's index here, after
    ///      dependencies.
    address[] internal _units;

    /// @notice Simulates `target` and what it depends on, in list order.
    function rehearse(string calldata network, string calldata target) external {
        // The steps would send from inside this one script, instead of from the separate command per
        // step that `plan` prints.
        require(!_broadcasting(), "rehearse only simulates: send each command plan prints");
        // Forge's default sender is not a real account. Without `--sender`, every step that accepts
        // any sender would be simulated from it, and the result would not predict the real run.
        require(msg.sender != DEFAULT_SENDER, "pass --sender <deployer> to the dry run, or --account");
        string memory net = _stage(network);
        if (_executeTarget(net, target)) console.log(string.concat("reached ", target));
    }

    /// @notice The commands that reach `target` and what it depends on, in order. Each line is
    ///         printed behind `PLAN ` and the lines are returned together.
    ///
    ///         Each command is a dry run. The same command with `--account <keystore> --broadcast`
    ///         sends it. Its `--rpc-url` is the chain's `rpc` alias, and `$DEPLOYER` the account that
    ///         sends a step with no `.by`.
    ///
    ///         Every other line is a comment, `# <keyword> ...`. The executor rejects any keyword not
    ///         listed here:
    ///         - `# chain <chain> <chain id> <kind>`: a chain of `network.json`. These lines come
    ///           before everything else.
    ///         - `# warning <text>`: for the person running the plan; it changes nothing, and a reader of
    ///           the plan ignores it. These lines follow the `# chain` lines.
    ///         - `# done <id>`: the chain or the journal shows the node done. No command follows.
    ///         - `# not before <unix time> [on <rpc>] <id>[, movable until reached]`: the node's date
    ///           has not been reached on that chain (without `on`, the default chain). The command
    ///           after it is valid only once the date is reached.
    ///         - `# cannot reach <id>: <reason>`: the node's step would refuse now, and its command
    ///           follows; or, for a predicate node, its condition is not met, and no command follows.
    ///           A view or predicate whose file read or JSON parse fails reverts the plan instead.
    ///         - `# then plan again <id>`: what follows depends on commands above that have not
    ///           landed. The plan ends here.
    function plan(string calldata network, string calldata target) external returns (string memory) {
        return _plan(network, target, false);
    }

    /// @notice `plan`; `allUnits` also prints the `# warning` lines of units whose nodes are all done.
    function plan(string calldata network, string calldata target, bool allUnits) external returns (string memory) {
        return _plan(network, target, allUnits);
    }

    function _plan(string memory network, string memory target, bool allUnits) private returns (string memory out) {
        string[] memory header = _chainLines(network);
        _home = _fork(type(uint256).max);
        (Visit[] memory visits, uint256 count) = _walk(network, target, new bool[](_nodes.length), false);
        for (uint256 i; i < header.length; ++i) {
            out = _line(out, header[i]);
        }
        out = _warnings(out, network, visits, count, allUnits);
        for (uint256 i; i < count; ++i) {
            Visit memory visit = visits[i];
            Node storage n = _nodes[visit.node];
            if (visit.notBefore != 0) {
                out = _line(
                    out,
                    string.concat(
                        "# not before ",
                        vm.toString(visit.notBefore),
                        _clockOn(network, n),
                        " ",
                        n.id,
                        // A date from an input file is fixed. A view's date may still move until the chain
                        // reaches it.
                        vm.contains(n.gate, ".") ? "" : ", movable until reached"
                    )
                );
            }
            if (visit.status == Status.NotJudged) {
                out = _line(out, string.concat("# then plan again ", n.id));
                break;
            }
            if (visit.status == Status.Done) {
                if (bytes(n.step).length == 0 && bytes(n.until).length == 0) continue;
                out = _line(out, string.concat("# done ", n.id));
                continue;
            }
            if (visit.status == Status.Waiting) {
                out = _line(out, string.concat("# ", _cannotReach(n.id, visit.reason)));
                if (bytes(n.until).length != 0) continue;
            }
            if (bytes(n.step).length == 0) continue;
            if (bytes(n.prepared).length != 0) out = _line(out, string.concat("# prepared ", n.id, ": ", n.prepared));
            out = _line(out, _command(network, n));
        }
    }

    /// @notice The nodes no other node depends on, in graph order.
    function list() external view returns (string memory out) {
        bool[] memory dependedOn = new bool[](_nodes.length);
        for (uint256 i; i < _nodes.length; ++i) {
            for (uint256 d; d < _nodes[i].deps.length; ++d) {
                dependedOn[_index(_nodes[i].deps[d])] = true;
            }
        }
        for (uint256 i; i < _nodes.length; ++i) {
            if (dependedOn[i]) continue;
            console.log(string.concat("TARGET ", _nodes[i].id));
            out = string.concat(out, _nodes[i].id, "\n");
        }
    }

    /// @notice Canonical, chain-independent JSON for the declared node table, one node per line.
    /// @dev Each line is also logged behind `GRAPH `, which is how `sprue json` reads it.
    function graph() external view returns (string memory out) {
        console.log('GRAPH {"nodes":[');
        out = '{"nodes":[\n';
        for (uint256 i; i < _nodes.length; ++i) {
            string memory line = string.concat(_nodeJson(_nodes[i]), i + 1 < _nodes.length ? "," : "");
            console.log(string.concat("GRAPH ", line));
            out = string.concat(out, line, "\n");
        }
        console.log("GRAPH ]}");
        out = string.concat(out, "]}\n");
    }

    function nodeCount() external view returns (uint256) {
        return _nodes.length;
    }

    function node(uint256 i) external view returns (Node memory) {
        return _nodes[i];
    }

    /// @dev Judges the nodes `target` needs, in list order, and stops after the first node that
    ///      cannot be judged yet. `passed` marks steps a rehearsal has already simulated. `alone`
    ///      judges `target` only, with its needs counted done and its step due even when done.
    function _walk(string memory network, string memory target, bool[] memory passed, bool alone)
        internal
        returns (Visit[] memory visits, uint256 count)
    {
        bool[] memory needed = _closure(target);
        if (alone) {
            needed = new bool[](_nodes.length);
            needed[_index(target)] = true;
        }
        Status[] memory statuses = new Status[](_nodes.length);
        visits = new Visit[](_nodes.length);
        for (uint256 i; i < _nodes.length; ++i) {
            if (!needed[i]) continue;
            Node storage n = _nodes[i];
            Visit memory visit;
            visit.node = i;
            // Alone, a certified step is still sent, so its date is judged too.
            if (passed[i] || (!alone && n.certified && _journalChecked(network, vm.split(n.id, ".")[0]))) {
                visit.status = Status.Done;
            } else if (!alone && !_dependenciesDone(i, statuses) && (n.due || n.probed || bytes(n.until).length != 0)) {
                visit.status = Status.NotJudged;
                _requireCertificateAhead(target, i, statuses, visits, count);
            } else {
                if (bytes(n.gate).length != 0) {
                    require(
                        !vm.contains(n.gate, ".") || _onDefaultChain(network, n),
                        string.concat(
                            n.id,
                            " has an input date but sends on ",
                            n.on,
                            ": use a gate view, which selects that chain"
                        )
                    );
                    // An earlier view may have left another chain selected; an input date is the default
                    // chain's. Restore the selection after, so later views read what they read before.
                    uint256 back = vm.contains(n.gate, ".") ? _fork(_home) : NONE;
                    visit.notBefore = _time(network, n);
                    if (block.timestamp >= visit.notBefore) visit.notBefore = 0;
                    _fork(back);
                }
                // The date is fixed and not yet reached, so the step's `Due` view would be read on a
                // chain still before it. Leave the step unjudged for the plan made after the date.
                if (visit.notBefore != 0 && vm.contains(n.gate, ".")) visit.status = Status.NotJudged;
                else (visit.status, visit.reason) = _status(network, n, passed[i]);
            }
            if (alone && visit.status == Status.Done && bytes(n.step).length != 0) {
                visit.status = Status.Due;
            }
            if (visit.status != Status.Done && n.certified && !alone && !_anyNeeded(n.certifiedBy, needed)) {
                revert(
                    _cannotReach(target, string.concat(n.id, " is done only by ", n.certifiedBy[0], ": target that"))
                );
            }
            statuses[i] = visit.status;
            visits[count++] = visit;
            if (visit.status == Status.NotJudged) break;
        }
    }

    /// @dev `nodeIndex` stops the plan until its needs are done. A need that only its unit's certificate
    ///      marks done stays undone unless this plan sends a `check` of that unit before `nodeIndex`, and
    ///      every later plan would stop at `nodeIndex` again.
    function _requireCertificateAhead(
        string memory target,
        uint256 nodeIndex,
        Status[] memory statuses,
        Visit[] memory visits,
        uint256 count
    ) private view {
        bool[] memory needed = _closure(nodeIndex);
        for (uint256 c; c < nodeIndex; ++c) {
            Node storage certified = _nodes[c];
            if (!needed[c] || statuses[c] == Status.Done || !certified.certified) continue;
            bytes32 journal = keccak256(bytes(vm.split(certified.id, ".")[0]));
            bool ahead;
            for (uint256 v; v < count && !ahead; ++v) {
                Node storage check = _nodes[visits[v].node];
                ahead = !check.due && keccak256(bytes(check.step)) == keccak256("check")
                    && keccak256(bytes(vm.split(check.id, ".")[0])) == journal;
            }
            require(
                ahead,
                _cannotReach(
                    target,
                    string.concat(
                        _nodes[nodeIndex].id,
                        " waits for ",
                        certified.id,
                        ", which only a check of its unit marks done, and none is sent before it: give ",
                        certified.id,
                        " a Due view, or plan such a check first"
                    )
                )
            );
        }
    }

    function _anyNeeded(string[] storage ids, bool[] memory needed) private view returns (bool) {
        for (uint256 i; i < ids.length; ++i) {
            if (needed[_index(ids[i])]) return true;
        }
        return false;
    }

    function _executeTarget(string memory network, string memory target) internal returns (bool reached) {
        return _interpret(network, target, false);
    }

    /// @dev Runs `id` as `_executeTarget` would, without its needs, and sends its step even when done,
    ///      so the unit's own checks decide: for tests that run a node out of order on purpose.
    function _executeNode(string memory network, string memory id) internal returns (bool done) {
        return _interpret(network, id, true);
    }

    function _interpret(string memory network, string memory target, bool alone) private returns (bool reached) {
        // A simulated step is not sent, so `_status` may not see its effect. `passed` records the steps
        // already run, so that each runs once.
        bool[] memory passed = new bool[](_nodes.length);
        bool[] memory driven = new bool[](_nodes.length);
        _home = _fork(type(uint256).max);
        while (true) {
            (Visit[] memory visits, uint256 count) = _walk(network, target, passed, alone);
            bool advanced;
            bool replan;
            for (uint256 i; i < count; ++i) {
                Visit memory visit = visits[i];
                Node storage n = _nodes[visit.node];
                if (visit.status == Status.Done) {
                    driven[visit.node] = false;
                    continue;
                }
                if (visit.status == Status.NotJudged) {
                    if (visit.notBefore != 0) {
                        _warpToDate(network, n);
                        advanced = true;
                    }
                    replan = true;
                    break;
                }
                if (visit.status == Status.Waiting && bytes(n.until).length != 0) {
                    // The predicate was judged before its date. Warp to the date and judge again. With no
                    // date left, the driver has one try until the predicate is met: a driver that claims
                    // progress it cannot make would otherwise loop forever.
                    if (!_warpToDate(network, n)) {
                        if (driven[visit.node] || !_unmetPredicate(visit.node)) return false;
                        driven[visit.node] = true;
                    }
                    advanced = true;
                    replan = true;
                    break;
                }
                _warpToDate(network, n);
                if (!_sendStep(network, visit.node)) return false;
                passed[visit.node] = true;
                advanced = true;
            }
            if (!replan) return true;
            require(advanced, _cannotReach(target, "the interpreter stalled"));
        }
    }

    /// @dev Reads the date afresh instead of reusing the walk's value. A gate view may select a
    ///      fork, and judging later nodes in the walk may have selected another since. Returns
    ///      whether the clock moved.
    function _warpToDate(string memory network, Node storage n) private returns (bool warped) {
        if (bytes(n.gate).length == 0) return false;
        if (vm.contains(n.gate, ".")) _fork(_home);
        uint256 date = _time(network, n);
        if (block.timestamp >= date) return false;
        vm.warp(date);
        return true;
    }

    function _status(string memory network, Node storage n, bool passed)
        internal
        returns (Status status, string memory reason)
    {
        if (passed || (n.certified && _journalChecked(network, vm.split(n.id, ".")[0]))) {
            return (Status.Done, "");
        }
        if (bytes(n.until).length != 0) {
            (bool ok, bytes memory ret) = n.unit.call(_calldata(n, n.until, network));
            if (!ok) return (Status.Waiting, _reason(n.id, ret));
            return (abi.decode(ret, (bool)) ? Status.Done : Status.Waiting, "its condition is not met");
        }
        if (n.due) {
            (bool ok, bytes memory ret) = n.unit.call(_calldata(n, string.concat(n.step, "Due"), network));
            if (!ok) return (Status.Waiting, _reason(n.id, ret));
            return (abi.decode(ret, (bool)) ? Status.Due : Status.Done, "");
        }
        if (n.probed) return _probe(network, n);
        return (Status.Due, "");
    }

    function _probe(string memory network, Node storage n) private returns (Status, string memory) {
        address sender = bytes(n.sender).length == 0 ? msg.sender : _senderAddress(network, n.sender);
        (, bytes memory ret) = n.unit.call(abi.encodeCall(IProbe.probe, (_calldata(n, n.step, network), sender)));
        require(bytes4(ret) == IProbe.Probed.selector, string.concat(n.id, ": its unit's probe did not answer"));
        (bool returned, bytes memory result) = abi.decode(_strip(ret), (bool, bytes));
        if (returned) return (Status.Done, "");
        if (bytes4(result) == IProbe.StepDue.selector) return (Status.Due, "");
        if (!_isBroadcastUnderPrank(result)) return (Status.Waiting, _reason(n.id, result));
        return (
            Status.Waiting,
            "it calls vm.startBroadcast or vm.broadcast, which a probe cannot judge: call _startBroadcast(), give it a Due view, or mark it doneByCheck"
        );
    }

    function _isBroadcastUnderPrank(bytes memory result) private pure returns (bool) {
        if (result.length < 68 || bytes4(result) != bytes4(keccak256("CheatcodeError(string)"))) return false;
        return vm.indexOf(abi.decode(_strip(result), (string)), "you have an active prank") != type(uint256).max;
    }

    /// @dev `data` without its selector, as a copy.
    function _strip(bytes memory data) private pure returns (bytes memory rest) {
        rest = new bytes(data.length - 4);
        for (uint256 i; i < rest.length; ++i) {
            rest[i] = data[i + 4];
        }
    }

    function _add(address target, string memory script) internal {
        _units.push(target);
        _add(Registration(target, script), IUnitSteps(target).steps());
    }

    function _add(Registration memory unit, Step[] memory steps) internal {
        // Keeps the unit's contract alive when a step later selects another fork.
        vm.makePersistent(unit.target);
        bool probes = _answersProbe(unit.target);
        _requirePlain(unit.script, "-:./");
        _requireScript(unit.script);
        for (uint256 i; i < steps.length; ++i) {
            Step memory s = steps[i];
            require(s.kind != StepKind.Empty && bytes(s.id).length != 0, EmptyStep(i));
            _requirePlain(s.fn, "");
            _requireNoDevice(vm.split(s.id, ".")[0]);
            require(_find(s.id) == _nodes.length, DuplicateId(s.id));
            string memory signature = s.hasArg ? "(string,uint8)" : "(string)";
            bytes4 selector = bytes4(keccak256(bytes(string.concat(s.fn, signature))));
            require(s.selector == selector, SelectorMismatch(s.id, selector, s.selector));
            if (s.dueSelector != 0) {
                bytes4 expected = s.kind == StepKind.Call
                    ? bytes4(keccak256(bytes(string.concat(s.fn, "Due", signature))))
                    : bytes4(0);
                require(s.dueSelector == expected, SelectorMismatch(s.id, expected, s.dueSelector));
            }
            if (s.gateSelector != 0) {
                bytes4 expected = bytes4(keccak256(bytes(string.concat(s.gate, signature))));
                require(s.gateSelector == expected, SelectorMismatch(s.id, expected, s.gateSelector));
            }

            Node storage n = _nodes.push();
            n.id = s.id;
            n.unit = unit.target;
            n.script = unit.script;
            if (s.kind == StepKind.Call) n.step = s.fn;
            if (s.kind == StepKind.Until) n.until = s.fn;
            n.deps = s.deps;
            n.sender = s.sender;
            require(
                bytes(s.preparedBy).length == 0 || bytes(s.sender).length != 0,
                string.concat(s.id, " is prepared but has no .by sender")
            );
            n.prepared = s.preparedBy;
            n.gate = s.gate;
            n.on = s.onChain;
            n.reads = s.readChains;
            n.slow = s.isSlow;
            n.testOnly = s.testOnly;
            if (s.hasArg) n.arg = vm.toString(s.arg);
            n.due = s.dueSelector != 0;
            n.probed = probes && s.kind == StepKind.Call && !n.due && !s.byCheck;
            n.ownForks = s.ownForks;
        }
    }

    function _answersProbe(address unit) private view returns (bool) {
        (bool ok, bytes memory ret) = unit.staticcall(abi.encodeCall(IProbe.probes, ()));
        return ok && ret.length == 32 && bytes4(ret) == IProbe.probe.selector;
    }

    /// @dev The script is `<path>` or `<path>:<Contract>`: a non-empty path that does not start with
    ///      `:`, and a contract of letters, digits and `_`, as the runner accepts.
    function _requireScript(string memory script) private pure {
        bytes memory b = bytes(script);
        uint256 colon = b.length;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] != ":") continue;
            require(colon == b.length, UnsafeName(script));
            colon = i;
        }
        require(colon != 0, UnsafeName(script));
        if (colon == b.length) return;
        require(colon + 1 < b.length, UnsafeName(script));
        for (uint256 i = colon + 1; i < b.length; ++i) {
            bytes1 c = b[i];
            require(
                (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_",
                UnsafeName(script)
            );
        }
    }

    /// @dev Reverts unless `name` is letters, digits, `_` and `extra`, and does not start with `-`. These
    ///      go into the command lines that the runner runs, and only such a name is in its
    ///      grammar.
    function _requirePlain(string memory name, string memory extra) private pure {
        bytes memory b = bytes(name);
        bytes memory allowed = bytes(extra);
        require(b.length != 0 && b[0] != "-", UnsafeName(name));
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_";
            for (uint256 j; !ok && j < allowed.length; ++j) {
                ok = c == allowed[j];
            }
            require(ok, UnsafeName(name));
        }
    }

    /// @dev A unit names a directory and files, and Windows reserves these names in any case and with any
    ///      extension.
    function _requireNoDevice(string memory unit) private pure {
        bytes memory name = bytes(vm.toLowercase(unit));
        // com1-com9 and lpt1-lpt9 compare as their first.
        if (name.length == 4 && name[3] >= "1" && name[3] <= "9") name[3] = "1";
        string[6] memory devices = ["con", "prn", "aux", "nul", "com1", "lpt1"];
        for (uint256 i; i < devices.length; ++i) {
            require(keccak256(name) != keccak256(bytes(devices[i])), UnsafeName(unit));
        }
    }

    /// @dev Call after the last `_add`. Reverts unless every dependency exists, no production node
    ///      depends on a test-only node, every node's unit is registered and the graph has no cycle,
    ///      and every step has a done rule: a `Due` view, a probe, or a `check` step of its unit that
    ///      reaches it through `needs`. A `check` certifies itself, and of its ancestors only those
    ///      that no probe judges. Sorts the nodes (`_order`).
    function _validateGraph() internal {
        for (uint256 i; i < _nodes.length; ++i) {
            Node storage n = _nodes[i];
            for (uint256 d; d < n.deps.length; ++d) {
                uint256 dependency = _find(n.deps[d]);
                require(dependency != _nodes.length, MissingDependency(n.id, n.deps[d]));
                require(n.testOnly || !_nodes[dependency].testOnly, ProductionDependency(n.id, n.deps[d]));
            }
        }
        _order();

        for (uint256 i; i < _nodes.length; ++i) {
            Node storage check = _nodes[i];
            if (check.due || keccak256(bytes(check.step)) != keccak256("check")) continue;
            bool[] memory ancestors = _closure(i);
            bytes32 journal = keccak256(bytes(vm.split(check.id, ".")[0]));
            for (uint256 j; j <= i; ++j) {
                Node storage n = _nodes[j];
                if (
                    ancestors[j] && n.unit == check.unit && !n.due && (j == i || !n.probed) && bytes(n.step).length != 0
                        && keccak256(bytes(vm.split(n.id, ".")[0])) == journal
                ) {
                    // An earlier `check` among the ancestors is refused: it would write `checked` first,
                    // and that would mark this `check` done without running it.
                    require(j == i || keccak256(bytes(n.step)) != keccak256("check"), MissingDoneRule(check.id));
                    n.certified = true;
                    n.probed = false;
                    n.certifiedBy.push(check.id);
                }
            }
        }
        for (uint256 i; i < _nodes.length; ++i) {
            Node storage n = _nodes[i];
            require(bytes(n.step).length == 0 || n.due || n.certified || n.probed, MissingDoneRule(n.id));
        }
    }

    /// @dev As `_closure(uint256)`, for a node id. Reverts on an unknown id, and on a test-only node
    ///      off a test chain.
    function _closure(string memory target) internal view returns (bool[] memory needed) {
        uint256 targetIndex = _index(target);
        require(!_nodes[targetIndex].testOnly || _isTestChain(), _cannotReach(target, "unknown target"));
        return _closure(targetIndex);
    }

    /// @dev Topological sort (Kahn's algorithm). Of the nodes whose dependencies are all placed, it
    ///      picks the one whose unit was registered first, then the one declared first.
    function _order() private {
        uint256 count = _nodes.length;
        uint256[] memory rank = new uint256[](count);
        uint256[][] memory deps = new uint256[][](count);
        for (uint256 i; i < count; ++i) {
            Node storage n = _nodes[i];
            while (rank[i] < _units.length && _units[rank[i]] != n.unit) ++rank[i];
            require(rank[i] < _units.length, UnlistedUnit(n.id));
            deps[i] = new uint256[](n.deps.length);
            for (uint256 d; d < n.deps.length; ++d) {
                deps[i][d] = _index(n.deps[d]);
            }
        }

        Node[] memory ordered = new Node[](count);
        bool[] memory placed = new bool[](count);
        for (uint256 k; k < count; ++k) {
            uint256 next = count;
            for (uint256 i; i < count; ++i) {
                if (placed[i] || _unplaced(deps[i], placed) != NONE) continue;
                if (next == count || rank[i] < rank[next]) next = i;
            }
            if (next == count) revert Cycle(_cycle(deps, placed));
            placed[next] = true;
            ordered[k] = _nodes[next];
        }
        delete _nodes;
        for (uint256 k; k < count; ++k) {
            _nodes.push(ordered[k]);
        }
    }

    function _unplaced(uint256[] memory deps, bool[] memory placed) private pure returns (uint256) {
        for (uint256 d; d < deps.length; ++d) {
            if (!placed[deps[d]]) return deps[d];
        }
        return NONE;
    }

    /// @dev Every unplaced node has an unplaced dependency, so following them from any unplaced node
    ///      must revisit one. Returns that loop as `a -> b -> a`, each arrow pointing from a
    ///      dependency to the node that needs it.
    function _cycle(uint256[][] memory deps, bool[] memory placed) private view returns (string memory out) {
        bool[] memory seen = new bool[](placed.length);
        uint256 cursor;
        while (placed[cursor]) ++cursor;
        while (!seen[cursor]) {
            seen[cursor] = true;
            cursor = _unplaced(deps[cursor], placed);
        }
        uint256 start = cursor;
        out = _nodes[start].id;
        do {
            cursor = _unplaced(deps[cursor], placed);
            out = string.concat(_nodes[cursor].id, " -> ", out);
        } while (cursor != start);
    }

    /// @dev Marks `targetIndex` and everything it depends on. Walks the list backwards: after
    ///      `_validateGraph` sorted it, dependencies precede their dependents, so a node is marked
    ///      before it is visited.
    function _closure(uint256 targetIndex) internal view returns (bool[] memory needed) {
        needed = new bool[](_nodes.length);
        needed[targetIndex] = true;
        for (uint256 i = targetIndex + 1; i > 0; --i) {
            if (!needed[i - 1]) continue;
            Node storage n = _nodes[i - 1];
            for (uint256 d; d < n.deps.length; ++d) {
                needed[_index(n.deps[d])] = true;
            }
        }
    }

    function _index(string memory name) internal view returns (uint256 i) {
        i = _find(name);
        require(i != _nodes.length, _cannotReach(name, "unknown target"));
    }

    function _find(string memory name) private view returns (uint256) {
        for (uint256 i; i < _nodes.length; ++i) {
            if (keccak256(bytes(_nodes[i].id)) == keccak256(bytes(name))) return i;
        }
        return _nodes.length;
    }

    function _time(string memory net, Node storage n) internal returns (uint256) {
        if (vm.contains(n.gate, ".")) return vm.parseUint(_input(net, n.gate));
        return abi.decode(_call(n.unit, _calldata(n, n.gate, net)), (uint256));
    }

    /// @dev Returns the selected fork, then selects `select` unless it is `type(uint256).max`. Returns
    ///      `type(uint256).max` when no fork is selected.
    function _fork(uint256 select) internal virtual returns (uint256 active) {
        try vm.activeFork() returns (uint256 id) {
            active = id;
            if (select != type(uint256).max) vm.selectFork(select);
        } catch {
            active = type(uint256).max;
        }
    }

    function _journalChecked(string memory net, string memory unit) internal view virtual returns (bool);

    function _input(string memory net, string memory ref) internal view virtual returns (string memory);

    function _isTestChain() internal view virtual returns (bool);

    /// @dev The `--rpc-url` value `plan` prints for `chain`, its `rpc`. An empty `chain` is the
    ///      default chain.
    function _rpcFlag(string memory, string memory) internal view virtual returns (string memory);

    /// @dev The variable assignments (`NAME=value `, each ending in a space) that start every command.
    function _commandEnv(string memory) internal view virtual returns (string memory) {
        return "";
    }

    /// @dev The comment lines `plan` opens with. `FileGraph` prints one `# chain` line per chain.
    function _chainLines(string memory) internal view virtual returns (string[] memory) {
        return new string[](0);
    }

    function _warnings(string memory out, string memory network, Visit[] memory visits, uint256 count, bool allUnits)
        private
        view
        returns (string memory)
    {
        string[] memory units = new string[](count);
        uint256 n;
        for (uint256 i; i < count; ++i) {
            if (allUnits || visits[i].status != Status.Done) units[n++] = vm.split(_nodes[visits[i].node].id, ".")[0];
        }
        // SAFETY: `n <= count`, so the shortened array lies within its allocation.
        assembly ("memory-safe") {
            mstore(units, n)
        }
        string[] memory warnings = _warningLines(network, units);
        for (uint256 i; i < warnings.length; ++i) {
            out = _line(out, string.concat("# warning ", warnings[i]));
        }
        return out;
    }

    /// @dev The text of each `# warning` line for the plan of network `net`, whose nodes belong to `units`
    ///      (a unit may repeat).
    function _warningLines(string memory, string[] memory) internal view virtual returns (string[] memory) {
        return new string[](0);
    }

    /// @dev Reverts if the step names a chain that network `net` lacks. Runs for each command
    ///      `plan` prints. A done node prints no command, so its chains are not checked.
    function _requireChains(string memory, Node storage) internal view virtual {}

    function _stage(string calldata network) internal virtual returns (string memory);

    function _prepareSender(string memory network, uint256 nodeIndex) internal virtual returns (bool);

    function _callStep(address unit, bytes memory callData) internal virtual returns (bool) {
        _call(unit, callData);
        return true;
    }

    /// @dev Called when a predicate is unmet with no date left to wait for, and not again until it is
    ///      met. Returns whether to judge it again.
    function _unmetPredicate(uint256 nodeIndex) internal virtual returns (bool);

    function _broadcasting() internal view virtual returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    function _sendStep(string memory network, uint256 nodeIndex) internal returns (bool) {
        if (!_prepareSender(network, nodeIndex)) return false;
        Node storage n = _nodes[nodeIndex];
        return _callStep(n.unit, _calldata(n, n.step, network));
    }

    function _command(string memory network, Node storage n) private view returns (string memory) {
        _requireChains(network, n);
        string memory sender =
            bytes(n.sender).length == 0 ? "$DEPLOYER" : vm.toString(_senderAddress(network, n.sender));
        return string.concat(
            _commandEnv(network),
            "forge script ",
            n.script,
            " --sig '",
            _signature(n, n.step),
            "' ",
            network,
            bytes(n.arg).length == 0 ? "" : string.concat(" ", n.arg),
            n.ownForks ? "" : string.concat(" --rpc-url ", _rpcFlag(network, n.on)),
            " --sender ",
            sender,
            n.slow ? " --slow" : ""
        );
    }

    /// @dev ` on <rpc>` for the chain whose clock the date is read against. Empty for the default
    ///      chain.
    function _clockOn(string memory network, Node storage n) private view returns (string memory) {
        string memory flag = _rpcFlag(network, n.on);
        require(
            bytes(flag).length != 0,
            string.concat(n.id, " has no chain: add .on(...) to it or set chains.default in sprue.json")
        );
        if (_onDefaultChain(network, n)) return "";
        return string.concat(" on ", flag);
    }

    function _onDefaultChain(string memory network, Node storage n) private view returns (bool) {
        return
            bytes(n.on).length == 0
                || keccak256(bytes(_rpcFlag(network, n.on))) == keccak256(bytes(_rpcFlag(network, "")));
    }

    function _dependenciesDone(uint256 nodeIndex, Status[] memory statuses) private view returns (bool) {
        bool[] memory needed = _closure(nodeIndex);
        for (uint256 i; i < nodeIndex; ++i) {
            if (needed[i] && statuses[i] != Status.Done) return false;
        }
        return true;
    }

    function _calldata(Node storage n, string memory fn, string memory net) private view returns (bytes memory) {
        bytes memory args = bytes(n.arg).length == 0 ? abi.encode(net) : abi.encode(net, vm.parseUint(n.arg));
        return bytes.concat(bytes4(keccak256(bytes(_signature(n, fn)))), args);
    }

    function _signature(Node storage n, string memory fn) private view returns (string memory) {
        return string.concat(fn, bytes(n.arg).length == 0 ? "(string)" : "(string,uint8)");
    }

    /// @dev Refuses the zero address, so that a placeholder in an input file fails the plan instead
    ///      of being printed as a sender.
    function _senderAddress(string memory net, string memory ref) internal view returns (address sender) {
        sender = vm.parseAddress(_input(net, ref));
        require(sender != address(0), string.concat(ref, " is the zero address: set it in the network's files"));
    }

    /// @dev An `Error(string)`'s text; any other revert as hex. A failed file read or JSON parse is the
    ///      project's own setup, never the world, so it fails the plan. Other cheatcodes stay waits: a
    ///      `vm.rpc` call fails when the contract it calls refuses for now.
    function _reason(string memory id, bytes memory ret) private pure returns (string memory) {
        string memory raw = vm.toString(ret);
        bytes4 selector = bytes4(ret);
        bool cheatcode = selector == bytes4(keccak256("CheatcodeError(string)"));
        if (ret.length < 68 || !(cheatcode || selector == bytes4(keccak256("Error(string)")))) return raw;
        assembly ("memory-safe") {
            let length := mload(ret)
            ret := add(ret, 4)
            mstore(ret, sub(length, 4))
        }
        string memory text = abi.decode(ret, (string));
        if (!cheatcode) return text;
        require(
            vm.indexOf(text, "vm.readFile") != 0 && vm.indexOf(text, "vm.parseJson") != 0, string.concat(id, ": ", text)
        );
        return raw;
    }

    function _cannotReach(string memory id, string memory reason) internal pure returns (string memory) {
        return string.concat("cannot reach ", id, ": ", reason);
    }

    function _line(string memory out, string memory line) private pure returns (string memory) {
        console.log(string.concat("PLAN ", line));
        return string.concat(out, line, "\n");
    }

    function _call(address target, bytes memory callData) internal returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(callData);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _nodeJson(Node storage n) private view returns (string memory) {
        return string.concat(
            '{"id":',
            _quote(n.id),
            ',"kind":',
            _quote(_kind(n)),
            ',"unit":',
            _quote(vm.split(n.id, ".")[0]),
            ',"signature":',
            _quote(_nodeSignature(n)),
            ',"sender":',
            _quote(n.sender),
            ',"on":',
            _quote(n.on),
            ',"reads":',
            _stringsJson(n.reads),
            ',"dependencies":',
            _stringsJson(n.deps),
            ',"doneRule":',
            _doneRuleJson(n),
            ',"gate":',
            _gateJson(n),
            ',"flags":',
            _flagsJson(n),
            "}"
        );
    }

    function _stringsJson(string[] storage values) private view returns (string memory out) {
        out = "[";
        for (uint256 i; i < values.length; ++i) {
            out = string.concat(out, i == 0 ? "" : ",", _quote(values[i]));
        }
        return string.concat(out, "]");
    }

    function _doneRuleJson(Node storage n) private view returns (string memory) {
        string memory kind;
        string memory signature;
        if (n.certified) {
            kind = "certificate";
        } else if (n.probed) {
            kind = "probe";
            signature = _signature(n, n.step);
        } else if (bytes(n.until).length != 0) {
            kind = "predicate";
            signature = _signature(n, n.until);
        } else {
            // `_validateGraph` refused any other step without a done rule, so this is a step with a
            // `Due` view.
            kind = "view";
            signature = _signature(n, string.concat(n.step, "Due"));
        }
        return string.concat('{"kind":', _quote(kind), ',"signature":', _quote(signature), "}");
    }

    function _nodeSignature(Node storage n) private view returns (string memory) {
        if (bytes(n.step).length != 0) return _signature(n, n.step);
        if (bytes(n.until).length != 0) return _signature(n, n.until);
        return "";
    }

    function _gateJson(Node storage n) private view returns (string memory) {
        bool input = vm.indexOf(n.gate, ".") != type(uint256).max;
        string memory kind = bytes(n.gate).length == 0 ? "none" : input ? "input" : "view";
        string memory value = bytes(n.gate).length == 0 ? "" : input ? n.gate : _signature(n, n.gate);
        return string.concat('{"kind":', _quote(kind), ',"value":', _quote(value), "}");
    }

    function _flagsJson(Node storage n) private view returns (string memory) {
        return string.concat(
            '{"slow":',
            n.slow ? "true" : "false",
            ',"testOnly":',
            n.testOnly ? "true" : "false",
            ',"ownForks":',
            n.ownForks ? "true" : "false",
            ',"argument":',
            bytes(n.arg).length == 0 ? "null" : n.arg,
            "}"
        );
    }

    function _kind(Node storage n) private view returns (string memory) {
        return bytes(n.step).length != 0 ? "step" : "predicate";
    }

    /// @dev The graph's author writes every value, so refusing the characters JSON would escape is
    ///      enough to keep the export valid, and no escaping code is needed.
    function _quote(string memory value) private pure returns (string memory) {
        bytes memory raw = bytes(value);
        for (uint256 i; i < raw.length; ++i) {
            require(raw[i] >= 0x20 && raw[i] != '"' && raw[i] != "\\", string.concat("not JSON-safe: ", value));
        }
        return string.concat('"', value, '"');
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {Registration, IUnitSteps, Step, StepKind} from "./Step.sol";

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
        /// @dev The unit has a view `<step>Due`. It returns true while the step still has work and
        ///      false once the step is done. It reverts while the step would refuse to run.
        bool due;
        /// @dev The step creates its own forks, so `plan` prints its command without `--rpc-url`.
        bool ownForks;
        /// @dev Done once the unit's journal holds `checked`. `plan` reads that file and does not
        ///      call the step.
        bool certified;
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

    uint256 private constant NONE = type(uint256).max;

    Node[] internal _nodes;
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
        if (_execute(net, target)) console.log(string.concat("reached ", target));
    }

    /// @notice The commands that reach `target` and what it depends on, in order. Each line is
    ///         printed behind `PLAN ` and the lines are returned together.
    ///
    ///         Each command is a dry run. The same command with `--account <keystore> --broadcast`
    ///         sends it. `$R` is the RPC URL of the default chain and `$DEPLOYER` the account that
    ///         sends a step with no `.by`. A command whose script reads a chain through an
    ///         environment variable starts with that variable's assignment.
    ///
    ///         Every other line is a comment, `# <keyword> ...`. The executor rejects any keyword not
    ///         listed here:
    ///         - `# chain <chain> <chain id> <kind>`: a chain of `network.json`. These lines come
    ///           before everything else.
    ///         - `# done <id>`: the chain or the journal shows the node done. No command follows.
    ///         - `# not before <unix time> [on <RPC variable or alias>] <id>[, movable until reached]`:
    ///           the node's date has not been reached on that chain (without `on`, the chain `$R`
    ///           serves). The command after it is valid only once the date is reached.
    ///         - `# cannot reach <id>: <reason>`: the node's step would refuse now, and its command
    ///           follows; or, for a predicate node, its condition is not met, and no command follows.
    ///         - `# then plan again <id>`: what follows depends on commands above that have not
    ///           landed. The plan ends here.
    function plan(string calldata network, string calldata target) external returns (string memory out) {
        string[] memory header = _chainLines(network);
        (Visit[] memory visits, uint256 count) = _walk(network, target, new bool[](_nodes.length));
        for (uint256 i; i < header.length; ++i) {
            out = _line(out, header[i]);
        }
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
    /// @dev Each line is also logged behind `GRAPH `, which is how `graph.sh json` reads it.
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
    ///      cannot be judged yet. `passed` marks steps a rehearsal has already simulated.
    function _walk(string memory network, string memory target, bool[] memory passed)
        internal
        returns (Visit[] memory visits, uint256 count)
    {
        bool[] memory needed = _closure(target);
        Status[] memory statuses = new Status[](_nodes.length);
        visits = new Visit[](_nodes.length);
        for (uint256 i; i < _nodes.length; ++i) {
            if (!needed[i]) continue;
            Node storage n = _nodes[i];
            Visit memory visit;
            visit.node = i;
            if (!_dependenciesDone(i, statuses) && (n.due || bytes(n.until).length != 0)) {
                visit.status = Status.NotJudged;
            } else {
                if (bytes(n.gate).length != 0) {
                    visit.notBefore = _time(network, n);
                    if (block.timestamp >= visit.notBefore) visit.notBefore = 0;
                }
                // The date is fixed and not yet reached, so the step's `Due` view would be read on a
                // chain still before it. Leave the step unjudged for the plan made after the date.
                if (visit.notBefore != 0 && vm.contains(n.gate, ".")) visit.status = Status.NotJudged;
                else (visit.status, visit.reason) = _status(network, n, passed[i]);
            }
            statuses[i] = visit.status;
            visits[count++] = visit;
            if (visit.status == Status.NotJudged) break;
        }
    }

    function _execute(string memory network, string memory target) internal returns (bool reached) {
        // A simulated step is not sent, so `_status` may not see its effect. `passed` records the steps
        // already run, so that each runs once.
        bool[] memory passed = new bool[](_nodes.length);
        while (true) {
            (Visit[] memory visits, uint256 count) = _walk(network, target, passed);
            bool advanced;
            bool replan;
            for (uint256 i; i < count; ++i) {
                Visit memory visit = visits[i];
                Node storage n = _nodes[visit.node];
                if (visit.status == Status.Done) continue;
                if (visit.status == Status.NotJudged) {
                    if (visit.notBefore != 0) {
                        _warpToDate(network, n);
                        advanced = true;
                    }
                    replan = true;
                    break;
                }
                if (visit.status == Status.Waiting && bytes(n.until).length != 0) {
                    // The predicate was judged before its date. Warp to the date and judge again. If there
                    // was no date to warp to and the condition is unmet, stop.
                    if (!_warpToDate(network, n) && !_unmetPredicate(visit.node)) return false;
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
            if (!ok) return (Status.Waiting, _reason(ret));
            return (abi.decode(ret, (bool)) ? Status.Done : Status.Waiting, "its condition is not met");
        }
        if (n.due) {
            (bool ok, bytes memory ret) = n.unit.call(_calldata(n, string.concat(n.step, "Due"), network));
            if (!ok) return (Status.Waiting, _reason(ret));
            return (abi.decode(ret, (bool)) ? Status.Due : Status.Done, "");
        }
        return (Status.Due, "");
    }

    function _add(address target, string memory script) internal {
        _units.push(target);
        _add(Registration(target, script), IUnitSteps(target).steps());
    }

    function _add(Registration memory unit, Step[] memory steps) internal {
        // Keeps the unit's contract alive when a step later selects another fork.
        vm.makePersistent(unit.target);
        for (uint256 i; i < steps.length; ++i) {
            Step memory s = steps[i];
            require(s.kind != StepKind.Empty && bytes(s.id).length != 0, EmptyStep(i));
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
            n.gate = s.gate;
            n.on = s.onChain;
            n.reads = s.readChains;
            n.slow = s.isSlow;
            n.testOnly = s.testOnly;
            if (s.hasArg) n.arg = vm.toString(s.arg);
            n.due = s.dueSelector != 0;
            n.ownForks = s.ownForks;
        }
    }

    /// @dev Call after the last `_add`. Reverts unless every dependency exists, no production node
    ///      depends on a test-only node, every node's unit is registered and the graph has no cycle,
    ///      and every step has a done rule: a `Due` view, or a `check` step of its unit that reaches
    ///      it through `needs`. Sorts the nodes (`_order`).
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
                    ancestors[j] && n.unit == check.unit && !n.due && bytes(n.step).length != 0
                        && keccak256(bytes(vm.split(n.id, ".")[0])) == journal
                ) {
                    // An earlier `check` among the ancestors is refused: it would write `checked` first,
                    // and that would mark this `check` done without running it.
                    require(j == i || keccak256(bytes(n.step)) != keccak256("check"), MissingDoneRule(check.id));
                    n.certified = true;
                }
            }
        }
        for (uint256 i; i < _nodes.length; ++i) {
            Node storage n = _nodes[i];
            require(bytes(n.step).length == 0 || n.due || n.certified, MissingDoneRule(n.id));
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
        uint256 at;
        while (placed[at]) ++at;
        while (!seen[at]) {
            seen[at] = true;
            at = _unplaced(deps[at], placed);
        }
        uint256 start = at;
        out = _nodes[start].id;
        do {
            at = _unplaced(deps[at], placed);
            out = string.concat(_nodes[at].id, " -> ", out);
        } while (at != start);
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

    function _journalChecked(string memory net, string memory unit) internal view virtual returns (bool);

    function _input(string memory net, string memory ref) internal view virtual returns (string memory);

    function _isTestChain() internal view virtual returns (bool);

    /// @dev The `--rpc-url` value `plan` prints for `chain`: a `foundry.toml` alias, or an
    ///      environment variable with its `$`. An empty `chain` is the default chain, which `plan`
    ///      reaches with `$R`.
    function _rpcFlag(string memory, string memory) internal view virtual returns (string memory) {
        return "$R";
    }

    /// @dev The variable assignments (`NAME=$NAME `, each ending in a space) that start a command
    ///      whose script reads the named chains through environment variables. An empty name is the
    ///      default chain.
    function _chainEnv(string memory, string[] memory) internal view virtual returns (string memory) {
        return "";
    }

    /// @dev The comment lines `plan` opens with. `FileGraph` prints one `# chain` line per chain.
    function _chainLines(string memory) internal view virtual returns (string[] memory) {
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
            _chainEnv(network, _envChains(n)),
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

    /// @dev The chains the command's script reads by variable: what the step reads, and, when it
    ///      selects its own forks, the one it sends on.
    function _envChains(Node storage n) private view returns (string[] memory chains) {
        uint256 count = n.reads.length;
        chains = new string[](count + (n.ownForks ? 1 : 0));
        for (uint256 i; i < count; ++i) {
            chains[i] = n.reads[i];
        }
        if (n.ownForks) chains[count] = n.on;
    }

    /// @dev ` on <name>` for the chain whose clock the date is read against. Empty when `$R` already
    ///      serves that chain.
    function _clockOn(string memory network, Node storage n) private view returns (string memory) {
        string memory flag = _rpcFlag(network, n.on);
        require(
            bytes(flag).length != 0,
            string.concat(n.id, " has no chain: add .on(...) to it or set chains.default in sprue.json")
        );
        if (bytes(n.on).length == 0) return "";
        if (keccak256(bytes(flag)) == keccak256(bytes(_rpcFlag(network, "")))) return "";
        return string.concat(" on ", vm.replace(flag, "$", ""));
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

    /// @dev An `Error(string)`'s text; any other revert as hex.
    function _reason(bytes memory ret) private pure returns (string memory) {
        if (ret.length < 68 || bytes4(ret) != bytes4(keccak256("Error(string)"))) return vm.toString(ret);
        assembly ("memory-safe") {
            let length := mload(ret)
            ret := add(ret, 4)
            mstore(ret, sub(length, 4))
        }
        return abi.decode(ret, (string));
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
        } else if (bytes(n.until).length != 0) {
            kind = "predicate";
            signature = _signature(n, n.until);
        } else {
            // `_validateGraph` refused any step without a done rule, so this is a step with a `Due`
            // view.
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {Graph} from "../src/graph/Graph.sol";
import {Registration, Step, Declares} from "../src/graph/Step.sol";
import {BuilderGraph, StepFunctions} from "./StepBuilders.t.sol";

contract ClosureGraph is BuilderGraph {
    constructor(Registration memory unit) BuilderGraph(unit, new Step[](0)) {}

    function needed(string calldata id) external view returns (bool[] memory) {
        return _closure(id);
    }
}

/// @notice Random dependency graphs against a straight-line model of `Graph._order`, `_closure` and
///         the cycle refusal.
contract GraphOrderTest is Test, Declares {
    uint256 private constant MAX = 8;

    struct Model {
        uint256 count;
        uint256[MAX] unit; // 0 or 1: the registration rank
        uint256[MAX] deps; // bit j: node i needs node j
    }

    /// @dev Node i is the i-th declared; unit 0 is registered before unit 1.
    function _model(uint256 seed) private pure returns (Model memory m) {
        m.count = 1 + seed % MAX;
        bool acyclic = (seed >> 8) % 4 != 0;
        uint256 threshold = [uint256(30), 80, 160][(seed >> 10) % 3];
        for (uint256 i; i < m.count; ++i) {
            m.unit[i] = (seed >> (12 + i)) & 1;
            for (uint256 j; j < m.count; ++j) {
                if (uint8(uint256(keccak256(abi.encode(seed, i, j)))) >= threshold) continue;
                // A hidden total order keeps the graph acyclic.
                if (
                    acyclic
                        && uint256(keccak256(abi.encode(seed, "rank", j)))
                            >= uint256(keccak256(abi.encode(seed, "rank", i)))
                ) {
                    continue;
                }
                m.deps[i] |= 1 << j;
            }
        }
    }

    /// @dev Kahn's algorithm: of the ready nodes, the lowest (unit rank, declaration index).
    ///      Returns `count` entries of `MAX` (placed == false) on a cycle.
    function _expected(Model memory m) private pure returns (uint256[] memory order, bool acyclic) {
        order = new uint256[](m.count);
        uint256 placed;
        for (uint256 k; k < m.count; ++k) {
            uint256 next = type(uint256).max;
            for (uint256 i; i < m.count; ++i) {
                if (placed >> i & 1 == 1 || m.deps[i] & ~placed != 0) continue;
                if (next == type(uint256).max || m.unit[i] < m.unit[next]) next = i;
            }
            if (next == type(uint256).max) return (order, false);
            order[k] = next;
            placed |= 1 << next;
        }
        return (order, true);
    }

    function _ancestors(Model memory m, uint256 target) private pure returns (uint256 seen) {
        seen = 1 << target;
        for (uint256 pass; pass < m.count; ++pass) {
            for (uint256 i; i < m.count; ++i) {
                if (seen >> i & 1 == 1) seen |= m.deps[i];
            }
        }
    }

    function _id(uint256 i) private pure returns (string memory) {
        return string.concat("n", vm.toString(i));
    }

    function _build(Model memory m, ClosureGraph g, Registration memory a, Registration memory b) private {
        g.listUnit(b.target);
        for (uint256 i; i < m.count; ++i) {
            Step[] memory steps = new Step[](1);
            steps[0] = _step(_id(i), "fund", StepFunctions.fund.selector).due(StepFunctions.fundDue.selector);
            for (uint256 j; j < m.count; ++j) {
                if (m.deps[i] >> j & 1 == 1) steps[0] = steps[0].needs(_id(j));
            }
            g.add(m.unit[i] == 0 ? a : b, steps);
        }
    }

    function _graph(Model memory m) private returns (ClosureGraph g) {
        Registration memory a = Registration(address(new StepFunctions()), "a.s.sol");
        Registration memory b = Registration(address(new StepFunctions()), "b.s.sol");
        g = new ClosureGraph(a);
        _build(m, g, a, b);
    }

    function testFuzz_order_isTheLowestReadyNode_andACycleIsRefused(uint256 seed) public {
        Model memory m = _model(seed);
        (uint256[] memory order, bool acyclic) = _expected(m);
        ClosureGraph g = _graph(m);

        if (!acyclic) {
            (bool ok, bytes memory ret) = address(g).call(abi.encodeCall(BuilderGraph.validate, ()));
            assertFalse(ok, "a cycle was accepted");
            assertEq(bytes4(ret), Graph.Cycle.selector);
            return;
        }
        g.validate();

        for (uint256 k; k < m.count; ++k) {
            assertEq(g.node(k).id, _id(order[k]), "order");
        }
        // Sorting again changes nothing.
        g.validate();
        for (uint256 k; k < m.count; ++k) {
            assertEq(g.node(k).id, _id(order[k]), "order is not stable");
        }
    }

    function testFuzz_closure_isExactlyTheAncestors(uint256 seed) public {
        Model memory m = _model(seed);
        (uint256[] memory order, bool acyclic) = _expected(m);
        vm.assume(acyclic);
        ClosureGraph g = _graph(m);
        g.validate();

        for (uint256 t; t < m.count; ++t) {
            bool[] memory needed = g.needed(_id(t));
            uint256 want = _ancestors(m, t);
            for (uint256 k; k < m.count; ++k) {
                assertEq(needed[k], want >> order[k] & 1 == 1, "closure");
            }
        }
    }

    /// @dev `a -> b` reads "b needs a", and the loop closes on its first node.
    function testFuzz_cycleNamesARealLoop(uint256 seed) public {
        Model memory m = _model(seed);
        (, bool acyclic) = _expected(m);
        vm.assume(!acyclic);
        ClosureGraph g = _graph(m);

        (bool ok, bytes memory ret) = address(g).call(abi.encodeCall(BuilderGraph.validate, ()));
        assertFalse(ok);
        string[] memory loop;
        {
            bytes memory data = new bytes(ret.length - 4);
            for (uint256 i; i < data.length; ++i) {
                data[i] = ret[i + 4];
            }
            loop = vm.split(abi.decode(data, (string)), " -> ");
        }
        assertGe(loop.length, 2);
        assertEq(loop[0], loop[loop.length - 1], "the loop does not close");
        for (uint256 k; k + 1 < loop.length; ++k) {
            uint256 from = vm.parseUint(vm.replace(loop[k], "n", ""));
            uint256 to = vm.parseUint(vm.replace(loop[k + 1], "n", ""));
            assertEq(m.deps[to] >> from & 1, 1, "an arrow is not a dependency");
        }
    }

    function testFuzz_anUnknownNeedIsRefused(uint256 seed, uint8 slot) public {
        Model memory m = _model(seed);
        m.deps[slot % m.count] = 0;
        Registration memory a = Registration(address(new StepFunctions()), "a.s.sol");
        ClosureGraph g = new ClosureGraph(a);
        Step[] memory steps = new Step[](m.count);
        for (uint256 i; i < m.count; ++i) {
            steps[i] = _step(_id(i), "fund", StepFunctions.fund.selector).due(StepFunctions.fundDue.selector);
        }
        steps[slot % m.count] = steps[slot % m.count].needs("ghost");
        g.add(a, steps);
        vm.expectRevert(abi.encodeWithSelector(Graph.MissingDependency.selector, _id(slot % m.count), "ghost"));
        g.validate();
    }
}

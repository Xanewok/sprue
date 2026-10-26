// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {GraphTest} from "./GraphTest.sol";
import {FIXTURE_SENDER} from "../src/graph/Graph.sol";
import {RawGraph, RawUnit} from "./RawGraph.sol";

/// @dev Steps that send on a rerun in ways the fixture must see.
contract GraphMutantsTest is GraphTest {
    RawGraph private graph;
    bool private nest;

    function setUp() public {
        vm.chainId(31337);
        string memory dir = "deployments/graphtest-source-raw";
        vm.createDir(dir, true);
        vm.writeFile(string.concat(dir, "/network.json"), '{"chains":{"l2":{"id":31337,"rpc":"local"}}}');
        vm.writeFile(
            string.concat(dir, "/raw.input.json"),
            string.concat('{"operator":"', vm.toString(makeAddr("operator")), '"}')
        );
        graph = new RawGraph();
        _useGraph(graph, "graphtest-source-raw", string.concat("raw-", vm.toString(vm.randomUint())));
    }

    function again(string memory node) external {
        quiet(node);
    }

    function test_quiet_failsOnASilentSetter() public {
        vm.expectRevert("raw.silent sends on a rerun");
        this.again("raw.silent");
    }

    function test_quiet_failsOnARawBroadcastSend() public {
        vm.expectRevert("raw.raw sends on a rerun");
        this.again("raw.raw");
    }

    function test_quiet_failsOnARawSendWhoseCalldataStartsLikeAProbe() public {
        vm.expectRevert("raw.stray sends on a rerun");
        this.again("raw.stray");
    }

    function test_quiet_failsOnABodyThatBranchesOnItsCaller() public {
        vm.expectRevert("raw.gated is not done by the planner");
        this.again("raw.gated");
    }

    function test_runNode_failsOnASendOutsideTheStepsCall() public {
        vm.expectRevert(bytes(string.concat(vm.toString(FIXTURE_SENDER), " sent outside a step's call")));
        this.once("raw.hidden");
    }

    function once(string memory node) external {
        runNode(node);
    }

    function test_quiet_failsOnAnUnnamedSendWhileThePlannerJudges() public {
        vm.expectRevert(
            bytes(string.concat(vm.toString(RawUnit(graph.node(0).unit).STRAY()), " sent outside a step's call"))
        );
        this.again("raw.unnamed");
    }

    function test_quiet_failsOnASendInTheFirstJudgment() public {
        upTo("raw.judge");
        vm.expectRevert(bytes(string.concat(vm.toString(FIXTURE_SENDER), " sent outside a step's call")));
        this.again("raw.judge");
    }

    function test_quiet_failsOnAnExplicitDueThatHidesACallerBranch() public {
        vm.expectRevert("raw.explicit would send as its sender");
        this.again("raw.explicit");
    }

    function _meet(string memory) internal override returns (bool) {
        if (nest) runNode("raw.silent");
        RawUnit(graph.node(0).unit).setOpen();
        return true;
    }

    function reach(string memory node) external {
        upTo(node);
    }

    function test_runNode_refusesToNestInAMeet() public {
        nest = true;
        vm.expectRevert("a fixture run is already running");
        this.reach("raw.gate");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {Graph} from "../src/graph/Graph.sol";
import {Declares, Step, Registration} from "../src/graph/Step.sol";

/// @dev The graph with a unit of its own and no project: everything a consumer of the library sees.
contract Toy is Declares {
    bool public deployed;
    bool public checked;

    function deploy(string calldata) external {
        deployed = true;
    }

    function deployDue(string calldata) external view returns (bool) {
        return !deployed;
    }

    function check(string calldata) external {
        checked = true;
    }

    function checkDue(string calldata) external view returns (bool) {
        return !checked;
    }

    function steps() external pure returns (Step[] memory s) {
        s = new Step[](2);
        s[0] = _step("toy.check", this.check.selector)
            .due(this.checkDue.selector)
            .needs("toy.deploy")
            .notBefore("toy.openAt");
        s[1] = _step("toy.deploy", this.deploy.selector).due(this.deployDue.selector);
    }
}

contract ToyGraph is Graph {
    Toy public toy = new Toy();

    constructor(Step[] memory extra) {
        _add(address(toy), "toy.s.sol:Toy");
        _add(Registration(address(toy), "toy.s.sol:Toy"), extra);
        _validateGraph();
    }

    function _journalChecked(string memory, string memory) internal pure override returns (bool) {
        return false;
    }

    function _input(string memory, string memory) internal pure override returns (string memory) {
        return "100";
    }

    function _isTestChain() internal pure override returns (bool) {
        return false;
    }

    function _stage(string calldata network) internal pure override returns (string memory) {
        return network;
    }

    function _prepareSender(string memory, uint256) internal pure override returns (bool) {
        return true;
    }

    function _unmetPredicate(uint256) internal pure override returns (bool) {
        return false;
    }
}

/// @dev Chains `near` (a variable) and `far` (an alias).
contract ChainGraph is ToyGraph {
    constructor() ToyGraph(new Step[](0)) {
        Node storage sends = _nodes[_index("toy.deploy")];
        sends.on = "far";
        sends.reads.push("near");
        Node storage owns = _nodes[_index("toy.check")];
        owns.on = "near";
        owns.reads.push("far");
        owns.ownForks = true;
    }

    function _rpcFlag(string memory, string memory chain) internal pure override returns (string memory) {
        if (keccak256(bytes(chain)) == keccak256("far")) return "farnet";
        return bytes(chain).length == 0 ? "$R" : "$NEAR_RPC";
    }

    function _chainEnv(string memory, string[] memory chains) internal pure override returns (string memory out) {
        for (uint256 i; i < chains.length; ++i) {
            out = string.concat(out, chains[i], "=$", chains[i], " ");
        }
    }
}

contract CoreTest is Test, Declares {
    string private constant GOLDEN = '{"nodes":[\n'
        '{"id":"toy.deploy","kind":"step","unit":"toy","signature":"deploy(string)","sender":"","on":"","reads":[],"dependencies":[],"doneRule":{"kind":"view","signature":"deployDue(string)"},"gate":{"kind":"none","value":""},"flags":{"slow":false,"testOnly":false,"ownForks":false,"argument":null}},\n'
        '{"id":"toy.check","kind":"step","unit":"toy","signature":"check(string)","sender":"","on":"","reads":[],"dependencies":["toy.deploy"],"doneRule":{"kind":"view","signature":"checkDue(string)"},"gate":{"kind":"input","value":"toy.openAt"},"flags":{"slow":false,"testOnly":false,"ownForks":false,"argument":null}},\n'
        '{"id":"x.rich","kind":"step","unit":"x","signature":"deploy(string,uint8)","sender":"toy.owner","on":"far","reads":["near"],"dependencies":["toy.check"],"doneRule":{"kind":"view","signature":"deployDue(string,uint8)"},"gate":{"kind":"none","value":""},"flags":{"slow":true,"testOnly":true,"ownForks":false,"argument":7}},\n'
        '{"id":"x.open","kind":"predicate","unit":"x","signature":"observed(string)","sender":"","on":"","reads":[],"dependencies":["x.rich"],"doneRule":{"kind":"predicate","signature":"observed(string)"},"gate":{"kind":"none","value":""},"flags":{"slow":false,"testOnly":true,"ownForks":false,"argument":null}}\n'
        "]}\n";

    ToyGraph private g = new ToyGraph(new Step[](0));

    function _node(string memory id) private view returns (Step memory) {
        return _step(id, "deploy", g.toy().deploy.selector).due(g.toy().deployDue.selector);
    }

    function test_plan_blocksADependentUntilItsDependencyIsDone() public {
        assertEq(
            g.plan("net", "toy.check"),
            "forge script toy.s.sol:Toy --sig 'deploy(string)' net --rpc-url $R --sender $DEPLOYER\n"
            "# then plan again toy.check\n"
        );
    }

    function test_plan_marksWhatTheChainHasDone() public {
        g.toy().deploy("net");
        vm.warp(100);
        assertEq(
            g.plan("net", "toy.check"),
            "# done toy.deploy\n"
            "forge script toy.s.sol:Toy --sig 'check(string)' net --rpc-url $R --sender $DEPLOYER\n"
        );
    }

    function test_plan_judgesAStepGatedByAnInputOnlyFromItsDate() public {
        g.toy().deploy("net");
        assertEq(
            g.plan("net", "toy.check"), "# done toy.deploy\n# not before 100 toy.check\n# then plan again toy.check\n"
        );
    }

    function test_rehearse_runsTheClosureAndWarpsToTheDate() public {
        g.rehearse("net", "toy.check");
        assertTrue(g.toy().deployed());
        assertTrue(g.toy().checked());
        assertEq(block.timestamp, 100);
    }

    function test_rehearse_refusesForgesDefaultSender() public {
        vm.prank(DEFAULT_SENDER);
        vm.expectRevert("pass --sender <deployer> to the dry run, or --account");
        g.rehearse("net", "toy.check");
    }

    function test_rehearse_doesNotCrossADateAlreadyPast() public {
        vm.warp(101);
        g.rehearse("net", "toy.check");
        assertEq(block.timestamp, 101);
    }

    /// @dev A test-only node is unknown off a test chain, which `ToyGraph` is.
    function test_unknownTarget_isRefused() public {
        vm.expectRevert("cannot reach nope: unknown target");
        g.plan("net", "nope");

        Step[] memory s = new Step[](1);
        s[0] = _node("x.test").forTests();
        ToyGraph withTestNode = new ToyGraph(s);
        vm.expectRevert("cannot reach x.test: unknown target");
        withTestNode.plan("net", "x.test");
    }

    function test_list_namesTheNodesNothingDependsOn() public view {
        assertEq(g.list(), "toy.check\n");
    }

    function test_graph_exportsOneLinePerNode_andRefusesWhatJsonWouldEscape() public {
        Step[] memory s = new Step[](2);
        s[0] = _step("x.rich", "deploy", bytes4(keccak256("deploy(string,uint8)")))
            .needs("toy.check")
            .by("toy.owner")
            .on("far")
            .reads("near")
            .slow()
            .forTests()
            .withArg(7)
            .due(bytes4(keccak256("deployDue(string,uint8)")));
        s[1] = _until("x.open", "observed", bytes4(keccak256("observed(string)"))).needs("x.rich").forTests();
        assertEq(new ToyGraph(s).graph(), GOLDEN);

        s = new Step[](1);
        s[0] = _node('x."quoted"');
        ToyGraph quoted = new ToyGraph(s);
        vm.expectRevert(bytes('not JSON-safe: x."quoted"'));
        quoted.graph();
    }

    function test_plan_namesTheChainsAStepSendsOnAndReads() public {
        ChainGraph chains = new ChainGraph();
        assertEq(
            chains.plan("net", "toy.deploy"),
            "near=$near forge script toy.s.sol:Toy --sig 'deploy(string)' net --rpc-url farnet --sender $DEPLOYER\n"
        );
        chains.toy().deploy("net");
        vm.warp(100);
        assertEq(
            chains.plan("net", "toy.check"),
            "# done toy.deploy\n"
            "far=$far near=$near forge script toy.s.sol:Toy --sig 'check(string)' net --sender $DEPLOYER\n"
        );
    }
}

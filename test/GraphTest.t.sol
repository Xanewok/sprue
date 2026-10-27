// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {rehearsalPrefix} from "../src/Chains.sol";
import {Graph} from "../src/graph/Graph.sol";
import {FixtureVault} from "./FixtureVault.sol";
import {GraphTest} from "./GraphTest.sol";
import {LIMIT, SUPPLY, TokenUnit, VaultGraph, VaultUnit} from "./VaultGraph.sol";

/// @dev Linked, so forge deploys it with the test, and that deployment shows in the test's first recording.
library Linked {
    function one() external pure returns (uint256) {
        return 1;
    }
}

contract GraphFixtureTest is GraphTest {
    uint256 private constant OPEN_AT = 2_000_000_000;

    address private deployer = makeAddr("deployer");
    address private operator = makeAddr("operator");
    VaultGraph private graph;
    string private net;
    bool private approve;

    function _world(string memory session) private {
        vm.chainId(31337);
        string memory source = string.concat("graphtest-source-", session);
        string memory dir = string.concat("deployments/", source);
        vm.createDir(dir, true);
        vm.writeFile(
            string.concat(dir, "/network.json"),
            string.concat('{"deployer":"', vm.toString(deployer), '","chains":{"l2":{"id":31337,"rpc":"local"}}}')
        );
        vm.writeFile(
            string.concat(dir, "/vault.input.json"),
            string.concat('{"openAt":', vm.toString(OPEN_AT), ',"operator":"', vm.toString(operator), '"}')
        );
        graph = new VaultGraph();
        _useGraph(graph, source, session);
        net = string.concat(rehearsalPrefix(), "-", session);
    }

    function _meet(string memory) internal override returns (bool) {
        if (!approve) return false;
        FixtureVault(role("vault", ".vault")).approve();
        return true;
    }

    function reach(string memory node) external {
        upTo(node);
    }

    function test_upTo_sendsTheClosureFromEachStepsOwnAccount() public {
        _world("closure");
        Sent[] memory sent = upTo("vault.check");

        assertEq(sent.length, 4);
        // token.deploy and vault.deploy: the pinned deployer's CREATEs.
        assertTrue(sent[0].create && sent[1].create);
        assertEq(sent[0].from, deployer);
        assertEq(sent[1].from, deployer);
        assertEq(sent[0].to, role("token", ".token"));
        assertEq(sent[1].to, role("vault", ".vault"));
        assertEq(sent[0].nonce, 0);
        assertEq(sent[1].nonce, 1);
        // vault.configure is the operator's, on the vault.
        assertEq(sent[2].from, operator);
        assertFalse(sent[2].create);
        assertEq(sent[2].to, role("vault", ".vault"));
        assertEq(sent[2].nonce, 0);
        assertEq(FixtureVault(sent[2].to).limit(), LIMIT);
        // vault.fund is the deployer's again.
        assertEq(sent[3].from, deployer);
        assertEq(sent[3].to, role("token", ".token"));
        assertEq(sent[3].nonce, 2);
        assertEq(uint8(graph.status(net, "vault.check")), uint8(Graph.Status.Done));
    }

    function test_upTo_ignoresALinkedLibrarysDeployment() public {
        _world("linked");
        assertEq(Linked.one(), 1);
        assertEq(upTo("token.check").length, 1);
    }

    function test_upTo_aSecondRunSendsNothing() public {
        _world("second");
        upTo("vault.check");
        uint256 deployerNonce = vm.getNonce(deployer);
        uint256 operatorNonce = vm.getNonce(operator);
        assertEq(upTo("vault.check").length, 0);
        assertEq(vm.getNonce(deployer), deployerNonce);
        assertEq(vm.getNonce(operator), operatorNonce);
    }

    function test_quiet_holdsForEveryStepOfAFinishedClosure() public {
        _world("quiet");
        upTo("vault.check");
        quiet("vault.check");
    }

    function test_upTo_warpsToADateGateOnlyForTheStepsThatHaveOne() public {
        _world("date");
        upTo("vault.configure");
        assertLt(block.timestamp, OPEN_AT);
        upTo("vault.fund");
        assertEq(block.timestamp, OPEN_AT);
    }

    function test_needsOf_runsTheClosureWithoutTheNode_andRunNodeSendsTheNode() public {
        _world("needs");
        assertEq(needsOf("vault.configure").length, 2);
        assertEq(uint8(graph.status(net, "vault.configure")), uint8(Graph.Status.Due));
        Sent[] memory sent = runNode("vault.configure");
        assertEq(sent.length, 1);
        assertEq(sent[0].from, operator);
        assertEq(sent[0].data, abi.encodeCall(FixtureVault.configure, (LIMIT)));
        assertEq(runNode("vault.configure").length, 0);
    }

    function test_upTo_anUnmetPredicateFails() public {
        _world("unmet");
        vm.expectRevert("the fixture cannot reach vault.approved");
        this.reach("vault.approved");
    }

    function test_upTo_aPredicateTheTestMeetsPasses() public {
        _world("met");
        approve = true;
        upTo("vault.approved");
        assertTrue(FixtureVault(role("vault", ".vault")).approved());
        quiet("vault.approved");
    }

    function test_stepCalldata_isTheCommandsCall() public {
        _world("calldata");
        assertEq(graph.stepCalldata(net, "vault.fund"), abi.encodeWithSignature("fund(string)", net));
        assertEq(graph.fixtureSender(net, "vault.configure"), operator);
        assertEq(graph.fixtureSender(net, "vault.fund"), deployer);
    }

    /// @dev The two sessions share the source and the filesystem, and run on separate threads.
    function test_sessions_runInParallel_a() public {
        _world("parallel-a");
        assertEq(upTo("vault.check").length, 4);
        assertTrue(vm.exists(string.concat("deployments/", net, "/vault.json")));
    }

    function test_sessions_runInParallel_b() public {
        _world("parallel-b");
        assertEq(upTo("vault.check").length, 4);
        assertTrue(vm.exists(string.concat("deployments/", net, "/vault.json")));
    }

    /// @dev A unit that did not make a role proves it only against an observed creation, and only if that
    ///      creation sent the initcode the journal records.
    function test_trustTestCreationAt_vouchesForTheJournaledInitcodeOnly() public {
        _world("witness");
        Sent[] memory sent = upTo("token.deploy");
        TokenUnit fresh = new TokenUnit();
        address token = sent[0].to;
        bytes32 hash = keccak256(abi.encodePacked(vm.getCode("FixtureToken.sol:FixtureToken"), abi.encode(SUPPLY)));
        assertEq(keccak256(sent[0].data), hash);

        vm.expectRevert(
            bytes(
                "neither token.json, a broadcast record nor the chain shows the transaction that created token: journal it as tokenTx"
            )
        );
        fresh.check(net);

        fresh.trustTestCreationAt(token, hex"01");
        vm.expectRevert(bytes("token's witnessed creation sent other initcode or arguments than its input"));
        fresh.check(net);

        fresh.trustTestCreationAt(token, sent[0].data);
        fresh.check(net);
    }

    function test_trustTestCreationAt_refusesNoInitcode() public {
        _world("zero");
        Sent[] memory sent = upTo("token.deploy");
        TokenUnit fresh = new TokenUnit();
        vm.expectRevert(bytes("a witnessed creation needs its initcode"));
        fresh.trustTestCreationAt(sent[0].to, "");
    }

    /// @dev Changing the input and the journal's arguments together must not make a witnessed creation pass for
    ///      constructor arguments it did not send.
    function test_trustTestCreationAt_refusesArgumentsTheCreationDidNotSend() public {
        _world("args");
        Sent[] memory sent = upTo("vault.check");
        address other = makeAddr("other operator");
        string memory dir = string.concat("deployments/", net);
        vm.writeFile(string.concat(dir, "/vault.input.json"), string.concat('{"operator":"', vm.toString(other), '"}'));
        vm.writeJson(
            vm.toString(abi.encode(role("token", ".token"), other)), string.concat(dir, "/vault.json"), ".vaultArgs"
        );
        VaultUnit fresh = new VaultUnit();
        fresh.trustTestCreationAt(sent[0].to, sent[0].data);
        fresh.trustTestCreationAt(sent[1].to, sent[1].data);
        vm.expectRevert(bytes("vault's witnessed creation sent other initcode or arguments than its input"));
        fresh.check(net);
    }
}

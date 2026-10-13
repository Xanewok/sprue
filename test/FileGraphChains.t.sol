// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {defaultChainIn} from "../src/Chains.sol";
import {isRehearsalNetwork} from "../src/Journal.sol";
import {FileGraph} from "../src/FileGraph.sol";
import {Registration, Step, Declares} from "../src/graph/Step.sol";
import {Counting, StepFunctions} from "./StepBuilders.t.sol";

/// @dev A project with no `chains.default`, whatever project the test runs in.
contract NoDefaultGraph is FileGraph {
    constructor(Registration memory unit, Step[] memory steps) {
        _units.push(unit.target);
        _add(unit, steps);
        _validateGraph();
    }

    function _homeChain(string memory file) internal view override returns (string memory) {
        return defaultChainIn("{}", file);
    }
}

contract FileGraphChainsTest is Test, Declares {
    string private constant NET = "fork-test-filegraph-chains";

    function _graph(bool named) private returns (NoDefaultGraph) {
        Step[] memory s = new Step[](1);
        s[0] = _step("fixture.notify.0", "notify", StepFunctions.notify.selector)
            .withArg(0)
            .due(StepFunctions.notifyDue.selector)
            .gateView("windowEnd", StepFunctions.windowEnd.selector);
        if (named) s[0] = s[0].on("a").reads("b");
        return _graph(s[0]);
    }

    function _graph(Step memory step) private returns (NoDefaultGraph) {
        Step[] memory s = new Step[](1);
        s[0] = step;
        return new NoDefaultGraph(Registration(address(new StepFunctions()), "toy.s.sol:Toy"), s);
    }

    function test_noDefaultChain_refusesAStepWithoutOn_andServesOneWithOn() public {
        vm.createDir(string.concat("deployments/", NET), true);
        vm.writeFile(
            string.concat("deployments/", NET, "/network.json"), '{"chains":{"a":{"id":1,"rpc":"alpha"},"b":{"id":2}}}'
        );
        NoDefaultGraph unnamed = _graph(false);
        NoDefaultGraph named = _graph(true);
        vm.expectRevert(bytes("fixture.notify.0 has no chain: add .on(...) to it or set chains.default in sprue.json"));
        unnamed.plan(NET, "fixture.notify.0");
        string memory out = named.plan(NET, "fixture.notify.0");
        vm.removeDir(string.concat("deployments/", NET), true);
        assertTrue(vm.contains(out, "# not before 100 on alpha fixture.notify.0"), out);
        assertTrue(vm.contains(out, "--rpc-url alpha"), out);
    }

    /// @dev Neither refusal is the command's: a step not judged before its date prints only the date,
    ///      and the default chain a step reads is no chain it sends on.
    function test_noDefaultChain_refusesAnUnjudgedStepsDate_andADefaultRead() public {
        string memory net = "fork-test-filegraph-chains-dated";
        vm.createDir(string.concat("deployments/", net), true);
        vm.writeFile(
            string.concat("deployments/", net, "/network.json"),
            '{"openAt":"100","chains":{"a":{"id":1,"rpc":"alpha"},"b":{"id":2}}}'
        );
        NoDefaultGraph dated = _graph(
            _step("fixture.deploy", "deploy", StepFunctions.deploy.selector)
                .due(StepFunctions.deployDue.selector)
                .notBefore("network.openAt")
        );
        NoDefaultGraph reader = _graph(
            _step("fixture.deploy", "deploy", StepFunctions.deploy.selector)
                .due(StepFunctions.deployDue.selector)
                .on("a")
                .reads("")
        );
        vm.expectRevert(bytes("fixture.deploy has no chain: add .on(...) to it or set chains.default in sprue.json"));
        dated.plan(net, "fixture.deploy");
        vm.expectRevert(bytes("a step reads the default chain, and sprue.json sets no chains.default"));
        reader.plan(net, "fixture.deploy");
        vm.removeDir(string.concat("deployments/", net), true);
    }
}

/// @dev A project that sets `chains.default` (`l2`, as this repository's `sprue.json` does) and refuses
///      chain id 666.
contract ProjectGraph is FileGraph {
    constructor(Registration memory unit, Step[] memory steps) {
        _units.push(unit.target);
        _add(unit, steps);
        _validateGraph();
    }

    function _requireChain(string memory, uint256 id) internal pure override {
        require(id != 666, "the project refuses chain 666");
    }
}

contract FileGraphProjectTest is Test, Declares {
    /// @dev A network of the test's own, as tests run in parallel.
    string private net;
    string private constant HEADER =
        "# chain l2 31337 local\n# chain a 11155111 test\n# chain b 1 live\n# chain c 1337 local\n";
    address private owner = makeAddr("owner");

    function _network(string memory name, string memory ownerValue, string memory extraChain) private {
        net = name;
        vm.createDir(string.concat("deployments/", name), true);
        vm.writeFile(
            string.concat("deployments/", name, "/network.json"),
            string.concat(
                '{"openAt":"100","owner":"',
                ownerValue,
                '","chains":{"l2":{"id":31337},"a":{"id":11155111,"rpc":"alpha"},"b":{"id":1},"c":{"id":1337}',
                extraChain,
                "}}"
            )
        );
    }

    function _project(address target, Step memory step) private returns (ProjectGraph) {
        Step[] memory s = new Step[](1);
        s[0] = step;
        return new ProjectGraph(Registration(target, "toy.s.sol:Toy"), s);
    }

    function _fund() private pure returns (Step memory) {
        return _step("fixture.fund", StepFunctions.fund.selector).due(StepFunctions.fundDue.selector);
    }

    function _plan(Step memory step) private returns (string memory) {
        return _project(address(new StepFunctions()), step).plan(net, "fixture.fund");
    }

    function test_plan_listsTheChainsAndTheVariablesACommandReads() public {
        _network("fork-test-fgp-chains", vm.toString(owner), "");

        assertEq(
            _plan(_fund().on("a").reads("ghost").reads("b")),
            string.concat(
                HEADER,
                "B_RPC=$B_RPC GHOST_RPC=$GHOST_RPC forge script toy.s.sol:Toy --sig 'fund(string)' ",
                net,
                " --rpc-url alpha --sender $DEPLOYER\n"
            ),
            "declared chains first, then the others as the step reads them; an alias needs no variable"
        );
        assertEq(
            _plan(_fund().on("c").reads("").reads("b").ownsForks()),
            string.concat(
                HEADER,
                "L2_RPC=$L2_RPC B_RPC=$B_RPC C_RPC=$C_RPC forge script toy.s.sol:Toy --sig 'fund(string)' ",
                net,
                " --sender $DEPLOYER\n"
            ),
            "a step that selects its own forks passes no --rpc-url"
        );
        assertTrue(vm.contains(_plan(_fund().on("b")), "--rpc-url $B_RPC --sender"));
        assertTrue(vm.contains(_plan(_fund().by("network.owner")), string.concat("--sender ", vm.toString(owner))));
        vm.removeDir(string.concat("deployments/", net), true);
    }

    function test_plan_refusesAnInputDateOnAChainOtherThanTheDefault() public {
        _network("fork-test-fgp-clock", vm.toString(owner), "");
        assertEq(
            _plan(_fund().on("l2").notBefore("network.openAt")),
            string.concat(HEADER, "# not before 100 fixture.fund\n# then plan again fixture.fund\n")
        );
        string[2] memory others = ["a", "b"];
        for (uint256 i; i < others.length; ++i) {
            _refuses(
                _fund().on(others[i]).notBefore("network.openAt"),
                string.concat(
                    "fixture.fund has an input date but sends on ",
                    others[i],
                    ": use a gate view, which selects that chain"
                )
            );
        }
        vm.removeDir(string.concat("deployments/", net), true);
    }

    function test_plan_refusesWhatTheNetworkOrTheProjectCannotServe() public {
        _network("fork-test-fgp-refusals", vm.toString(owner), "");
        _refuses(
            _fund().on("ghost"), string.concat("fixture.fund sends on ghost, which ", net, "'s network.json lacks")
        );
        _refuses(
            _fund().reads("ghost").ownsForks(),
            string.concat("fixture.fund reads ghost, which ", net, "'s network.json lacks")
        );

        _network(net, "<owner>", "");
        _refuses(
            _fund().by("network.owner"),
            string.concat("deployments/", net, "/network.json's owner is a placeholder: fill it in and commit it")
        );
        _network(net, vm.toString(address(0)), "");
        _refuses(_fund().by("network.owner"), "network.owner is the zero address: set it in the network's files");

        _network(net, vm.toString(owner), ',"x":{"id":666}');
        _refuses(_fund(), "the project refuses chain 666");
        vm.removeDir(string.concat("deployments/", net), true);
    }

    function _refuses(Step memory step, string memory reason) private {
        ProjectGraph g = _project(address(new StepFunctions()), step);
        vm.expectRevert(bytes(reason));
        g.plan(net, "fixture.fund");
    }

    function test_rehearse_stagesTheNetworkAndSendsOnlyAsTheStepsSender() public {
        _network("filegraph-rehearse", vm.toString(address(this)), "");
        string memory dir = string.concat("deployments/", net);
        string memory staged = "deployments/fork-test-rehearse-filegraph-rehearse";
        vm.writeFile(string.concat(dir, "/foo.input.json"), "{}");
        vm.createDir(string.concat(dir, "/sub"), true);
        vm.writeFile(string.concat(dir, "/sub/inner.json"), "{}");
        vm.createDir(staged, true);
        vm.writeFile(string.concat(staged, "/stale.json"), "{}");

        Counting own = new Counting();
        _project(address(own), _deploy("network.owner")).rehearse(net, "fixture.deploy");
        assertEq(own.deploys(), 1);
        assertTrue(
            vm.exists(string.concat(staged, "/network.json")) && vm.exists(string.concat(staged, "/foo.input.json"))
        );
        assertFalse(vm.exists(string.concat(staged, "/sub")), "a directory is not staged");
        assertFalse(vm.exists(string.concat(staged, "/stale.json")), "the stage starts empty");

        _network("filegraph-rehearse", vm.toString(owner), "");
        Counting foreign = new Counting();
        _project(address(foreign), _deploy("network.owner")).rehearse(net, "fixture.deploy");
        assertEq(foreign.deploys(), 0, "a step is not sent as another account");

        ProjectGraph g = _project(address(own), _deploy("network.owner"));
        string[3] memory refused = ["", "../x", "a/b"];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert("the network is a directory under paths.deployments");
            g.rehearse(refused[i], "fixture.deploy");
        }
        vm.removeDir(dir, true);
        vm.removeDir(staged, true);
    }

    function test_isRehearsalNetwork_isThePrefixAloneOrWithADashedSuffix() public view {
        assertTrue(isRehearsalNetwork("fork-test") && isRehearsalNetwork("fork-test-x"));
        assertFalse(
            isRehearsalNetwork("fork-testing") || isRehearsalNetwork("fork-tes") || isRehearsalNetwork("fork-tesx")
        );
        assertFalse(isRehearsalNetwork("mainnet"));
    }

    function _deploy(string memory by) private pure returns (Step memory) {
        return _step("fixture.deploy", Counting.deploy.selector).due(Counting.deployDue.selector).by(by);
    }

    function test_plan_aSlowStepEndsItsCommandWithTheFlag() public {
        _network("fork-test-fgp-slow", vm.toString(owner), "");
        assertTrue(vm.contains(_plan(_fund().slow()), string.concat(" --sender $DEPLOYER --slow\n")));
        vm.removeDir(string.concat("deployments/", net), true);
    }
}

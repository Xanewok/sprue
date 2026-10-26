// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {Declares, Registration, Step} from "../src/graph/Step.sol";
import {Probes} from "../src/Probes.sol";
import {BuilderGraph} from "./StepBuilders.t.sol";
import {ToyUnit} from "./ToyUnit.sol";

/// @dev Steps without a `Due` view, one per outcome of a probe.
contract ProbeUnit is ToyUnit {
    bool public sends;
    uint256 public runs;

    function setSends(bool sends_) external {
        sends = sends_;
    }

    function transfer(string calldata network) external returns (string memory) {
        _use(network);
        ++runs;
        if (sends) {
            _startBroadcast();
            vm.stopBroadcast();
        }
        return _done(sends);
    }

    function refuse(string calldata) external pure returns (string memory) {
        revert("not yet");
    }

    function raw(string calldata) external returns (string memory) {
        vm.startBroadcast();
        vm.stopBroadcast();
        return "";
    }

    address public owner;

    function setOwner(address owner_) external {
        owner = owner_;
    }

    /// @dev Its work depends on who sends it.
    function claim(string calldata network) external returns (string memory) {
        _use(network);
        if (msg.sender != owner) {
            _startBroadcast();
            vm.stopBroadcast();
        }
        return _done(msg.sender != owner);
    }

    function build(string calldata network) external returns (string memory) {
        _use(network);
        _recordBuild("toy", address(1), "ToyPayload");
        return _done(false);
    }

    function mark(string calldata network) external returns (string memory) {
        string memory journal = _use(network);
        if (!_has(journal, ".marked")) _put(".marked", "true");
        return _done(false);
    }
}

/// @dev Not a sprue unit: asking whether it answers a probe must not run its fallback.
contract FallbackUnit {
    uint256 public calls;

    fallback() external {
        ++calls;
    }

    function fund(string calldata) external {}

    function fundDue(string calldata) external view returns (bool) {
        return calls == 0;
    }
}

contract ProbeTest is Test, Declares {
    string private constant DIR = "cache/core-test/deployments/";
    string private constant SCRIPT = "test/Probe.t.sol:ProbeUnit";

    ProbeUnit private unit;

    function setUp() public {
        unit = new ProbeUnit();
    }

    function _network(string memory name) private returns (string memory) {
        string memory dir = string.concat(DIR, name);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(dir, true);
        vm.chainId(31337);
        vm.writeFile(string.concat(dir, "/network.json"), '{"chains": {"main": {"id": 31337}}}');
        return name;
    }

    function _graph(Step[] memory s) private returns (BuilderGraph) {
        return new BuilderGraph(Registration(address(unit), SCRIPT), s);
    }

    function _one(string memory id) private pure returns (Step[] memory s) {
        s = new Step[](1);
        s[0] = _bare(id);
    }

    function _bare(string memory id) private pure returns (Step memory) {
        bytes memory name = bytes(id);
        uint256 start;
        for (uint256 i; i < name.length; ++i) {
            if (name[i] == ".") start = i + 1;
        }
        string memory fn = vm.replace(id, string(_slice(name, 0, start)), "");
        return _step(id, bytes4(keccak256(bytes(string.concat(fn, "(string)")))));
    }

    function _slice(bytes memory b, uint256 from, uint256 to) private pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[from + i];
        }
    }

    function _command(string memory net, string memory fn) private pure returns (string memory) {
        return string.concat(
            "forge script ", SCRIPT, " --sig '", fn, "(string)' ", net, " --rpc-url node --sender $DEPLOYER\n"
        );
    }

    function test_plan_judgesAStepWithoutADueViewByRunningIt_andKeepsNothingItDid() public {
        string memory net = _network("probe-transfer");
        BuilderGraph g = _graph(_one("toy.transfer"));
        assertTrue(g.node(0).probed);

        assertEq(g.plan(net, "toy.transfer"), "# done toy.transfer\n");
        unit.setSends(true);
        assertEq(g.plan(net, "toy.transfer"), _command(net, "transfer"));
        assertEq(unit.runs(), 0, "the probe's state remained");
    }

    /// @dev The plan's own sender stands for a step with no `.by`, as `$DEPLOYER` does in its command.
    function test_plan_probesAsTheStepsSender() public {
        string memory net = _network("probe-sender");
        BuilderGraph g = _graph(_one("toy.claim"));
        unit.setOwner(address(this));
        assertEq(g.plan(net, "toy.claim"), "# done toy.claim\n");
        unit.setOwner(address(1));
        assertEq(g.plan(net, "toy.claim"), _command(net, "claim"));
    }

    function test_plan_countsABuildRecordAsWork_andWritesNoMetadata() public {
        string memory net = _network("probe-build");
        assertEq(_graph(_one("toy.build")).plan(net, "toy.build"), _command(net, "build"));
        assertFalse(vm.exists(string.concat(DIR, net, "/ToyPayload.metadata.json")), "the probe wrote metadata");
    }

    function test_add_asksAUnitWhetherItProbesWithoutRunningIt() public {
        FallbackUnit legacy = new FallbackUnit();
        Step[] memory s = new Step[](1);
        s[0] = _step("legacy.fund", FallbackUnit.fund.selector).due(FallbackUnit.fundDue.selector);
        BuilderGraph g = new BuilderGraph(Registration(address(legacy), SCRIPT), s);
        assertFalse(g.node(0).probed);
        assertEq(legacy.calls(), 0, "asking ran the unit's fallback");
    }

    /// @dev What the plan prints, for a test: due, done, or the step's own refusal.
    function test_probesDue_judgesAsThePlan_andRevertsWithTheStepsRefusal() public {
        string memory net = _network("probe-library");
        bytes memory transfer = abi.encodeCall(ProbeUnit.transfer, (net));
        assertFalse(Probes.due(address(unit), transfer, address(this)));
        unit.setSends(true);
        assertTrue(Probes.due(address(unit), transfer, address(this)));
        assertEq(unit.runs(), 0, "the probe's state remained");

        unit.setOwner(address(this));
        assertFalse(Probes.due(address(unit), abi.encodeCall(ProbeUnit.claim, (net)), address(this)));
        assertTrue(Probes.due(address(unit), abi.encodeCall(ProbeUnit.claim, (net)), address(1)));

        vm.expectRevert(bytes("not yet"));
        Probes.due(address(unit), abi.encodeCall(ProbeUnit.refuse, (net)), address(this));
    }

    function test_plan_waitsOnTheStepsOwnRefusal() public {
        string memory net = _network("probe-refuse");
        assertEq(
            _graph(_one("toy.refuse")).plan(net, "toy.refuse"),
            string.concat("# cannot reach toy.refuse: not yet\n", _command(net, "refuse"))
        );
    }

    /// @dev Even on a network whose simulations journal, the probe writes nothing.
    function test_plan_countsAJournalWriteAsWork_andWritesNothing() public {
        string memory net = _network("probe-mark");
        BuilderGraph g = _graph(_one("toy.mark"));
        assertEq(g.plan(net, "toy.mark"), _command(net, "mark"));
        assertFalse(vm.exists(string.concat(DIR, net, "/toy.json")), "the probe wrote the journal");

        unit.mark(net);
        assertEq(g.plan(net, "toy.mark"), "# done toy.mark\n");
    }

    function test_plan_judgesDeployRoleByItsReuse() public {
        string memory net = _network("probe-deploy");
        BuilderGraph g = _graph(_one("toy.deploy"));
        assertEq(g.plan(net, "toy.deploy"), _command(net, "deploy"));
        assertFalse(vm.exists(string.concat(DIR, net, "/toy.json")), "the probe journaled an intent");

        unit.deploy(net);
        assertEq(g.plan(net, "toy.deploy"), "# done toy.deploy\n");
        unit.setRefuseReuse(true);
        assertEq(
            g.plan(net, "toy.deploy"),
            string.concat("# cannot reach toy.deploy: the check refused the reuse\n", _command(net, "deploy"))
        );
    }

    function test_plan_leavesAProbedStepUnjudgedUntilItsNeedsAreDone() public {
        string memory net = _network("probe-needs");
        Step[] memory s = new Step[](2);
        s[0] = _bare("toy.mark");
        s[1] = _bare("toy.transfer").needs("toy.mark");
        assertEq(
            _graph(s).plan(net, "toy.transfer"),
            string.concat(_command(net, "mark"), "# then plan again toy.transfer\n")
        );
    }

    /// @dev Forge refuses its broadcast cheatcodes under the probe's prank, so the step queues nothing.
    function test_plan_refusesToJudgeADirectBroadcast() public {
        string memory net = _network("probe-raw");
        assertEq(
            _graph(_one("toy.raw")).plan(net, "toy.raw"),
            string.concat(
                "# cannot reach toy.raw: it calls vm.startBroadcast or vm.broadcast, which a probe cannot judge: "
                "call _startBroadcast() or give it a Due view\n",
                _command(net, "raw")
            )
        );
    }

    /// @dev A `check` holds no record of having passed: what it asserts is read at each plan.
    function test_plan_judgesACheckLive_andRefusesOnceWhatItAssertsChanged() public {
        string memory net = _network("probe-live-check");
        Step[] memory s = new Step[](2);
        s[0] = _bare("toy.deploy");
        s[1] = _bare("toy.check").needs("toy.deploy");
        BuilderGraph g = _graph(s);
        unit.deploy(net);
        unit.check(net);
        assertEq(g.plan(net, "toy.check"), "# done toy.deploy\n# done toy.check\n");

        unit.setTag(2);
        string memory plan = g.plan(net, "toy.check");
        assertTrue(vm.contains(plan, "# cannot reach toy."), plan);
        assertFalse(vm.contains(plan, "# done toy.check"), plan);
    }
}

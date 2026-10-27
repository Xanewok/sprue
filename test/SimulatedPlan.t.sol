// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";

import {FileGraph} from "../src/FileGraph.sol";
import {Registration, Step, Declares} from "../src/graph/Step.sol";

contract Made {}

/// @dev Journals under the `network` it is called with, as a `Unit` does: `make` creates a contract and
///      records its address; `use` needs that address to hold code; `last` follows `use`.
contract SimUnit is Script, Declares {
    address public lastMade;
    bool public breakLast;

    function setBreakLast() external {
        breakLast = true;
    }

    function make(string calldata net) external {
        lastMade = address(new Made());
        vm.writeFile(_path(net), string.concat('{"made":"', vm.toString(lastMade), '"}'));
    }

    function use(string calldata net) external {
        require(_made(net).code.length != 0, "no code at made");
        vm.writeJson('"yes"', _path(net), ".used");
    }

    function last(string calldata net) external {
        require(!breakLast, "last refuses");
        vm.writeJson('"yes"', _path(net), ".last");
    }

    function makeDue(string calldata net) external view returns (bool) {
        return !vm.exists(_path(net));
    }

    function useDue(string calldata net) external view returns (bool) {
        return !vm.keyExistsJson(vm.readFile(_path(net)), ".used");
    }

    function lastDue(string calldata net) external view returns (bool) {
        return !vm.keyExistsJson(vm.readFile(_path(net)), ".last");
    }

    function openAt(string calldata) external pure returns (uint256) {
        return 5000;
    }

    function _made(string calldata net) private view returns (address) {
        return vm.parseJsonAddress(vm.readFile(_path(net)), ".made");
    }

    function _path(string memory net) private pure returns (string memory) {
        return string.concat("deployments/", net, "/sim.json");
    }

    function steps() external view returns (Step[] memory s) {
        s = new Step[](3);
        s[0] = _step("sim.make", this.make.selector).due(this.makeDue.selector);
        s[1] = _step("sim.use", this.use.selector).due(this.useDue.selector).needs("sim.make");
        s[2] = _step("sim.last", this.last.selector).due(this.lastDue.selector).needs("sim.use");
    }
}

contract SimGraph is FileGraph {
    constructor(address unit, Step[] memory steps) {
        _units.push(unit);
        _add(Registration(unit, "sim.s.sol:SimUnit"), steps);
        _validateGraph();
    }
}

contract SimulatedPlanTest is Test, Declares {
    /// @dev Each test has a network of its own, as tests run in parallel.
    string private net;
    string private real;
    string private staged;
    string private constant CHAINS = '"chains":{"l2":{"id":31337,"rpc":"local"},"far":{"id":10,"rpc":"far"}}';
    string private constant HEADER = "# chain l2 31337 local\n# chain far 10 live\n";

    SimUnit private unit;

    function _begin(string memory name) private {
        unit = new SimUnit();
        net = name;
        real = string.concat("deployments/", name);
        staged = string.concat("deployments/rehearsal-plan-", name);
        _end();
        vm.createDir(real, true);
        vm.writeFile(
            string.concat(real, "/network.json"),
            string.concat('{"owner":"0x00000000000000000000000000000000000000aa",', CHAINS, "}")
        );
    }

    function _end() private {
        if (vm.exists(staged)) vm.removeDir(staged, true);
        if (vm.exists(real)) vm.removeDir(real, true);
    }

    function _make() private view returns (string memory) {
        return _command("make", true);
    }

    function _graph() private returns (SimGraph) {
        return new SimGraph(address(unit), unit.steps());
    }

    function _command(string memory fn, bool newline) private view returns (string memory) {
        return string.concat(
            "forge script sim.s.sol:SimUnit --sig '",
            fn,
            "(string)' ",
            net,
            " --rpc-url local --sender $DEPLOYER",
            newline ? "\n" : ""
        );
    }

    function test_plainPlan_stopsAtTheFirstSend_andIsUnchangedBySimulating() public {
        _begin("sp-1");
        SimGraph g = _graph();
        string memory expected = string.concat(HEADER, _make(), "# then plan again sim.use\n");
        assertEq(g.plan(net, "sim.last"), expected);

        g.planSimulated(net, "sim.last", false);
        assertEq(g.plan(net, "sim.last"), expected, "the plain plan changed after a simulated one");
        _end();
    }

    function test_simulated_continuesPastTheSend_andMarksTheCreatedAddress() public {
        _begin("sp-2");
        SimGraph g = _graph();
        string memory out = g.planSimulated(net, "sim.last", false);
        address made = unit.lastMade();
        assertTrue(made != address(0) && made.code.length != 0, "the send did not run in simulation");

        string memory expected = string.concat(
            HEADER,
            _make(),
            "# then plan again sim.use\n"
            "# simulated below: the commands above are assumed to land; nothing below is read from the chain. Steps without .by are simulated as ",
            vm.toString(address(this)),
            "\n# simulated value sim.made = ",
            vm.toString(made),
            ", written by simulated send sim.make\n"
            "# simulated due sim.use, after simulated send sim.make\n# simulated command ",
            _command("use", false),
            "\n# simulated due sim.last, after simulated send sim.make\n# simulated command ",
            _command("last", false),
            "\n"
        );
        assertEq(out, expected);
        _end();
    }

    function test_simulated_writesNothingOutsideItsCopy() public {
        _begin("sp-3");
        SimGraph g = _graph();
        bytes32 network = keccak256(bytes(vm.readFile(string.concat(real, "/network.json"))));
        g.planSimulated(net, "sim.last", false);
        assertFalse(vm.exists(string.concat(real, "/sim.json")), "a journal appeared in the network");
        assertEq(vm.readDir(real).length, 1, "the network's directory gained a file");
        assertEq(keccak256(bytes(vm.readFile(string.concat(real, "/network.json")))), network);
        assertTrue(vm.exists(string.concat(staged, "/sim.json")), "the copy holds the simulated journal");
        assertTrue(vm.keyExistsJson(vm.readFile(string.concat(staged, "/sim.json")), ".last"));

        // The next plan is as the first was: nothing simulated counts as done.
        assertEq(g.plan(net, "sim.last"), string.concat(HEADER, _make(), "# then plan again sim.use\n"));
        _end();
    }

    function test_simulated_isRefusedAsForgesDefaultSender() public {
        _begin("sp-4");
        SimGraph g = _graph();
        vm.prank(DEFAULT_SENDER);
        vm.expectRevert("pass --sender <deployer> to the plan");
        g.planSimulated(net, "sim.last", false);
        _end();
    }

    function test_simulated_addsNothingToAPlanThatEndsWithoutAnUnjudgedNode() public {
        _begin("sp-5");
        Step[] memory s = new Step[](1);
        s[0] = _step("sim.make", unit.make.selector).due(unit.makeDue.selector);
        SimGraph g = new SimGraph(address(unit), s);
        assertEq(g.planSimulated(net, "sim.make", false), string.concat(HEADER, _make()));
        _end();
    }

    function test_simulated_aStepOfAnotherAccount_orChain_isUnknownNotSimulated() public {
        _begin("sp-6");
        Step[] memory s = new Step[](3);
        s[0] = _step("sim.make", unit.make.selector).due(unit.makeDue.selector);
        s[1] = _step("sim.use", unit.use.selector).due(unit.useDue.selector).needs("sim.make").by("network.owner");
        s[2] = _step("sim.last", unit.last.selector).due(unit.lastDue.selector).needs("sim.use");
        string memory out = new SimGraph(address(unit), s).planSimulated(net, "sim.last", false);
        assertTrue(
            vm.contains(
                out,
                "# simulated unknown sim.use: it is sent by 0x00000000000000000000000000000000000000AA, not by "
            ),
            out
        );
        assertTrue(vm.contains(out, "# simulated unknown sim.last: not judged, the walk ended at sim.use"), out);
        assertFalse(vm.contains(out, "# simulated due"), out);

        s[1] = _step("sim.use", unit.use.selector).due(unit.useDue.selector).needs("sim.make").on("far");
        out = new SimGraph(address(unit), s).planSimulated(net, "sim.last", false);
        assertTrue(
            vm.contains(out, "# simulated unknown sim.use: it sends on far, and a simulated plan runs on the default chain only"),
            out
        );
        _end();
    }

    function test_simulated_aRevertingSend_endsTheWalkInsteadOfThePlan() public {
        _begin("sp-7");
        unit.setBreakLast();
        string memory out = _graph().planSimulated(net, "sim.last", false);
        assertTrue(vm.contains(out, "# simulated due sim.last, after simulated send sim.make"), out);
        assertTrue(
            vm.contains(out, "# simulated cannot reach sim.last: its simulated send reverted: last refuses"), out
        );
        // The prefix is the plan's.
        assertTrue(vm.contains(out, string.concat(_make(), "# then plan again sim.use\n")), out);
        _end();
    }

    function test_simulated_warpsToADateAndPrintsIt() public {
        _begin("sp-8");
        Step[] memory s = new Step[](2);
        s[0] = _step("sim.make", unit.make.selector).due(unit.makeDue.selector);
        s[1] = _step("sim.use", unit.use.selector).due(unit.useDue.selector).needs("sim.make").gateView(
            "openAt", unit.openAt.selector
        );
        vm.warp(100);
        string memory out = new SimGraph(address(unit), s).planSimulated(net, "sim.use", false);
        assertTrue(vm.contains(out, "# simulated not before 5000 sim.use, warped to it\n# simulated due sim.use"), out);
        assertEq(block.timestamp, 5000);
        _end();
    }
}

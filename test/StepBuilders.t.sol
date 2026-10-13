// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {Graph} from "../src/graph/Graph.sol";
import {Registration, Step, StepKind, Declares} from "../src/graph/Step.sol";

contract StepFunctions {
    function deploy(string calldata) external {}
    function configure(string calldata) external {}
    function check(string calldata) external {}
    function fund(string calldata) external {}

    function fundDue(string calldata) external pure returns (bool) {
        return true;
    }

    function deployDue(string calldata) external pure returns (bool) {
        return true;
    }

    function configureDue(string calldata) external pure returns (bool) {
        return false;
    }

    function observed(string calldata) external pure returns (bool) {
        return false;
    }

    function guarded(string calldata) external {}

    function guardedDue(string calldata) external pure returns (bool) {
        revert("not yet");
    }

    error Closed();

    function locked(string calldata) external {}

    function lockedDue(string calldata) external pure returns (bool) {
        revert Closed();
    }

    function notify(string calldata, uint8) external {}

    function notifyDue(string calldata, uint8) external pure returns (bool) {
        return true;
    }

    function windowEnd(string calldata, uint8) external pure returns (uint256) {
        return 100;
    }
}

contract Counting {
    uint256 public deploys;
    uint256 public checks;
    bool public open;

    function deploy(string calldata) external {
        ++deploys;
    }

    function check(string calldata) external {
        ++checks;
    }

    function deployDue(string calldata) external view returns (bool) {
        return deploys == 0;
    }

    function observed(string calldata) external view returns (bool) {
        return open;
    }

    function openUp() external {
        open = true;
    }
}

contract ClosedWindow {
    error WindowUnknown();

    function notify(string calldata, uint8) external {}

    function notifyDue(string calldata, uint8) external pure returns (bool) {
        return true;
    }

    function windowEnd(string calldata, uint8) external pure returns (uint256) {
        revert WindowUnknown();
    }
}

/// @dev Two chains' clocks on one EVM: selecting a chain parks the selected one's clock and loads
///      the other's, as `vm.selectFork` does.
contract TwoClocks is Test {
    uint256 public constant END = 1000;
    uint256[2] private _clock = [500, 500];
    uint256 private _selected;
    bool public notified;

    function windowEnd(string calldata, uint8) external returns (uint256) {
        _select(0);
        return END;
    }

    function notifyDue(string calldata, uint8) external returns (bool) {
        _select(1);
        return !notified;
    }

    function notify(string calldata, uint8) external {
        _select(0);
        require(block.timestamp >= END, "window open");
        notified = true;
    }

    function _select(uint256 chain) private {
        _clock[_selected] = block.timestamp;
        _selected = chain;
        vm.warp(_clock[chain]);
    }
}

contract BuilderGraph is Graph {
    constructor(Registration memory unit, Step[] memory steps) {
        _units.push(unit.target);
        _add(unit, steps);
        _validateGraph();
    }

    function listUnit(address unit) external {
        _units.push(unit);
    }

    function add(Registration memory unit, Step[] memory steps) external {
        _add(unit, steps);
    }

    function validate() external {
        _validateGraph();
    }

    function _journalChecked(string memory, string memory) internal pure override returns (bool) {
        return false;
    }

    function _input(string memory, string memory) internal pure override returns (string memory) {
        return "100";
    }

    function _isTestChain() internal pure override returns (bool) {
        return true;
    }

    function _stage(string calldata net) internal pure override returns (string memory) {
        return net;
    }

    function _prepareSender(string memory, uint256) internal pure override returns (bool) {
        return true;
    }

    function _unmetPredicate(uint256) internal pure override returns (bool) {
        return false;
    }
}

contract StepBuildersTest is Test, Declares {
    Registration private unit;

    function setUp() public {
        unit = Registration(address(new StepFunctions()), "test/Fixture.s.sol:Fixture");
    }

    function _node(string memory id) private pure returns (Step memory) {
        return _step(id, "fund", StepFunctions.fund.selector).due(StepFunctions.fundDue.selector);
    }

    function test_aStepNeedsAnIdAndAKind() public {
        Step[] memory s = new Step[](1);
        s[0] = _node("");
        vm.expectRevert(abi.encodeWithSelector(Graph.EmptyStep.selector, 0));
        new BuilderGraph(unit, s);

        s[0] = _node("x");
        s[0].kind = StepKind.Empty;
        vm.expectRevert(abi.encodeWithSelector(Graph.EmptyStep.selector, 0));
        new BuilderGraph(unit, s);
    }

    function test_uniqueIds() public {
        Step[] memory s = new Step[](2);
        s[0] = _node("same");
        s[1] = _node("same");
        vm.expectRevert(abi.encodeWithSelector(Graph.DuplicateId.selector, "same"));
        new BuilderGraph(unit, s);
    }

    function test_everyNeedResolves() public {
        Step[] memory s = new Step[](1);
        s[0] = _node("target").needs("missing");
        vm.expectRevert(abi.encodeWithSelector(Graph.MissingDependency.selector, "target", "missing"));
        new BuilderGraph(unit, s);
    }

    function test_aDependencyDeclaredLaterIsOrderedFirst_andTheRestKeepDeclarationOrder() public {
        Step[] memory s = new Step[](3);
        s[0] = _node("a").needs("b");
        s[1] = _node("b");
        s[2] = _node("c");
        BuilderGraph g = new BuilderGraph(unit, s);
        assertEq(g.node(0).id, "b");
        assertEq(g.node(1).id, "a");
        assertEq(g.node(2).id, "c");
    }

    function test_cycleIsRefusedWithItsIds() public {
        Step[] memory s = new Step[](4);
        s[0] = _node("tail").needs("a");
        s[1] = _node("a").needs("b");
        s[2] = _node("b").needs("c");
        s[3] = _node("c").needs("a");
        vm.expectRevert(abi.encodeWithSelector(Graph.Cycle.selector, "a -> c -> b -> a"));
        new BuilderGraph(unit, s);
    }

    function test_unlistedUnitIsRefused() public {
        BuilderGraph g = new BuilderGraph(unit, new Step[](0));
        Step[] memory s = new Step[](1);
        s[0] = _step("fixture.deploy", StepFunctions.deploy.selector);
        g.add(Registration(address(new StepFunctions()), ""), s);
        vm.expectRevert(abi.encodeWithSelector(Graph.UnlistedUnit.selector, "fixture.deploy"));
        g.validate();
    }

    function test_productionNeverNeedsATestNode() public {
        Step[] memory s = new Step[](2);
        s[0] = _node("test").forTests();
        s[1] = _node("production").needs("test");
        vm.expectRevert(abi.encodeWithSelector(Graph.ProductionDependency.selector, "production", "test"));
        new BuilderGraph(unit, s);
    }

    function test_stepSelectorMatchesTheName() public {
        Step[] memory s = new Step[](1);
        s[0] = _step("fixture.deploy", StepFunctions.check.selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                Graph.SelectorMismatch.selector,
                "fixture.deploy",
                StepFunctions.deploy.selector,
                StepFunctions.check.selector
            )
        );
        new BuilderGraph(unit, s);
    }

    function test_dueSelectorMatchesTheStepName() public {
        Step[] memory s = new Step[](1);
        s[0] = _step("fixture.fund", StepFunctions.fund.selector).due(StepFunctions.deployDue.selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                Graph.SelectorMismatch.selector,
                "fixture.fund",
                StepFunctions.fundDue.selector,
                StepFunctions.deployDue.selector
            )
        );
        new BuilderGraph(unit, s);
    }

    function test_checkCertifiesItselfAndItsTransitiveAncestorsOnly() public {
        Step[] memory s = new Step[](5);
        s[0] = _step("fixture.deploy", StepFunctions.deploy.selector);
        s[1] = _step("fixture.fund", StepFunctions.fund.selector)
            .needs("fixture.deploy")
            .due(StepFunctions.fundDue.selector);
        s[2] = _step("fixture.configure", StepFunctions.configure.selector).needs("fixture.fund");
        s[3] = _step("fixture.check", StepFunctions.check.selector).needs("fixture.configure");
        s[4] = _step("fixture.guarded", StepFunctions.guarded.selector)
            .needs("fixture.check")
            .due(StepFunctions.guardedDue.selector);
        BuilderGraph g = new BuilderGraph(unit, s);
        assertTrue(g.node(0).certified);
        assertFalse(g.node(1).certified, "a step with a due view keeps it as its rule");
        assertTrue(g.node(2).certified);
        assertTrue(g.node(3).certified);
        assertFalse(g.node(4).certified);
        assertTrue(g.node(4).due);
    }

    function test_unrelatedCheckDoesNotCertifyAStep() public {
        Step[] memory s = new Step[](2);
        s[0] = _step("fixture.deploy", StepFunctions.deploy.selector);
        s[1] = _step("fixture.check", StepFunctions.check.selector);
        vm.expectRevert(abi.encodeWithSelector(Graph.MissingDoneRule.selector, "fixture.deploy"));
        new BuilderGraph(unit, s);
    }

    function test_anotherUnitsCheckDoesNotCertifyAStep() public {
        BuilderGraph g = new BuilderGraph(unit, new Step[](0));
        Step[] memory s = new Step[](1);
        s[0] = _step("fixture.deploy", StepFunctions.deploy.selector);
        g.add(unit, s);
        s[0] = _step("fixture.check", StepFunctions.check.selector).needs("fixture.deploy");
        Registration memory other = Registration(address(new StepFunctions()), unit.script);
        g.listUnit(other.target);
        g.add(other, s);
        vm.expectRevert(abi.encodeWithSelector(Graph.MissingDoneRule.selector, "fixture.deploy"));
        g.validate();
    }

    function test_dueCheckCannotCertifyAncestors() public {
        Step[] memory s = new Step[](2);
        s[0] = _step("fixture.deploy", StepFunctions.deploy.selector);
        s[1] = _step("fixture.check", StepFunctions.check.selector)
            .needs("fixture.deploy")
            .due(bytes4(keccak256("checkDue(string)")));
        vm.expectRevert(abi.encodeWithSelector(Graph.MissingDoneRule.selector, "fixture.deploy"));
        new BuilderGraph(unit, s);
    }

    function test_aSecondCheckOfAJournalNeedsADueView() public {
        Step[] memory s = new Step[](4);
        s[0] = _step("fixture.deploy", StepFunctions.deploy.selector);
        s[1] = _step("fixture.check", StepFunctions.check.selector).needs("fixture.deploy");
        s[2] = _step("fixture.configure", StepFunctions.configure.selector).needs("fixture.check");
        s[3] = _step("fixture.recheck", "check", StepFunctions.check.selector).needs("fixture.configure");
        vm.expectRevert(abi.encodeWithSelector(Graph.MissingDoneRule.selector, "fixture.recheck"));
        new BuilderGraph(unit, s);
    }

    function test_gateViewSelectorMatchesItsArgumentSignature() public {
        Step[] memory s = new Step[](1);
        s[0] = _step("toy.notify.0", "notify", StepFunctions.notify.selector)
            .withArg(0)
            .due(StepFunctions.notifyDue.selector)
            .gateView("windowEnd", StepFunctions.fundDue.selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                Graph.SelectorMismatch.selector,
                "toy.notify.0",
                StepFunctions.windowEnd.selector,
                StepFunctions.fundDue.selector
            )
        );
        new BuilderGraph(unit, s);
    }

    function test_aFailingGateViewKeepsItsRevertData() public {
        Step[] memory s = new Step[](1);
        s[0] = _step("toy.notify.0", "notify", ClosedWindow.notify.selector)
            .withArg(0)
            .due(ClosedWindow.notifyDue.selector)
            .gateView("windowEnd", ClosedWindow.windowEnd.selector);
        BuilderGraph g = new BuilderGraph(Registration(address(new ClosedWindow()), unit.script), s);
        vm.expectRevert(ClosedWindow.WindowUnknown.selector);
        g.plan("anvil", "toy.notify.0");
    }

    function test_buildersPreserveOptionsAndDeclarationOrder() public {
        Step[] memory s = new Step[](3);
        s[0] = _node("date").notBefore("fixture.time");
        s[1] = _until("predicate", "observed", StepFunctions.observed.selector).needs("date");
        s[2] = _step("alias", "notify", StepFunctions.notify.selector)
            .needs("date")
            .needs("predicate")
            .by("fixture.owner")
            .slow()
            .forTests()
            .withArg(255)
            .due(StepFunctions.notifyDue.selector)
            .gateView("windowEnd", StepFunctions.windowEnd.selector)
            .on("far")
            .reads("near")
            .reads("other")
            .ownsForks();
        BuilderGraph g = new BuilderGraph(unit, s);
        assertEq(g.nodeCount(), 3);
        assertEq(g.node(0).gate, "fixture.time");
        assertEq(g.node(1).until, "observed");
        Graph.Node memory n = g.node(2);
        assertEq(n.id, "alias");
        assertEq(n.unit, unit.target);
        assertEq(n.script, unit.script);
        assertEq(n.step, "notify");
        assertEq(n.deps.length, 2);
        assertEq(n.deps[0], "date");
        assertEq(n.deps[1], "predicate");
        assertEq(n.sender, "fixture.owner");
        assertEq(n.gate, "windowEnd");
        assertEq(n.on, "far");
        assertEq(n.reads.length, 2);
        assertEq(n.reads[0], "near");
        assertEq(n.reads[1], "other");
        assertTrue(n.slow);
        assertTrue(n.testOnly);
        assertEq(n.arg, "255");
        assertTrue(n.due);
        assertFalse(n.certified);
        assertTrue(n.ownForks);
    }

    function test_anotherJournalCannotCertifyTheSameUnitsStep() public {
        Step[] memory s = new Step[](2);
        s[0] = _step("fixture.deploy", StepFunctions.deploy.selector);
        s[1] = _step("other.check", StepFunctions.check.selector).needs("fixture.deploy");
        vm.expectRevert(abi.encodeWithSelector(Graph.MissingDoneRule.selector, "fixture.deploy"));
        new BuilderGraph(unit, s);
    }

    function test_plan_namesAWaitingPredicateAndARefusingStep() public {
        Step[] memory s = new Step[](2);
        s[0] = _until("fixture.observed", "observed", StepFunctions.observed.selector);
        s[1] = _node("fixture.fund").needs("fixture.observed");
        assertEq(
            new BuilderGraph(unit, s).plan("anvil", "fixture.fund"),
            "# cannot reach fixture.observed: its condition is not met\n# then plan again fixture.fund\n"
        );

        s = new Step[](1);
        s[0] = _step("fixture.guarded", StepFunctions.guarded.selector).due(StepFunctions.guardedDue.selector);
        assertEq(
            new BuilderGraph(unit, s).plan("anvil", "fixture.guarded"),
            "# cannot reach fixture.guarded: not yet\n"
            "forge script test/Fixture.s.sol:Fixture --sig 'guarded(string)' anvil --rpc-url $R --sender $DEPLOYER\n"
        );

        s[0] = _step("fixture.locked", StepFunctions.locked.selector).due(StepFunctions.lockedDue.selector);
        assertEq(
            new BuilderGraph(unit, s).plan("anvil", "fixture.locked"),
            string.concat(
                "# cannot reach fixture.locked: ",
                vm.toString(abi.encodeWithSelector(StepFunctions.Closed.selector)),
                "\nforge script test/Fixture.s.sol:Fixture --sig 'locked(string)' anvil --rpc-url $R --sender $DEPLOYER\n"
            )
        );
    }

    function test_rehearse_sendsAStepOnceAcrossADateWarp() public {
        Counting counting = new Counting();
        Step[] memory s = new Step[](2);
        s[0] = _step("fixture.deploy", Counting.deploy.selector);
        s[1] = _step("fixture.check", Counting.check.selector).needs("fixture.deploy").notBefore("fixture.time");
        new BuilderGraph(Registration(address(counting), unit.script), s).rehearse("anvil", "fixture.check");
        assertEq(counting.deploys(), 1);
        assertEq(counting.checks(), 1);
    }

    function test_rehearse_waitsOnAPredicateNothingSatisfies() public {
        Counting counting = new Counting();
        Step[] memory s = new Step[](3);
        s[0] = _until("fixture.open", "observed", Counting.observed.selector);
        s[1] = _step("fixture.deploy", Counting.deploy.selector).needs("fixture.open");
        s[2] = _step("fixture.check", Counting.check.selector).needs("fixture.deploy");
        BuilderGraph g = new BuilderGraph(Registration(address(counting), unit.script), s);

        g.rehearse("anvil", "fixture.check");
        assertEq(counting.deploys(), 0);

        counting.openUp();
        g.rehearse("anvil", "fixture.check");
        assertEq(counting.deploys(), 1);
        assertEq(counting.checks(), 1);
    }

    /// @notice The date view leaves one chain selected and the step's due check another: the clock
    ///         warped is the date's, so the step sees its window ended.
    function test_aReachedDateWarpsTheClockItWasReadFrom() public {
        TwoClocks clocks = new TwoClocks();
        Step[] memory s = new Step[](1);
        s[0] = _step("fixture.notify.0", "notify", TwoClocks.notify.selector)
            .withArg(0)
            .due(TwoClocks.notifyDue.selector)
            .gateView("windowEnd", TwoClocks.windowEnd.selector);
        BuilderGraph g = new BuilderGraph(Registration(address(clocks), "test/Fixture.s.sol:Fixture"), s);

        g.rehearse("anvil", "fixture.notify.0");
        assertTrue(clocks.notified());
    }
}

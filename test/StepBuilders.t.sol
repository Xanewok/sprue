// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

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

    function unread(string calldata) external {}

    function unreadDue(string calldata) external view returns (bool) {
        Vm(address(uint160(uint256(keccak256("hevm cheat code"))))).readFile("deployments/anvil/missing.json");
        return true;
    }

    function refused(string calldata) external {}

    function refusedDue(string calldata) external pure returns (bool) {
        bytes memory error = abi.encodeWithSignature("CheatcodeError(string)", "vm.rpc: execution reverted");
        assembly ("memory-safe") {
            revert(add(error, 32), mload(error))
        }
    }

    function notify(string calldata, uint8) external {}

    function notifyDue(string calldata, uint8) external pure returns (bool) {
        return true;
    }

    function windowEnd(string calldata, uint8) external pure returns (uint256) {
        return 100;
    }
}

contract TypedSteps {
    function fund(string calldata) external returns (string memory) {}
    function fundDue(string calldata) external view returns (bool) {}
    function notify(string calldata, uint8) external returns (string memory) {}
    function notifyDue(string calldata, uint8) external pure returns (bool) {}
    function observed(string calldata) external view returns (bool) {}
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

    function checkDue(string calldata) external view returns (bool) {
        return checks == 0;
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

    uint256 public openUntil;

    function renew() external {
        openUntil = block.timestamp + 10;
    }

    function fresh(string calldata) external view returns (bool) {
        return block.timestamp <= openUntil;
    }

    function freshFrom(string calldata) external pure returns (uint256) {
        return 100;
    }

    uint256 private _ripeAt = 40;

    function ripeAt(string calldata) external view returns (uint256) {
        return _ripeAt;
    }

    function postpone(string calldata) external {
        _ripeAt = 100;
    }

    function postponeDue(string calldata) external view returns (bool) {
        return _ripeAt != 100;
    }

    function ripe(string calldata) external view returns (bool) {
        return block.timestamp >= 100;
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

    function check(string calldata) external {}

    function checkDue(string calldata) external pure returns (bool) {
        return true;
    }

    function preDue(string calldata) external returns (bool) {
        _select(1);
        return !notified;
    }

    function pre(string calldata) external {
        notified = true;
    }

    function fork(uint256 chain) external returns (uint256 was) {
        was = _selected;
        if (chain != type(uint256).max) _select(chain);
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

    function executeNode(string calldata network, string calldata id) external returns (bool) {
        return _executeNode(network, id);
    }

    function _rpcFlag(string memory, string memory) internal pure virtual override returns (string memory) {
        return "node";
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

    function _unmetPredicate(uint256) internal virtual override returns (bool) {
        return false;
    }
}

/// @dev Each chain its own RPC.
contract RpcGraph is BuilderGraph {
    constructor(Registration memory u, Step[] memory s) BuilderGraph(u, s) {}

    function _rpcFlag(string memory, string memory chain) internal pure override returns (string memory) {
        return chain;
    }
}

/// @dev A driver that claims progress and meets only `Counting.fresh`, for 10 seconds per call.
contract DriverGraph is BuilderGraph {
    Counting private immutable counting;
    uint256 public calls;

    constructor(Counting c, Registration memory u, Step[] memory s) BuilderGraph(u, s) {
        counting = c;
    }

    function _unmetPredicate(uint256) internal override returns (bool) {
        ++calls;
        counting.renew();
        return true;
    }
}

contract ClockGraph is BuilderGraph {
    TwoClocks private immutable clocks;

    constructor(TwoClocks c, Registration memory u, Step[] memory s) BuilderGraph(u, s) {
        clocks = c;
    }

    function _fork(uint256 id) internal override returns (uint256) {
        return clocks.fork(id);
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

    function test_emptyArraySlotIsRefused() public {
        Step[] memory s = new Step[](2);
        s[0] = _node("present");
        vm.expectRevert(abi.encodeWithSelector(Graph.EmptyStep.selector, 1));
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

    function test_unlistedUnitIsRefused() public {
        BuilderGraph g = new BuilderGraph(unit, new Step[](0));
        Step[] memory s = new Step[](1);
        s[0] = _step("fixture.deploy", StepFunctions.deploy.selector);
        g.add(Registration(address(new StepFunctions()), "u.s.sol"), s);
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

    function test_typedFormsBuildTheSelectorForms() public {
        TypedSteps t = new TypedSteps();
        Step memory plain = _step("fixture.fund", t.fund);
        assertEq(plain.fn, "fund");
        assertEq(plain.selector, TypedSteps.fund.selector);
        assertEq(plain.dueSelector, bytes4(0));
        Step memory due = _step("fixture.fund", t.fund, t.fundDue);
        assertEq(due.selector, TypedSteps.fund.selector);
        assertEq(due.dueSelector, TypedSteps.fundDue.selector);
        Step memory nth = _step("fixture.notify.2", "notify", t.notify, t.notifyDue, 2);
        assertEq(nth.fn, "notify");
        assertEq(nth.selector, TypedSteps.notify.selector);
        assertEq(nth.dueSelector, TypedSteps.notifyDue.selector);
        assertTrue(nth.hasArg);
        assertEq(nth.arg, 2);
        Step memory until = _until("fixture.observed", "observed", t.observed);
        assertEq(uint8(until.kind), uint8(StepKind.Until));
        assertEq(until.selector, TypedSteps.observed.selector);
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

    function test_aStepWithoutADoneRuleIsRefused() public {
        Step[] memory s = new Step[](2);
        s[0] = _step("fixture.deploy", StepFunctions.deploy.selector);
        s[1] = _step("fixture.check", StepFunctions.check.selector);
        vm.expectRevert(abi.encodeWithSelector(Graph.MissingDoneRule.selector, "fixture.deploy"));
        new BuilderGraph(unit, s);
    }

    function test_predicateSelectorMatchesItsSignature() public {
        Step[] memory s = new Step[](1);
        s[0] = _until("observed", "observed", StepFunctions.fundDue.selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                Graph.SelectorMismatch.selector,
                "observed",
                StepFunctions.observed.selector,
                StepFunctions.fundDue.selector
            )
        );
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
            "forge script test/Fixture.s.sol:Fixture --sig 'guarded(string)' anvil --rpc-url node --sender $DEPLOYER\n"
        );

        s[0] = _step("fixture.locked", StepFunctions.locked.selector).due(StepFunctions.lockedDue.selector);
        assertEq(
            new BuilderGraph(unit, s).plan("anvil", "fixture.locked"),
            string.concat(
                "# cannot reach fixture.locked: ",
                vm.toString(abi.encodeWithSelector(StepFunctions.Closed.selector)),
                "\nforge script test/Fixture.s.sol:Fixture --sig 'locked(string)' anvil --rpc-url node --sender $DEPLOYER\n"
            )
        );
    }

    /// @dev A missing input is the project's mistake, but a remote refusal through `vm.rpc` may pass later.
    function test_plan_failsOnAFailedFileReadButWaitsOnARefusedRpc() public {
        Step[] memory s = new Step[](1);
        s[0] = _step("fixture.unread", StepFunctions.unread.selector).due(StepFunctions.unreadDue.selector);
        BuilderGraph g = new BuilderGraph(unit, s);
        try g.plan("anvil", "fixture.unread") {
            fail();
        } catch Error(string memory reason) {
            assertEq(vm.indexOf(reason, "fixture.unread: vm.readFile: failed to open file"), 0);
        }

        s[0] = _step("fixture.refused", StepFunctions.refused.selector).due(StepFunctions.refusedDue.selector);
        assertEq(
            new BuilderGraph(unit, s).plan("anvil", "fixture.refused"),
            string.concat(
                "# cannot reach fixture.refused: ",
                vm.toString(abi.encodeWithSignature("CheatcodeError(string)", "vm.rpc: execution reverted")),
                "\nforge script test/Fixture.s.sol:Fixture --sig 'refused(string)' anvil --rpc-url node --sender $DEPLOYER\n"
            )
        );
    }

    function test_rehearse_sendsAStepOnceAcrossADateWarp() public {
        Counting counting = new Counting();
        Step[] memory s = new Step[](2);
        s[0] = _step("fixture.deploy", Counting.deploy.selector).due(Counting.deployDue.selector);
        s[1] = _step("fixture.check", Counting.check.selector)
            .due(Counting.checkDue.selector)
            .needs("fixture.deploy")
            .notBefore("fixture.time");
        new BuilderGraph(Registration(address(counting), unit.script), s).rehearse("anvil", "fixture.check");
        assertEq(counting.deploys(), 1);
        assertEq(counting.checks(), 1);
    }

    function test_rehearse_waitsOnAPredicateNothingSatisfies() public {
        Counting counting = new Counting();
        Step[] memory s = new Step[](3);
        s[0] = _until("fixture.open", "observed", Counting.observed.selector);
        s[1] = _step("fixture.deploy", Counting.deploy.selector).due(Counting.deployDue.selector).needs("fixture.open");
        s[2] = _step("fixture.check", Counting.check.selector).due(Counting.checkDue.selector).needs("fixture.deploy");
        BuilderGraph g = new BuilderGraph(Registration(address(counting), unit.script), s);

        g.rehearse("anvil", "fixture.check");
        assertEq(counting.deploys(), 0);

        counting.openUp();
        g.rehearse("anvil", "fixture.check");
        assertEq(counting.deploys(), 1);
        assertEq(counting.checks(), 1);
    }

    function test_executeNode_sendsTheStepAloneEvenWhenDone() public {
        Counting counting = new Counting();
        Step[] memory s = new Step[](3);
        s[0] = _step("fixture.deploy", Counting.deploy.selector).due(Counting.deployDue.selector);
        s[1] = _step("fixture.check", Counting.check.selector).due(Counting.checkDue.selector).needs("fixture.deploy");
        s[2] = _step("other.deploy", Counting.deploy.selector).due(Counting.deployDue.selector).needs("fixture.check");
        BuilderGraph g = new BuilderGraph(Registration(address(counting), unit.script), s);

        assertTrue(g.executeNode("anvil", "other.deploy"));
        assertTrue(g.executeNode("anvil", "other.deploy"));
        assertEq(counting.deploys(), 2);
        assertEq(counting.checks(), 0);

        assertTrue(g.executeNode("anvil", "fixture.deploy"));
        assertEq(counting.deploys(), 3);
    }

    function test_executeNode_givesTheDriverOneTry() public {
        Counting counting = new Counting();
        Step[] memory s = new Step[](2);
        s[0] = _until("fixture.fresh", "fresh", Counting.fresh.selector);
        s[1] = _until("fixture.open", "observed", Counting.observed.selector);
        DriverGraph g = new DriverGraph(counting, Registration(address(counting), unit.script), s);

        assertTrue(g.executeNode("anvil", "fixture.fresh"));
        assertEq(g.calls(), 1);
        assertFalse(g.executeNode("anvil", "fixture.open"));
        assertEq(g.calls(), 2);
    }

    function test_executeNode_judgesTheDateOfACertifiedStep() public {
        Counting counting = new Counting();
        Step[] memory s = new Step[](2);
        s[0] = _step("fixture.deploy", Counting.deploy.selector)
            .due(Counting.deployDue.selector)
            .on("other")
            .notBefore("fixture.time");
        s[1] = _step("fixture.check", Counting.check.selector).due(Counting.checkDue.selector).needs("fixture.deploy");
        RpcGraph g = new RpcGraph(Registration(address(counting), unit.script), s);

        vm.expectRevert(
            bytes("fixture.deploy has an input date but sends on other: use a gate view, which selects that chain")
        );
        g.executeNode("anvil", "fixture.deploy");
    }

    function test_executeNode_readsAnInputDateOnTheChainItStartsOn() public {
        TwoClocks clocks = new TwoClocks();
        vm.warp(500);
        clocks.fork(1);
        vm.warp(50);
        Step[] memory s = new Step[](1);
        s[0] = _step("fixture.check", TwoClocks.check.selector)
            .due(TwoClocks.checkDue.selector)
            .notBefore("fixture.openAt");
        new ClockGraph(clocks, Registration(address(clocks), "test/Fixture.s.sol:Fixture"), s)
            .executeNode("anvil", "fixture.check");
        assertEq(clocks.fork(type(uint256).max), 1);
        assertEq(block.timestamp, 100);
    }

    /// @notice A predicate met, then unmet after a later step's date: the driver tries again.
    function test_rehearse_drivesAPredicateAgainAfterItWasMet() public {
        Counting counting = new Counting();
        Step[] memory s = new Step[](3);
        s[0] = _until("fixture.fresh", "fresh", Counting.fresh.selector);
        s[1] = _step("fixture.deploy", Counting.deploy.selector)
            .due(Counting.deployDue.selector)
            .needs("fixture.fresh")
            .notBefore("fixture.time");
        s[2] = _step("fixture.check", Counting.check.selector).due(Counting.checkDue.selector).needs("fixture.deploy");
        new DriverGraph(counting, Registration(address(counting), unit.script), s).rehearse("anvil", "fixture.check");
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

    function _datedAfterOtherChain(TwoClocks clocks) private returns (ClockGraph) {
        vm.warp(50);
        Step[] memory s = new Step[](2);
        s[0] = _step("other.pre", TwoClocks.pre.selector).due(TwoClocks.preDue.selector);
        s[1] = _step("fixture.check", TwoClocks.check.selector)
            .due(TwoClocks.checkDue.selector)
            .needs("other.pre")
            .notBefore("fixture.openAt");
        return new ClockGraph(clocks, Registration(address(clocks), "test/Fixture.s.sol:Fixture"), s);
    }

    function test_anInputDateIsReadOnTheStartingChain() public {
        TwoClocks clocks = new TwoClocks();
        clocks.pre("");
        ClockGraph g = _datedAfterOtherChain(clocks);
        assertTrue(vm.contains(g.plan("anvil", "fixture.check"), "# not before 100"));
    }

    /// @dev A done check stays done after the date: a view's date does not stop the plan.
    function test_aDoneStepPrintsNoFutureViewDate() public {
        TwoClocks clocks = new TwoClocks();
        clocks.pre("");
        Step[] memory s = new Step[](1);
        s[0] = _step("fixture.notify.0", "notify", TwoClocks.notify.selector)
            .withArg(0)
            .due(TwoClocks.notifyDue.selector)
            .gateView("windowEnd", TwoClocks.windowEnd.selector);
        ClockGraph g = new ClockGraph(clocks, Registration(address(clocks), "test/Fixture.s.sol:Fixture"), s);
        assertEq(g.plan("anvil", "fixture.notify.0"), "# done fixture.notify.0\n");
    }

    /// @dev An input date moved past a finished step does not stop the plan.
    function test_aDoneStepPrintsNoFutureInputDate() public {
        TwoClocks clocks = new TwoClocks();
        vm.warp(50);
        clocks.pre("");
        Step[] memory s = new Step[](1);
        s[0] = _step("fixture.pre", TwoClocks.pre.selector).due(TwoClocks.preDue.selector).notBefore("fixture.openAt");
        ClockGraph g = new ClockGraph(clocks, Registration(address(clocks), "test/Fixture.s.sol:Fixture"), s);
        assertEq(g.plan("anvil", "fixture.pre"), "# done fixture.pre\n");
    }

    /// @dev A predicate that holds before its date may not hold at it: its dependents wait for the date.
    function test_aPredicateThatHoldsBeforeItsDate_waitsForIt() public {
        Counting counting = new Counting();
        vm.warp(50);
        counting.renew();
        Step[] memory s = new Step[](2);
        s[0] = _until("fixture.fresh", "fresh", Counting.fresh.selector).notBefore("fixture.time");
        s[1] = _step("fixture.deploy", Counting.deploy.selector).due(Counting.deployDue.selector).needs("fixture.fresh");
        BuilderGraph g = new BuilderGraph(Registration(address(counting), unit.script), s);
        assertEq(g.plan("anvil", "fixture.deploy"), "# not before 100 fixture.fresh\n# then plan again fixture.fresh\n");
    }

    function _freshUntil60BehindAViewDateOf100() private returns (BuilderGraph) {
        Counting counting = new Counting();
        vm.warp(50);
        counting.renew();
        Step[] memory s = new Step[](2);
        s[0] = _until("fixture.fresh", "fresh", Counting.fresh.selector)
            .gateView("freshFrom", Counting.freshFrom.selector);
        s[1] = _step("fixture.deploy", Counting.deploy.selector).due(Counting.deployDue.selector).needs("fixture.fresh");
        return new BuilderGraph(Registration(address(counting), unit.script), s);
    }

    function test_aPredicateThatHoldsBeforeItsViewDate_waitsForIt() public {
        assertEq(
            _freshUntil60BehindAViewDateOf100().plan("anvil", "fixture.deploy"),
            "# not before 100 fixture.fresh, movable until reached\n# then plan again fixture.fresh\n"
        );
    }

    /// @dev A step of the same walk moves a reached date into the future: the predicate is read at the new date.
    function test_rehearse_readsAPredicateAtTheDateAnEarlierStepMoved() public {
        Counting counting = new Counting();
        vm.warp(50);
        Step[] memory s = new Step[](3);
        s[0] = _step("fixture.postpone", Counting.postpone.selector).due(Counting.postponeDue.selector);
        s[1] = _until("fixture.ripe", "ripe", Counting.ripe.selector).gateView("ripeAt", Counting.ripeAt.selector);
        s[2] = _step("fixture.deploy", Counting.deploy.selector)
            .due(Counting.deployDue.selector)
            .needs("fixture.postpone")
            .needs("fixture.ripe");
        new BuilderGraph(Registration(address(counting), unit.script), s).rehearse("anvil", "fixture.deploy");
        assertEq(counting.deploys(), 1);
        assertEq(block.timestamp, 100);
    }

    function test_executeNode_readsAPredicateAtItsViewDate() public {
        assertFalse(_freshUntil60BehindAViewDateOf100().executeNode("anvil", "fixture.fresh"));
        assertEq(block.timestamp, 100);
    }

    function test_rehearse_doesNotWarpAnotherChainToAnInputDate() public {
        TwoClocks clocks = new TwoClocks();
        clocks.fork(1);
        vm.warp(50);
        clocks.fork(0);
        vm.warp(150);
        Step[] memory s = new Step[](3);
        s[0] = _step("fixture.check", TwoClocks.check.selector)
            .due(TwoClocks.checkDue.selector)
            .notBefore("fixture.openAt");
        s[1] = _step("other.pre", TwoClocks.pre.selector).due(TwoClocks.preDue.selector);
        s[2] = _step("other.check", TwoClocks.check.selector)
            .due(TwoClocks.checkDue.selector)
            .needs("fixture.check")
            .needs("other.pre");
        new ClockGraph(clocks, Registration(address(clocks), "test/Fixture.s.sol:Fixture"), s)
            .rehearse("anvil", "other.check");
        clocks.fork(1);
        assertEq(block.timestamp, 50);
    }
}

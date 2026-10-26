// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {Declares, Registration, Step} from "../src/graph/Step.sol";
import {BuilderGraph} from "./StepBuilders.t.sol";
import {ToyUnit} from "./ToyUnit.sol";

contract Settings {
    uint256 public a;
    uint256 public b;

    function setA(uint256 a_) external {
        a = a_;
    }

    function setB(uint256 b_) external {
        require(b_ != 0, "b is never zero");
        b = b_;
    }
}

contract WantUnit is ToyUnit {
    Settings public immutable settings = new Settings();
    uint256 public wantedA = 1;
    uint256 public wantedB = 2;
    bool public sent;

    function wantB(uint256 b) external {
        wantedB = b;
    }

    /// @dev `b` waits for `a`: a want reads what the earlier ones sent.
    function configure(string calldata network) external returns (string memory) {
        _use(network);
        _want(settings.a() == wantedA, address(settings), abi.encodeCall(Settings.setA, (wantedA)));
        _want(
            settings.a() != wantedA || settings.b() == wantedB,
            address(settings),
            abi.encodeCall(Settings.setB, (wantedB))
        );
        sent = _sentThisStep();
        return _done();
    }

    function pay(string calldata network, address to, uint256 value) external returns (string memory) {
        _use(network);
        _want(to.balance >= value, to, value, "");
        return _done();
    }

    function sendA(string calldata network, uint256 a) external returns (string memory) {
        _use(network);
        _send(address(settings), abi.encodeCall(Settings.setA, (a)));
        sent = _sentThisStep();
        return _done();
    }

    function sendValue(string calldata network, address to, uint256 value) external returns (string memory) {
        _use(network);
        _send(to, value, "");
        return _done();
    }

    function payAnyway(string calldata network, address to, uint256 value) external returns (string memory) {
        _use(network);
        _want(false, to, value, "");
        return _done();
    }

    function wantAt(string calldata network, address target) external returns (string memory) {
        _use(network);
        _want(false, target, abi.encodeCall(Settings.setA, (1)));
        return _done();
    }

    /// @dev Mixes a direct broadcast with the step's own.
    function rawThenWant(string calldata network) external returns (string memory) {
        _use(network);
        vm.startBroadcast(address(0xB0B));
        _want(false, address(settings), abi.encodeCall(Settings.setA, (3)));
        return _done();
    }

    /// @dev As a deploy step does for a reused role.
    function openOnly(string calldata network) external returns (string memory) {
        _use(network);
        _startBroadcast();
        sent = _sentThisStep();
        return _done();
    }

    /// @dev Opens twice, closes, and opens again: one broadcast at a time, two sends counted.
    function reopen(string calldata network) external returns (string memory) {
        _use(network);
        _startBroadcast();
        _startBroadcast();
        settings.setA(7);
        vm.stopBroadcast();
        _startBroadcast();
        settings.setB(7);
        sent = _sentThisStep();
        return _done();
    }
}

contract WantsTest is Test, Declares {
    string private constant DIR = "cache/core-test/deployments/";
    string private constant SCRIPT = "test/Wants.t.sol:WantUnit";

    WantUnit private unit;

    function setUp() public {
        unit = new WantUnit();
    }

    function _network(string memory name) private returns (string memory) {
        string memory dir = string.concat(DIR, name);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(dir, true);
        vm.chainId(31337);
        vm.writeFile(string.concat(dir, "/network.json"), '{"chains": {"main": {"id": 31337}}}');
        return name;
    }

    function test_want_sendsOnlyWhatIsUnmet_inOrder_andTheProbeReadsTheStepDue() public {
        string memory net = _network("wants-configure");
        Step[] memory s = new Step[](1);
        s[0] = _step("toy.configure", WantUnit.configure.selector);
        BuilderGraph g = new BuilderGraph(Registration(address(unit), SCRIPT), s);
        assertEq(
            g.plan(net, "toy.configure"),
            string.concat(
                "forge script ", SCRIPT, " --sig 'configure(string)' ", net, " --rpc-url node --sender $DEPLOYER\n"
            )
        );

        unit.configure(net);
        assertTrue(unit.sent());
        assertEq(unit.settings().a(), 1);
        assertEq(unit.settings().b(), 2);
        assertEq(g.plan(net, "toy.configure"), "# done toy.configure\n");

        unit.configure(net);
        assertFalse(unit.sent());
    }

    function test_want_revertsWithTheCallsReason() public {
        string memory net = _network("wants-revert");
        unit.configure(net);
        unit.wantB(0);
        vm.expectRevert(bytes("b is never zero"));
        unit.configure(net);
    }

    function test_want_paysAnAccountWithoutCode_onlyWhereItsBalanceIsShort() public {
        string memory net = _network("wants-pay");
        address payee = makeAddr("payee");
        unit.pay(net, payee, 1 ether);
        assertEq(payee.balance, 1 ether);
        unit.pay(net, payee, 1 ether);
        assertEq(payee.balance, 1 ether, "a met want paid again");
        vm.expectRevert(bytes(string.concat(vm.toString(payee), " has no code")));
        unit.payAnyway(net, payee, 0);
    }

    function test_send_sendsEachTime_whateverTheStateHolds() public {
        string memory net = _network("wants-send");
        unit.sendA(net, 1);
        assertTrue(unit.sent());
        unit.sendA(net, 1);
        assertTrue(unit.sent(), "a send that the state already holds was skipped");
        assertEq(unit.settings().a(), 1);

        address payee = makeAddr("payee");
        unit.sendValue(net, payee, 1 ether);
        unit.sendValue(net, payee, 1 ether);
        assertEq(payee.balance, 2 ether);
    }

    function test_want_refusesATargetWithoutCode() public {
        string memory net = _network("wants-nocode");
        vm.expectRevert(bytes("0x000000000000000000000000000000000000dEaD has no code"));
        unit.wantAt(net, address(0xdead));
    }

    /// @dev Reusing it would send the want outside any broadcast, or as another account.
    function test_startBroadcast_refusesABroadcastTheStepDidNotOpen() public {
        string memory net = _network("wants-raw");
        vm.expectRevert(bytes("vm.startBroadcast: a broadcast is active already"));
        unit.rawThenWant(net);
    }

    function test_startBroadcast_opensOnce_andDoneCountsEverySend() public {
        string memory net = _network("wants-reopen");
        unit.openOnly(net);
        assertFalse(unit.sent(), "an open broadcast that sent nothing counted as a send");
        unit.reopen(net);
        assertTrue(unit.sent());
        assertEq(unit.settings().b(), 7);
        unit.reopen(net);
    }
}

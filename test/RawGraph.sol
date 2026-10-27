// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FIXTURE_SENDER} from "../src/graph/Graph.sol";
import {FileGraph} from "../src/FileGraph.sol";
import {Role} from "../src/Roles.sol";
import {IProbe, Step} from "../src/graph/Step.sol";
import {FixtureUnit} from "./VaultGraph.sol";
import {FixtureToken} from "./FixtureToken.sol";

/// @dev Steps that are done by their `Due` view and send anyway, each in a way the fixture must see.
contract RawUnit is FixtureUnit {
    address public constant STRAY = address(uint160(uint256(keccak256("stray sender"))));
    FixtureToken public sink = new FixtureToken(0);

    function steps() external view returns (Step[] memory s) {
        s = new Step[](12);
        s[0] = _step("raw.silent", "silent", this.silent.selector).due(this.silentDue.selector);
        s[1] = _step("raw.raw", "raw", this.raw.selector).due(this.rawDue.selector);
        s[2] = _step("raw.stray", "stray", this.stray.selector).due(this.strayDue.selector);
        s[4] = _step("raw.gated", "gated", this.gated.selector).by("raw.operator");
        s[5] = _step("raw.unnamed", "unnamed", this.unnamed.selector).due(this.unnamedDue.selector);
        s[6] = _step("raw.judge", "judge", this.judge.selector).due(this.judgeDue.selector);
        s[7] =
            _step("raw.explicit", "explicit", this.explicit.selector).due(this.explicitDue.selector).by("raw.operator");
        s[8] = _until("raw.gate", "gateOpen", this.gateOpen.selector);
        s[9] = _step("raw.reenter", "reenter", this.reenter.selector).due(this.reenterDue.selector);
        s[10] = _step("raw.spoil", "spoil", this.spoil.selector).due(this.spoilDue.selector);
        s[11] = _step("raw.victim", "victim", this.victim.selector).due(this.victimDue.selector).needs("raw.spoil");
        s[3] = _step("raw.hidden", "hidden", this.hidden.selector).due(this.hiddenDue.selector);
    }

    function silent(string calldata network) external step(network) {
        _send(address(sink), _transfer());
    }

    function raw(string calldata network) external step(network) {
        vm.broadcast(STRAY);
        address(sink).call(_transfer());
    }

    /// @dev A raw send whose calldata starts like a probe's.
    function stray(string calldata network) external step(network) {
        vm.broadcast(STRAY);
        address(sink).call(abi.encodePacked(IProbe.probe.selector));
    }

    /// @dev Sends only when entered as the operator, as its command enters it.
    function gated(string calldata network) external step(network) {
        if (msg.sender == _requiredAddress(_unitInput(), "operator")) _send(address(sink), _transfer());
    }

    function unnamed(string calldata network) external step(network) {}

    /// @dev Sends from an account no node names while the planner judges the step.
    function unnamedDue(string calldata) external returns (bool) {
        vm.broadcast(STRAY);
        address(sink).call(_transfer());
        return false;
    }

    /// @dev `gated` with a `Due` view, so that the planner does not probe it.
    function explicit(string calldata network) external step(network) {
        if (msg.sender == _requiredAddress(_unitInput(), "operator")) _send(address(sink), _transfer());
    }

    function explicitDue(string calldata) external pure returns (bool) {
        return false;
    }

    bool public open;

    function setOpen() external {
        open = true;
    }

    function gateOpen(string calldata) external view returns (bool) {
        return open;
    }

    address public host;
    bool private reentered;
    bool private fired;

    function setHost(address host_) external {
        host = host_;
    }

    function reenter(string calldata network) external step(network) {
        reentered = true;
    }

    /// @dev Sends once at the first judgment after the step ran, then calls back into the fixture.
    function reenterDue(string calldata) external returns (bool) {
        if (!reentered) return true;
        if (!fired) {
            fired = true;
            vm.broadcast(FIXTURE_SENDER);
            address(sink).call(_transfer());
            host.call(abi.encodeWithSignature("once(string)", "raw.silent"));
        }
        return false;
    }

    bool private judged;
    bool private rechecked;

    function judge(string calldata network) external step(network) {
        judged = true;
    }

    /// @dev Sends once, from a node's sender, at the first judgment after the step ran.
    function judgeDue(string calldata) external returns (bool) {
        if (!judged) return true;
        if (!rechecked) {
            rechecked = true;
            vm.broadcast(FIXTURE_SENDER);
            address(sink).call(_transfer());
        }
        return false;
    }

    bool private spoiled;

    /// @dev Sends nothing, yet its rerun makes `victim` due.
    function spoil(string calldata network) external step(network) {
        spoiled = true;
    }

    function spoilDue(string calldata) external pure returns (bool) {
        return false;
    }

    function victim(string calldata network) external step(network) {}

    function victimDue(string calldata) external view returns (bool) {
        return spoiled;
    }

    function hidden(string calldata network) external step(network) {}

    /// @dev Sends while the planner judges the step, outside the step's call.
    function hiddenDue(string calldata) external returns (bool) {
        vm.broadcast(FIXTURE_SENDER);
        address(sink).call(_transfer());
        return true;
    }

    function silentDue(string calldata) external pure returns (bool) {
        return false;
    }

    function rawDue(string calldata) external pure returns (bool) {
        return false;
    }

    function strayDue(string calldata) external pure returns (bool) {
        return false;
    }

    function _transfer() private pure returns (bytes memory) {
        return abi.encodeCall(FixtureToken.transfer, (address(1), 0));
    }

    function _roles() internal pure override returns (Role[] memory) {
        return new Role[](0);
    }

    function _unit() internal pure override returns (string memory) {
        return "raw";
    }
}

contract RawGraph is FileGraph {
    constructor() {
        _add(address(new RawUnit()), "script/RawUnit.s.sol:RawUnit");
        _validateGraph();
    }
}

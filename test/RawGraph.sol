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
        s = new Step[](6);
        s[0] = _step("raw.silent", "silent", this.silent.selector).due(this.silentDue.selector);
        s[1] = _step("raw.raw", "raw", this.raw.selector).due(this.rawDue.selector);
        s[2] = _step("raw.stray", "stray", this.stray.selector).due(this.strayDue.selector);
        s[4] = _step("raw.gated", "gated", this.gated.selector).by("raw.operator");
        s[5] = _step("raw.unnamed", "unnamed", this.unnamed.selector).due(this.unnamedDue.selector);
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

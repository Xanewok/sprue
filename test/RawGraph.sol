// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

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
        s = new Step[](3);
        s[0] = _step("raw.silent", "silent", this.silent.selector).due(this.silentDue.selector);
        s[1] = _step("raw.raw", "raw", this.raw.selector).due(this.rawDue.selector);
        s[2] = _step("raw.stray", "stray", this.stray.selector).due(this.strayDue.selector);
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

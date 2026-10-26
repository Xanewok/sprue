// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Role, create} from "sprue/Roles.sol";
import {Unit} from "sprue/Unit.sol";
import {Step} from "sprue/graph/Step.sol";

function SOURCE() pure returns (Role memory) {
    return create("source", "Source").unit("source");
}

contract DeploySource is Unit {
    function steps() external view returns (Step[] memory s) {
        s = new Step[](2);
        s[0] = _step("source.deploy", this.deploy);
        s[1] = _step("source.check", this.check).needs("source.deploy");
    }

    function deploy(string calldata network) external step(network) {
        _deploy(SOURCE());
    }

    function check(string calldata network) external step(network) {
        _at(SOURCE());
        _endCheck();
    }

    function _roles() internal pure override returns (Role[] memory) {
        return _list(SOURCE());
    }

    function _unit() internal pure override returns (string memory) {
        return "source";
    }
}

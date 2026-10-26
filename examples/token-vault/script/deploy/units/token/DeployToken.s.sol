// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Role, create} from "sprue/Roles.sol";
import {Recovers, Unit} from "sprue/Unit.sol";
import {Step} from "sprue/graph/Step.sol";

uint256 constant SUPPLY = 1000;

/// @dev The token, as this unit and every other reads it.
function TOKEN() pure returns (Role memory) {
    return create("token", "Token").unit("token").args(abi.encode(SUPPLY));
}

contract DeployToken is Unit, Recovers {
    function steps() external view returns (Step[] memory s) {
        s = new Step[](2);
        s[0] = _step("token.deploy", this.deploy);
        s[1] = _step("token.check", this.check).needs("token.deploy");
    }

    function deploy(string calldata network) external step(network) {
        _deploy(TOKEN());
    }

    function check(string calldata network) external step(network) {
        _at(TOKEN());
        _endCheck();
    }

    function _roles() internal pure override returns (Role[] memory) {
        return _list(TOKEN());
    }

    function _unit() internal pure override returns (string memory) {
        return "token";
    }
}

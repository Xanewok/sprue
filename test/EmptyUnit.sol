// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Unit} from "../src/Unit.sol";

contract EmptyUnit is Unit {
    function _unit() internal pure override returns (string memory) {
        return "empty";
    }
}

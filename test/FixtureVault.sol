// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @dev In its own file because the library finds an artifact at `out/<Name>.sol/<Name>.json`.
contract FixtureVault {
    address public immutable TOKEN;
    address public immutable OPERATOR;
    uint256 public limit;
    bool public approved;

    constructor(address token, address operator) {
        TOKEN = token;
        OPERATOR = operator;
    }

    function configure(uint256 limit_) external {
        require(msg.sender == OPERATOR, "not the operator");
        limit = limit_;
    }

    function approve() external {
        approved = true;
    }
}

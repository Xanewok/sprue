// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @dev In its own file because the library finds an artifact at `out/<Name>.sol/<Name>.json`.
contract FixtureToken {
    mapping(address => uint256) public balanceOf;

    constructor(uint256 supply) {
        balanceOf[msg.sender] = supply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

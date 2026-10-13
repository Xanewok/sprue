// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @dev In its own file because the library finds an artifact at `out/<Name>.sol/<Name>.json`.
contract Token {
    uint256 public immutable SUPPLY;
    mapping(address => uint256) public balanceOf;

    constructor(uint256 supply) {
        SUPPLY = supply;
        balanceOf[msg.sender] = supply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

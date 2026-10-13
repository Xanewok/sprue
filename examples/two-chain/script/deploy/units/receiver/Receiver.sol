// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract Receiver {
    mapping(uint8 => address) public opened;

    function open(uint8 window, address source) external {
        opened[window] = source;
    }
}

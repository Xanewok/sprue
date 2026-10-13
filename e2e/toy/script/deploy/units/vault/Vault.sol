// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract Vault {
    address public immutable TOKEN;

    constructor(address token) {
        TOKEN = token;
    }
}

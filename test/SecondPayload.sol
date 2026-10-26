// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @dev A second artifact: a recovery finds each role's CREATE by its artifact.
contract SecondPayload {
    uint256 public immutable tag;

    constructor(uint256 tag_) {
        tag = tag_;
    }
}

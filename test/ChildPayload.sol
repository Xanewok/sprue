// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract ChildPayload {
    uint256 public immutable tag;

    constructor(uint256 tag_) {
        tag = tag_;
    }
}

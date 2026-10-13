// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @dev In its own file because the library finds an artifact at `out/<Name>.sol/<Name>.json`.
contract ToyPayload {
    uint256 public immutable tag;

    constructor(uint256 tag_) {
        tag = tag_;
    }
}

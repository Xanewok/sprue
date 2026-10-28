// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ChildPayload} from "./ChildPayload.sol";

/// @dev Its constructor creates a child, which it keeps in storage that a call can change.
contract StoragePayload {
    ChildPayload public child;

    constructor() {
        child = new ChildPayload(3);
    }

    function setChild(ChildPayload child_) external {
        child = child_;
    }
}

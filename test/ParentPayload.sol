// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ChildPayload} from "./ChildPayload.sol";

/// @dev Its constructor creates a child, which the parent's code fixes.
contract ParentPayload {
    ChildPayload public immutable CHILD;

    constructor() {
        CHILD = new ChildPayload(3);
    }
}

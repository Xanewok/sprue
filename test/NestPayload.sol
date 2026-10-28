// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ParentPayload} from "./ParentPayload.sol";

/// @dev Its constructor creates a parent, whose constructor creates a child.
contract NestPayload {
    ParentPayload public immutable PARENT;

    constructor() {
        PARENT = new ParentPayload();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {TablePayload} from "./TablePayload.sol";

/// @dev Its constructor returns `TablePayload`'s runtime with a row behind it, in place of its own.
contract ReturnsTable {
    constructor() {
        bytes memory code = abi.encodePacked(type(TablePayload).runtimeCode, uint256(7));
        assembly ("memory-safe") {
            return(add(code, 32), mload(code))
        }
    }
}

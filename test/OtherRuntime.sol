// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @dev Its constructor returns runtime code other than the artifact's, as a constructor-returned runtime does.
contract OtherRuntime {
    constructor() {
        assembly ("memory-safe") {
            mstore8(0, 0x00)
            return(0, 1)
        }
    }
}

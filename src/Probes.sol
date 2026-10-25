// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IProbe} from "./graph/Step.sol";

/// @notice For tests: a step's probe, as a plan judges a step that has no `Due` view.
library Probes {
    /// @dev True while `step` (a call of one of `unit`'s steps) would send or change its journal, false
    ///      once it is done. Reverts with the step's own refusal, so a test's `vm.expectRevert` sees it.
    ///      `sender` is the step's `.by` account, as the plan pranks it. External, so that the call
    ///      `vm.expectRevert` watches is this one.
    function due(address unit, bytes memory step, address sender) external returns (bool) {
        (, bytes memory ret) = unit.call(abi.encodeCall(IProbe.probe, (step, sender)));
        require(ret.length >= 4 && bytes4(ret) == IProbe.Probed.selector, "the unit does not answer a probe");
        (bool returned, bytes memory result) = abi.decode(_strip(ret), (bool, bytes));
        if (returned) return false;
        if (result.length >= 4 && bytes4(result) == IProbe.StepDue.selector) return true;
        assembly ("memory-safe") {
            revert(add(result, 32), mload(result))
        }
    }

    function _strip(bytes memory data) private pure returns (bytes memory rest) {
        rest = new bytes(data.length - 4);
        for (uint256 i; i < rest.length; ++i) {
            rest[i] = data[i + 4];
        }
    }
}

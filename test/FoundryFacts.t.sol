// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";

contract FoundryFactsTarget {
    uint256 public value;

    function touch() external {
        ++value;
    }

    function forward(FoundryFactsTarget next) external {
        next.touch();
    }
}

contract FoundryFactsTest is Test {
    address private sender = makeAddr("sender");
    FoundryFactsTarget private a = new FoundryFactsTarget();
    FoundryFactsTarget private b = new FoundryFactsTarget();

    function _access(VmSafe.AccountAccess[] memory accesses, VmSafe.AccountAccessKind kind, address account)
        private
        pure
        returns (VmSafe.AccountAccess memory)
    {
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].kind == kind && accesses[i].account == account) return accesses[i];
        }
        revert("missing account access");
    }

    /// @dev Counting sends needs CALL and CREATE accesses attributed to the broadcaster without code.
    function test_broadcast_recordsSenderAsCallAndCreateAccessor() public {
        assertEq(sender.code.length, 0);
        vm.startStateDiffRecording();
        vm.startBroadcast(sender);
        a.touch();
        address created = address(new FoundryFactsTarget());
        vm.stopBroadcast();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertEq(_access(accesses, VmSafe.AccountAccessKind.Call, address(a)).accessor, sender);
        assertEq(_access(accesses, VmSafe.AccountAccessKind.Create, created).accessor, sender);
    }

    /// @dev Counting sends and Replay use nonce deltas to detect sends, excluding static calls.
    function test_broadcast_incrementsNonceForCallAndCreateButNotStaticCalls() public {
        uint256 nonce = vm.getNonce(sender);
        vm.startBroadcast(sender);
        a.touch();
        assertEq(vm.getNonce(sender), nonce + 1);
        new FoundryFactsTarget();
        assertEq(vm.getNonce(sender), nonce + 2);
        assertEq(a.value(), 1);
        assertEq(vm.getNonce(sender), nonce + 2);
        vm.stopBroadcast();
    }

    /// @dev Counting sends must include a reverted top-level broadcast call: it advances the nonce.
    function test_broadcast_revertedCallIsRecordedAndStillAdvancesTheNonce() public {
        uint256 nonce = vm.getNonce(sender);
        vm.startStateDiffRecording();
        vm.startBroadcast(sender);
        (bool ok,) = address(this).call(abi.encodeWithSignature("missingProbeStep()"));
        vm.stopBroadcast();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertFalse(ok);
        assertTrue(_access(accesses, VmSafe.AccountAccessKind.Call, address(this)).reverted);
        // A reverted broadcast call is still a transaction: the send count must include it.
        assertEq(vm.getNonce(sender), nonce + 1);
    }

    /// @dev Kill after send k restores EVM state separately from its file checkpoint.
    function test_snapshot_restoresTimestampAndNonceButKeepsFileWrites() public {
        vm.createDir("cache/core-test", true);
        string memory path = string.concat("cache/core-test/foundry-facts-", vm.toString(vm.randomUint()));
        uint256 timestamp = vm.getBlockTimestamp();
        uint256 nonce = vm.getNonce(sender);
        uint256 id = vm.snapshotState();
        vm.warp(timestamp + 100);
        vm.broadcast(sender);
        a.touch();
        vm.writeFile(path, "after snapshot");
        assertEq(vm.getBlockTimestamp(), timestamp + 100);
        assertEq(vm.getNonce(sender), nonce + 1);
        assertTrue(vm.revertToState(id));
        assertEq(vm.getBlockTimestamp(), timestamp);
        assertEq(vm.getNonce(sender), nonce);
        assertEq(vm.readFile(path), "after snapshot");
        vm.removeFile(path);
    }

    /// @dev Kill after send k replays CREATE initcode from the restored sender nonce.
    function test_snapshot_replayedCreateLandsAtRecordedAddress() public {
        uint256 nonce = vm.getNonce(sender);
        uint256 id = vm.snapshotState();
        vm.startStateDiffRecording();
        vm.broadcast(sender);
        address created = address(new FoundryFactsTarget());
        VmSafe.AccountAccess memory access =
            _access(vm.stopAndReturnStateDiff(), VmSafe.AccountAccessKind.Create, created);
        assertEq(created, vm.computeCreateAddress(sender, nonce));
        assertTrue(vm.revertToState(id));
        assertEq(created.code.length, 0);
        bytes memory initcode = access.data;
        vm.broadcast(sender);
        address replayed;
        assembly ("memory-safe") {
            replayed := create(0, add(initcode, 0x20), mload(initcode))
        }
        assertEq(replayed, created);
        assertGt(replayed.code.length, 0);
    }

    /// @dev Counting sends filters accessors without code, so nested calls must retain contract accessors.
    function test_broadcast_onlyTopLevelCallHasSenderAsAccessor() public {
        vm.startStateDiffRecording();
        vm.startBroadcast(sender);
        a.forward(b);
        vm.stopBroadcast();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertEq(_access(accesses, VmSafe.AccountAccessKind.Call, address(a)).accessor, sender);
        assertEq(_access(accesses, VmSafe.AccountAccessKind.Call, address(b)).accessor, address(a));
        uint256 sends;
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].kind == VmSafe.AccountAccessKind.Call && accesses[i].accessor.code.length == 0) ++sends;
        }
        assertEq(sends, 1);
    }
}

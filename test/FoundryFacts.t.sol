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

    /// @dev A fixture that counts a step's sends from the state diff finds them as CALL and CREATE accesses
    ///      whose accessor is the broadcaster.
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

    /// @dev A fixture that checks its send count against the sender's nonce relies on each broadcast call and
    ///      create advancing it, and a static call not.
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

    /// @dev A fixture that counts a step's sends by nonce must count a reverted top-level broadcast call: it
    ///      advances the nonce.
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

    /// @dev A fixture that stops a step after some of its sends and runs it again must restore journal files
    ///      itself: reverting the EVM state leaves them.
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

    /// @dev A fixture that replays a step's first sends after reverting the EVM state relies on a replayed
    ///      CREATE landing at its recorded address.
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

    /// @dev A fixture that keeps only accesses whose accessor has no code relies on nested calls naming the
    ///      calling contract, not the broadcaster.
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

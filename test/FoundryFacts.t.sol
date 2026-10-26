// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";

contract FoundryFactsTarget {
    uint256 public value;

    function touch() external payable {
        ++value;
    }

    function forward(FoundryFactsTarget next) external {
        next.touch();
    }
}

contract FoundryFactsCallee {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address public caller;
    uint256 public value;

    function broadcast() external {
        caller = msg.sender;
        vm.startBroadcast(msg.sender);
        ++value;
        vm.stopBroadcast();
    }
}

contract FoundryFactsPayload {
    uint256 public immutable ARG;

    constructor(uint256 arg, bool fail) payable {
        require(!fail, "constructor refused");
        ARG = arg;
    }
}

contract FoundryFactsRelay {
    function callThenRevert(FoundryFactsTarget target) external {
        target.touch();
        revert("undone");
    }
}

contract FoundryFactsProber {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function probe(address as_) external {
        vm.startPrank(as_, as_);
        address(this).call(abi.encodeCall(this.noop, ()));
        vm.stopPrank();
        revert("probed");
    }

    function noop() external {}
}

contract FoundryFactsHost {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function start() external {
        vm.startStateDiffRecording();
    }

    function stop() external returns (VmSafe.AccountAccess[] memory) {
        return vm.stopAndReturnStateDiff();
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

    /// @dev A fixture cannot enter a step as its sender with a prank and leave the step's broadcast to the step:
    ///      the prank is still active in the called frame.
    function test_prank_blocksTheCalledFramesBroadcast() public {
        FoundryFactsCallee callee = new FoundryFactsCallee();
        vm.prank(sender, sender);
        (bool ok, bytes memory ret) = address(callee).call(abi.encodeCall(FoundryFactsCallee.broadcast, ()));
        assertFalse(ok);
        assertTrue(vm.contains(abi.decode(_strip(ret), (string)), "you have an active prank"));
    }

    function _strip(bytes memory data) private pure returns (bytes memory rest) {
        rest = new bytes(data.length - 4);
        for (uint256 i; i < rest.length; ++i) {
            rest[i] = data[i + 4];
        }
    }

    /// @dev A fixture that starts recording in a callback and drains it in a later one relies on the recording
    ///      surviving the first callback's return, holding what happens between them in order.
    function test_stateDiff_startedInACallbackSurvivesItsReturn() public {
        FoundryFactsHost host = new FoundryFactsHost();
        host.start();
        vm.broadcast(sender);
        a.touch();
        vm.broadcast(sender);
        b.touch();
        VmSafe.AccountAccess[] memory accesses = host.stop();
        uint256 sends;
        address[2] memory order;
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].kind != VmSafe.AccountAccessKind.Call || accesses[i].accessor != sender) continue;
            order[sends++] = accesses[i].account;
        }
        assertEq(sends, 2);
        assertEq(order[0], address(a));
        assertEq(order[1], address(b));
    }

    /// @dev A fixture that records a send as its envelope relies on these fields of a broadcast call and CREATE.
    function test_broadcast_recordsValueCalldataInitcodeAndChain() public {
        vm.deal(sender, 10);
        vm.startStateDiffRecording();
        vm.startBroadcast(sender);
        (bool ok,) = address(a).call{value: 3}(abi.encodeCall(FoundryFactsTarget.touch, ()));
        address made = address(new FoundryFactsPayload{value: 2}(7, false));
        vm.stopBroadcast();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertTrue(ok);
        VmSafe.AccountAccess memory call = _access(accesses, VmSafe.AccountAccessKind.Call, address(a));
        assertEq(call.value, 3);
        assertEq(call.data, abi.encodeCall(FoundryFactsTarget.touch, ()));
        assertEq(call.chainInfo.chainId, block.chainid);
        VmSafe.AccountAccess memory create = _access(accesses, VmSafe.AccountAccessKind.Create, made);
        assertEq(create.value, 2);
        assertEq(create.data, bytes.concat(type(FoundryFactsPayload).creationCode, abi.encode(uint256(7), false)));
    }

    /// @dev A fixture that counts a reverted send relies on a CREATE whose constructor reverts being recorded
    ///      as reverted, and on a call inside a reverted ancestor being marked reverted too.
    function test_broadcast_revertedCreateAndAncestorAreMarked() public {
        FoundryFactsRelay relay = new FoundryFactsRelay();
        vm.startStateDiffRecording();
        vm.startBroadcast(sender);
        try new FoundryFactsPayload(1, true) {} catch {}
        (bool ok,) = address(relay).call(abi.encodeCall(FoundryFactsRelay.callThenRevert, (a)));
        vm.stopBroadcast();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertFalse(ok);
        bool createSeen;
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].kind == VmSafe.AccountAccessKind.Create) {
                createSeen = true;
                assertTrue(accesses[i].reverted);
            }
        }
        assertTrue(createSeen);
        assertTrue(_access(accesses, VmSafe.AccountAccessKind.Call, address(a)).reverted);
        assertEq(a.value(), 0);
    }

    /// @dev `_broadcaster` reads the broadcaster and its nonce before a CREATE, and the CREATE lands there.
    function test_readCallers_namesTheBroadcasterBeforeACreate() public {
        vm.startBroadcast(sender);
        (VmSafe.CallerMode mode, address caller,) = vm.readCallers();
        uint256 nonce = vm.getNonce(sender);
        address made = address(new FoundryFactsTarget());
        vm.stopBroadcast();
        assertEq(uint8(mode), uint8(VmSafe.CallerMode.RecurrentBroadcast));
        assertEq(caller, sender);
        assertEq(made, vm.computeCreateAddress(sender, nonce));
    }

    /// @dev A broadcast CREATE2 is recorded as a call to the factory with `salt ++ initcode`, from the sender.
    function test_broadcast_create2IsAFactoryCall() public {
        address factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        vm.etch(
            factory,
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
        bytes32 salt = bytes32(uint256(5));
        vm.startStateDiffRecording();
        vm.startBroadcast(sender);
        address made = address(new FoundryFactsTarget{salt: salt}());
        vm.stopBroadcast();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        VmSafe.AccountAccess memory call = _access(accesses, VmSafe.AccountAccessKind.Call, factory);
        assertEq(call.accessor, sender);
        assertEq(call.data, bytes.concat(salt, type(FoundryFactsTarget).creationCode));
        assertGt(made.code.length, 0);
    }

    /// @dev Forge keeps no broadcast record of a test's sends, so a fixture's creations have no transaction
    ///      for a proof to find.
    function test_broadcast_leavesNoRecordUnderATest() public {
        bool existed = vm.exists("broadcast");
        vm.broadcast(sender);
        a.touch();
        assertEq(vm.exists("broadcast"), existed);
    }

    /// @dev A bare `vm.broadcast()` sends from forge's default sender, which a fixture always watches.
    function test_broadcast_withoutASenderIsTheDefaultSender() public {
        vm.startStateDiffRecording();
        vm.broadcast();
        a.touch();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertEq(_access(accesses, VmSafe.AccountAccessKind.Call, address(a)).accessor, DEFAULT_SENDER);
    }

    /// @dev A fixture that finds sends by their accessor must tell a probe's call to its own unit, which a prank
    ///      makes a call from the pranked account, from a send: the probe's frame is its parent in the diff.
    function test_prank_makesAProbesSelfCallACallFromThePrankedAccount() public {
        FoundryFactsProber prober = new FoundryFactsProber();
        vm.startStateDiffRecording();
        address(prober).call(abi.encodeCall(FoundryFactsProber.probe, (sender)));
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        VmSafe.AccountAccess memory probe = _access(accesses, VmSafe.AccountAccessKind.Call, address(prober));
        assertEq(probe.accessor, address(this));
        uint256 found;
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account != address(prober) || accesses[i].accessor != sender) continue;
            ++found;
            assertTrue(accesses[i].reverted);
            assertEq(accesses[i].depth, probe.depth + 1);
        }
        assertEq(found, 1);
    }
}

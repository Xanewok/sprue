// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice The only part of the fixture that reads Foundry's state diff and nonces: what a transaction is, in a
///         `forge test`. Each fact it relies on is pinned in `test/FoundryFacts.t.sol` and listed in
///         DESIGN.md, "What Foundry provides".
abstract contract ForgeTranscript is Test {
    struct Sent {
        uint256 chainId;
        address from;
        uint64 nonce;
        bool create;
        address to;
        uint256 value;
        bytes data;
    }

    struct Created {
        address at;
        bytes initcode;
    }

    Sent[] private _sent;
    address[] private _watched;
    uint256[] private _before;

    /// @dev Starts a transcript. `who` are the accounts whose nonce must move by exactly their entries.
    function _transcriptBegin(address[] memory who) internal {
        delete _sent;
        delete _before;
        _watched = who;
        for (uint256 i; i < who.length; ++i) {
            _before.push(vm.getNonce(who[i]));
        }
    }

    function _recordStart() internal {
        vm.startStateDiffRecording();
    }

    /// @dev Ends the recording and appends its sends: every Call and Create whose accessor has no code, a
    ///      reverted top-level one too. Returns the CREATEs that landed.
    function _recordStop() internal returns (Created[] memory created) {
        VmSafe.AccountAccess[] memory log = vm.stopAndReturnStateDiff();
        created = new Created[](log.length);
        uint256 count;
        for (uint256 i; i < log.length; ++i) {
            VmSafe.AccountAccess memory a = log[i];
            bool call = a.kind == VmSafe.AccountAccessKind.Call;
            if (!call && a.kind != VmSafe.AccountAccessKind.Create) continue;
            if (a.accessor.code.length != 0) continue;
            _sent.push(Sent(a.chainInfo.chainId, a.accessor, 0, !call, a.account, a.value, a.data));
            if (!call && !a.reverted) created[count++] = Created(a.account, a.data);
        }
        // SAFETY: `count <= log.length`, so the shortened array lies within its allocation.
        assembly ("memory-safe") {
            mstore(created, count)
        }
    }

    /// @dev Reverts unless each watched account's nonce moved by its entries. Returns the transcript with each
    ///      entry's nonce.
    function _transcriptEnd() internal returns (Sent[] memory sent) {
        sent = _sent;
        for (uint256 i; i < _watched.length; ++i) {
            uint256 count;
            for (uint256 j; j < sent.length; ++j) {
                if (sent[j].from == _watched[i]) ++count;
            }
            require(
                vm.getNonce(_watched[i]) == _before[i] + count,
                string.concat(
                    vm.toString(_watched[i]), " sent a different number of transactions than the transcript holds"
                )
            );
        }
        for (uint256 i; i < sent.length; ++i) {
            uint256 earlier;
            uint256 total;
            for (uint256 j; j < sent.length; ++j) {
                if (sent[j].from != sent[i].from) continue;
                if (j < i) ++earlier;
                ++total;
            }
            sent[i].nonce = uint64(vm.getNonce(sent[i].from) - total + earlier);
        }
    }
}

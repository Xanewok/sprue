// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {Unit} from "../src/Unit.sol";

/// @dev A unit whose forks are counted, not made: a test with no RPC has none to fork.
contract ForkCountingUnit is Unit {
    uint256 public made;

    function _unit() internal pure virtual override returns (string memory) {
        return "forks";
    }

    function _makeFork(string memory) internal override returns (uint256 fork, uint256 head) {
        return (++made + 100, 7);
    }

    function pick(string calldata chain) external returns (uint256 fork, uint256 head) {
        (fork, head) = _forkOf(chain);
    }

    function headOf(string calldata chain) external view returns (uint256) {
        return _forkHead(chain);
    }

    /// @dev What a probe does: work, then a revert that discards the unit's storage.
    function pickAndRevert(string calldata chain) external {
        _forkOf(chain);
        revert("probe");
    }
}

contract OtherForkCountingUnit is ForkCountingUnit {
    function _unit() internal pure override returns (string memory) {
        return "others";
    }
}

contract UnitForkTest is Test {
    ForkCountingUnit private unit = new ForkCountingUnit();

    function test_aForkOutlivesTheRevertOfTheCallThatMadeIt() public {
        (bool ok,) = address(unit).call(abi.encodeCall(unit.pickAndRevert, ("l2")));
        assertFalse(ok);
        (uint256 fork, uint256 head) = unit.pick("l2");
        // `made` is storage, which the revert discarded: the fork the revert left is the first one made.
        assertEq(unit.made(), 0, "the revert made the unit fork again");
        assertEq(fork, 101);
        assertEq(head, 7);
        assertEq(unit.headOf("l2"), 7);
    }

    function test_eachChainAndEachUnitHasItsOwnFork() public {
        (uint256 a,) = unit.pick("l1");
        (uint256 b,) = unit.pick("l2");
        (uint256 c,) = unit.pick("l1");
        (uint256 d,) = new OtherForkCountingUnit().pick("l1");
        assertEq(a, c);
        assertTrue(a != b);
        assertEq(d, 101, "another unit shared the fork");
        assertEq(unit.headOf("l3"), 0, "an unforked chain has a head");
    }
}

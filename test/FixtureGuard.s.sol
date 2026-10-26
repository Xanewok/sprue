// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";

import {TokenUnit, VaultGraph} from "./VaultGraph.sol";

/// @notice `forge script test/FixtureGuard.s.sol`: the test-only entry points refuse a script, which a
///         `forge test` cannot show.
contract FixtureGuard is Script {
    function run() external {
        VaultGraph graph = new VaultGraph();
        try graph.fixtureRun("none", "token.deploy", false) {
            revert("fixtureRun ran in a script");
        } catch Error(string memory reason) {
            require(_same(reason, "only a test runs a fixture"), reason);
        }
        TokenUnit unit = new TokenUnit();
        try unit.trustTestCreationAt(address(1), hex"01") {
            revert("trustTestCreationAt ran in a script");
        } catch Error(string memory reason) {
            require(_same(reason, "only a test trusts creations"), reason);
        }
    }

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

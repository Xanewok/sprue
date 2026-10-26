// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {Role, create} from "../src/Roles.sol";
import {Unit} from "../src/Unit.sol";
import {Step} from "../src/graph/Step.sol";

/// @dev A `Unit` on this repository's `sprue.json`, which `ToyJournal` replaces.
contract GasToy is Unit {
    function steps() external view returns (Step[] memory s) {
        s = new Step[](1);
        s[0] = _step("gastoy.deploy", this.deploy);
    }

    function deploy(string calldata network) external step(network) {
        _deploy(toy());
    }

    function read(string calldata network) external step(network) {
        _at(toy());
    }

    function toy() internal pure returns (Role memory) {
        return create("toy", "ToyPayload").args(abi.encode(uint256(1)));
    }

    function _roles() internal pure override returns (Role[] memory) {
        return _list(toy());
    }

    function _unit() internal pure override returns (string memory) {
        return "gastoy";
    }
}

contract UnitGasTest is Test {
    /// @dev A probe runs under the node's block gas limit, so a unit's steps must stay far below it.
    ///      Validating `sprue.json` on every read cost 1.8M here.
    function test_at_inAFreshStep_costsUnder600kGas() public {
        vm.chainId(31337);
        address ops = makeAddr("ops");
        string memory net = "rehearsal-gas";
        string memory dir = string.concat("deployments/", net);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(dir, true);
        vm.writeFile(
            string.concat(dir, "/network.json"),
            string.concat('{"chains":{"l2":{"id":31337}},"deployer":"', vm.toString(ops), '"}')
        );
        GasToy deployer = new GasToy();
        deployer.setTestSender(ops);
        deployer.deploy(net);
        GasToy reader = new GasToy();
        reader.setTestSender(ops);
        reader.trustTestCreations();

        uint256 before = gasleft();
        reader.read(net);
        assertLt(before - gasleft(), 600_000);
        vm.removeDir(dir, true);
    }
}

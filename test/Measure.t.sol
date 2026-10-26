// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";

import {Probes} from "../src/Probes.sol";
import {GasToy} from "./UnitGas.t.sol";

contract MeasureTest is Test {
    function test_measure() public {
        vm.chainId(31337);
        address ops = makeAddr("ops");
        string memory net = "rehearsal-measure";
        string memory dir = string.concat("deployments/", net);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(dir, true);
        vm.writeFile(
            string.concat(dir, "/network.json"),
            string.concat('{"chains":{"l2":{"id":31337}},"deployer":"', vm.toString(ops), '"}')
        );
        uint256 g = gasleft();
        GasToy deployer = new GasToy();
        console.log("MEASURE create gas", g - gasleft());
        deployer.setTestSender(ops);
        g = gasleft();
        assertTrue(Probes.due(address(deployer), abi.encodeCall(GasToy.deploy, (net)), ops));
        console.log("MEASURE deploy probe gas", g - gasleft());
        deployer.deploy(net);
        GasToy reader = new GasToy();
        reader.setTestSender(ops);
        reader.trustTestCreations();
        g = gasleft();
        reader.read(net);
        console.log("MEASURE _at step gas", g - gasleft());
        vm.removeDir(dir, true);
    }
}

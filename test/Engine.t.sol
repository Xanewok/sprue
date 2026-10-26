// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {Ctx, ENGINE, engine} from "../src/SprueEngine.sol";
import {Probes} from "../src/Probes.sol";
import {GasToy} from "./UnitGas.t.sol";

/// @dev A guard that a test calls from outside a unit, on whichever fork is selected.
contract EngineCaller {
    function hasRecoverStep() external view returns (bool) {
        Ctx memory c;
        c.script = "test/ToyUnit.sol";
        return engine().hasRecoverStep(c);
    }
}

contract EngineTest is Test {
    function _network(string memory net) private returns (address ops, string memory dir) {
        vm.chainId(31337);
        ops = makeAddr("ops");
        dir = string.concat("deployments/", net);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(dir, true);
        vm.writeFile(
            string.concat(dir, "/network.json"),
            string.concat('{"chains":{"l2":{"id":31337}},"deployer":"', vm.toString(ops), '"}')
        );
    }

    /// @dev Placed code is a cache of the build: a probe that places it and reverts changes no unit state, and the
    ///      next call places it again whether or not the revert kept it.
    function test_probe_placesTheEngineOnDemand_andKeepsNoUnitState() public {
        (address ops, string memory dir) = _network("rehearsal-engine-probe");
        GasToy unit = new GasToy();
        unit.setTestSender(ops);
        vm.etch(ENGINE, "");
        assertEq(ENGINE.code.length, 0);
        assertTrue(Probes.due(address(unit), abi.encodeCall(GasToy.deploy, ("rehearsal-engine-probe")), ops));
        emit log_named_uint("engine code after the probe", ENGINE.code.length);
        assertFalse(vm.exists(string.concat(dir, "/gastoy.json")), "a probe wrote the journal");
        assertEq(ops.balance, 0);
        vm.etch(ENGINE, "");
        unit.deploy("rehearsal-engine-probe");
        assertGt(ENGINE.code.length, 0, "a send does not place the engine");
        vm.removeDir(dir, true);
    }

    /// @dev A test that has two forks at hand sets `ENGINE_FORK_A` and `ENGINE_FORK_B` to their URLs.
    function test_engine_survivesAForkSwitch() public {
        string memory a = vm.envOr("ENGINE_FORK_A", string(""));
        string memory b = vm.envOr("ENGINE_FORK_B", string(""));
        if (bytes(a).length == 0 || bytes(b).length == 0) return;
        uint256 first = vm.createFork(a);
        uint256 second = vm.createFork(b);
        vm.selectFork(first);
        EngineCaller caller = new EngineCaller();
        vm.makePersistent(address(caller));
        assertTrue(caller.hasRecoverStep());
        uint256 id = block.chainid;
        vm.selectFork(second);
        assertTrue(block.chainid != id, "the forks serve one chain");
        assertGt(ENGINE.code.length, 0, "the engine is gone after the switch");
        assertTrue(caller.hasRecoverStep());
        vm.selectFork(first);
        assertTrue(caller.hasRecoverStep());
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {Role, create} from "../src/Roles.sol";
import {Unit} from "../src/Unit.sol";
import {Step} from "../src/graph/Step.sol";
import {Probes} from "../src/Probes.sol";
import {RolesToy} from "./Roles.t.sol";

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

    /// @dev This repository has no `paths.units` directory for it.
    function _deployScript() internal pure override returns (string memory) {
        return "test/UnitGas.t.sol";
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

    /// @dev A journal without `toyTx` sends the proof to the broadcast records. Other scripts' records, which
    ///      grow with every unit and run, must not raise its cost: 24 files of 100 kB cost a probe 31M.
    function test_at_withoutAJournaledTx_costsUnder1MGasWhateverOtherScriptsRecorded() public {
        vm.chainId(31337);
        address ops = makeAddr("ops");
        string memory net = "roles-gas-records";
        string memory dir = string.concat("cache/core-test/deployments/", net);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(string.concat(dir, "/broadcast/DeployOther.s.sol/31337"), true);
        vm.writeFile(
            string.concat(dir, "/network.json"),
            string.concat('{"chains":{"main":{"rpc":"main","id":31337}},"deployer":"', vm.toString(ops), '"}')
        );
        RolesToy deployer = new RolesToy();
        deployer.setTestSender(ops);
        deployer.deploy(net);
        string memory receipts = _receipts(250);
        for (uint256 i; i < 24; ++i) {
            vm.writeFile(
                string.concat(dir, "/broadcast/DeployOther.s.sol/31337/run-", vm.toString(i), ".json"), receipts
            );
        }
        RolesToy reader = new RolesToy();
        reader.setTestSender(ops);
        reader.trustTestCreations();

        uint256 before = gasleft();
        reader.atToy(net);
        assertLt(before - gasleft(), 1_000_000);
        vm.removeDir(dir, true);
    }

    /// @dev About 100 kB: `n` receipts of another script's run, none of the role's address.
    function _receipts(uint256 n) private pure returns (string memory json) {
        string memory one =
            '{"transactionHash":"0x1111111111111111111111111111111111111111111111111111111111111111","contractAddress":"0x2222222222222222222222222222222222222222","to":null,"blockNumber":"0x1","logs":[{"address":"0x3333333333333333333333333333333333333333","data":"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"}]}';
        json = '{"chain":31337,"transactions":[],"receipts":[';
        for (uint256 i; i < n; ++i) {
            json = string.concat(json, i == 0 ? "" : ",", one);
        }
        json = string.concat(json, "]}");
    }

    /// @dev A role the journal lacks sends its deploy step to the stray guard, which reads every script's
    ///      records on this chain: its gas must grow no faster than their size.
    function test_deployProbe_ofAnUnjournaledRole_costsUnder5MGasWithTwoDozenRecords() public {
        vm.chainId(31337);
        address ops = makeAddr("ops");
        string memory net = "roles-gas-stray";
        string memory dir = string.concat("cache/core-test/deployments/", net);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(string.concat(dir, "/broadcast/DeployOther.s.sol/31337"), true);
        vm.writeFile(
            string.concat(dir, "/network.json"),
            string.concat('{"chains":{"main":{"rpc":"main","id":31337}},"deployer":"', vm.toString(ops), '"}')
        );
        string memory run = _creates(20);
        for (uint256 i; i < 24; ++i) {
            vm.writeFile(string.concat(dir, "/broadcast/DeployOther.s.sol/31337/run-", vm.toString(i), ".json"), run);
        }
        RolesToy unit = new RolesToy();
        unit.setTestSender(ops);

        uint256 before = gasleft();
        assertTrue(Probes.due(address(unit), abi.encodeCall(RolesToy.deploy, (net)), ops));
        assertLt(before - gasleft(), 5_000_000);
        vm.removeDir(dir, true);
    }

    /// @dev About 160 kB: `n` CREATEs of another contract, each with 8 kB of initcode.
    function _creates(uint256 n) private pure returns (string memory json) {
        bytes memory input = new bytes(8000);
        for (uint256 k; k < input.length; ++k) {
            input[k] = "a";
        }
        string memory one = string.concat(
            '{"transactionType":"CREATE","contractName":"Other","contractAddress":"0x2222222222222222222222222222222222222222","transaction":{"from":"0x3333333333333333333333333333333333333333","nonce":"0x1","input":"0x',
            string(input),
            '"}}'
        );
        json = '{"chain":31337,"transactions":[';
        for (uint256 i; i < n; ++i) {
            json = string.concat(json, i == 0 ? "" : ",", one);
        }
        json = string.concat(json, '],"receipts":[]}');
    }
}

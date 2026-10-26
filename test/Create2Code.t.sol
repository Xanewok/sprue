// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {requireCode} from "../src/DeployChecks.sol";
import {ToyPayload} from "./ToyPayload.sol";
import {ToyUnit} from "./ToyUnit.sol";

contract CodeCaller {
    function check(address addr, bytes32[] calldata immutables) external view {
        requireCode(addr, "ToyPayload", immutables);
    }
}

contract Create2Unit is ToyUnit {
    function requireAddress(bytes32 salt, bytes memory args, address addr) external view {
        _requireCreate2Address(salt, "ToyPayload", args, addr);
    }

    function recordReceipt(string calldata network, address deployed) external {
        _recordCreate2Receipt(_use(network), "toy", deployed);
    }

    bool public refuseBuild;

    function setRefuseBuild(bool refuse) external {
        refuseBuild = refuse;
    }

    function _requireBuild(address addr, string memory artifact) internal view override {
        require(!refuseBuild, "the build check refused");
        super._requireBuild(addr, artifact);
    }

    /// @dev Only a factory call creates here.
    function _createdIn(bytes32 hash, address, bool create2) internal view override returns (uint256) {
        return confirmed[hash] && create2 ? 5 : 0;
    }
}

/// @notice `requireCode` and the CREATE2 helpers, which `_deployRole` does not reach.
contract Create2CodeTest is Test {
    address private constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes private constant FACTORY_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    string private constant DIR = "cache/core-test/deployments/";

    function _words(uint256 v) private pure returns (bytes32[] memory w) {
        w = new bytes32[](1);
        w[0] = bytes32(v);
    }

    function test_requireCode_acceptsTheArtifactWithItsImmutablesAndRefusesAnythingElse() public {
        CodeCaller caller = new CodeCaller();
        address deployed = address(new ToyPayload(7));
        caller.check(deployed, _words(7));

        vm.expectRevert(bytes(string.concat(vm.toString(deployed), " is not ToyPayload.sol:ToyPayload")));
        caller.check(deployed, _words(8));

        vm.expectRevert(bytes("ToyPayload.sol:ToyPayload has another number of immutables"));
        caller.check(deployed, new bytes32[](0));

        address other = address(new CodeCaller());
        vm.expectRevert(bytes(string.concat(vm.toString(other), " is not ToyPayload.sol:ToyPayload")));
        caller.check(other, _words(7));
    }

    function test_requireCreate2Address_needsTheFactoryAndTheComputedAddress() public {
        Create2Unit unit = new Create2Unit();
        bytes memory args = abi.encode(uint256(3));
        bytes32 salt = bytes32(uint256(1));
        address expected = vm.computeCreate2Address(
            salt, keccak256(bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), args)), FACTORY
        );

        vm.etch(FACTORY, "");
        vm.expectRevert(
            bytes(string.concat("this chain has no CREATE2 factory at ", vm.toString(FACTORY), ": opt out of create2"))
        );
        unit.requireAddress(salt, args, expected);

        vm.etch(FACTORY, FACTORY_CODE);
        unit.requireAddress(salt, args, expected);

        vm.expectRevert();
        unit.requireAddress(bytes32(uint256(2)), args, expected);
        vm.expectRevert();
        unit.requireAddress(salt, abi.encode(uint256(4)), expected);
    }

    function test_deployRoleCreate2_sendsOnce_adoptsItsOwnLandedRole_andRefusesAnyOther() public {
        Create2Unit unit = new Create2Unit();
        address ops = makeAddr("ops");
        unit.setTestSender(ops);
        string memory net = "create2-deploy";
        string memory dir = string.concat(DIR, net);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(dir, true);
        vm.writeFile(string.concat(dir, "/network.json"), '{"chains": {"main": {"id": 31337}}}');
        vm.chainId(31337);
        vm.etch(FACTORY, FACTORY_CODE);
        bytes32 salt = bytes32(uint256(1));
        address at = vm.computeCreate2Address(
            salt, keccak256(bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(uint256(1)))), FACTORY
        );
        string memory path = string.concat(dir, "/toy.json");

        assertTrue(unit.deploy2(net, salt, at), "the first run did not send");
        assertEq(ToyPayload(at).tag(), 1);
        assertEq(vm.parseJsonAddress(vm.readFile(path), ".toy"), at);
        assertEq(vm.parseJsonBytes32(vm.readFile(path), ".toySalt"), salt);
        assertFalse(unit.deploy2(net, salt, at), "a rerun sent");

        unit.setRefuseReuse(true);
        vm.expectRevert(bytes("the check refused the reuse"));
        unit.deploy2(net, salt, at);
        unit.setRefuseReuse(false);
        vm.expectRevert(bytes("the input's create2.salt differs from toy.json's"));
        unit.deploy2(net, bytes32(uint256(2)), at);
        vm.expectRevert(bytes("toy.json's toy is not the input's create2.address: a person must resolve it"));
        unit.deploy2(net, salt, address(0xBEEF));

        string memory journal = vm.readFile(path);
        vm.removeFile(path);
        unit.setTag(2);
        vm.expectRevert(
            bytes(
                "the input's create2.address holds a toy that another build or input made: restore the journal, and never mine a new salt"
            )
        );
        unit.deploy2(net, salt, at);
        unit.setTag(1);
        unit.setRefuseReuse(true);
        vm.expectRevert(bytes("the check refused the reuse"));
        unit.deploy2(net, salt, at);
        assertFalse(vm.exists(path), "a refused adoption was journaled");
        unit.setRefuseReuse(false);
        assertFalse(unit.deploy2(net, salt, at), "an adoption sent");
        assertEq(vm.parseJsonAddress(vm.readFile(path), ".toy"), at);
        assertEq(vm.parseJsonBytes32(vm.readFile(path), ".toyCodeHash"), vm.parseJsonBytes32(journal, ".toyCodeHash"));
    }

    /// @dev The pin refuses before the factory call: forge keeps a reverted run's broadcasts in its dry run.
    function test_deployRoleCreate2_refusesAnotherDeployerThanThePin_beforeTheFactoryCall() public {
        Create2Unit unit = new Create2Unit();
        address ops = makeAddr("ops");
        address pin = makeAddr("pin");
        unit.setTestSender(ops);
        string memory net = "create2-checks";
        string memory dir = string.concat(DIR, net);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(dir, true);
        string memory networkJson = string.concat(dir, "/network.json");
        vm.writeFile(
            networkJson, string.concat('{"chains": {"main": {"id": 31337}}, "deployer": "', vm.toString(pin), '"}')
        );
        vm.chainId(31337);
        vm.etch(FACTORY, FACTORY_CODE);
        bytes32 salt = bytes32(uint256(1));
        address at = vm.computeCreate2Address(
            salt, keccak256(bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(uint256(1)))), FACTORY
        );

        vm.expectCall(FACTORY, "", 0);
        vm.expectRevert(
            bytes(
                string.concat(
                    vm.toString(ops),
                    " is not ",
                    dir,
                    "/network.json's deployer ",
                    vm.toString(pin),
                    ": run with that key, or pass --unsafe-unexpected-deployer to sprue (UNSAFE_UNEXPECTED_DEPLOYER=1 for forge) to deploy with another"
                )
            )
        );
        unit.deploy2(net, salt, at);
    }

    function test_deployRoleCreate2_checksTheRecordedCode_andTheAdoptedBuild() public {
        Create2Unit unit = new Create2Unit();
        unit.setTestSender(makeAddr("ops"));
        string memory net = "create2-proofs";
        string memory dir = string.concat(DIR, net);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(dir, true);
        vm.writeFile(string.concat(dir, "/network.json"), '{"chains": {"main": {"id": 31337}}}');
        vm.chainId(31337);
        vm.etch(FACTORY, FACTORY_CODE);
        bytes32 salt = bytes32(uint256(1));
        address at = vm.computeCreate2Address(
            salt, keccak256(bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(uint256(1)))), FACTORY
        );
        string memory path = string.concat(dir, "/toy.json");

        assertTrue(unit.deploy2(net, salt, at), "the first run did not send");
        string memory journal = vm.readFile(path);
        vm.writeJson(vm.toString(bytes32(uint256(1))), path, ".toyCodeHash");
        vm.expectRevert(bytes("toy's code differs from toy.json"));
        unit.deploy2(net, salt, at);

        vm.removeFile(path);
        unit.setRefuseBuild(true);
        vm.expectRevert(bytes("the build check refused"));
        unit.deploy2(net, salt, at);
        assertFalse(vm.exists(path), "an adoption journaled an unproven build");
        unit.setRefuseBuild(false);
        assertFalse(unit.deploy2(net, salt, at), "an adoption sent");
        assertEq(vm.parseJsonBytes32(vm.readFile(path), ".toyCodeHash"), vm.parseJsonBytes32(journal, ".toyCodeHash"));
    }

    function test_recordCreate2Receipt_takesOnlyAReceiptOfACallToTheFactory() public {
        Create2Unit unit = new Create2Unit();
        string memory net = "create2-receipt";
        string memory dir = string.concat(DIR, net);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(string.concat(dir, "/broadcast/ToyUnit.sol/1"), true);
        vm.writeFile(string.concat(dir, "/network.json"), '{"chains": {"main": {"id": 31337}}}');
        vm.chainId(31337);
        bytes32 toFactory = keccak256("to the factory");
        bytes32 toOther = keccak256("to another contract");
        vm.writeFile(
            string.concat(dir, "/broadcast/ToyUnit.sol/1/run-latest.json"),
            string.concat(
                '{"receipts": [{"to": "',
                vm.toLowercase(vm.toString(FACTORY)),
                '", "transactionHash": "',
                vm.toString(toFactory),
                '"}, {"to": "0x000000000000000000000000000000000000dead", "transactionHash": "',
                vm.toString(toOther),
                '"}]}'
            )
        );
        address deployed = makeAddr("deployed");

        unit.confirm(toOther);
        unit.recordReceipt(net, deployed);
        assertFalse(vm.exists(string.concat(dir, "/toy.json")), "a receipt of another call was taken");

        unit.confirm(toFactory);
        unit.recordReceipt(net, deployed);
        string memory journal = vm.readFile(string.concat(dir, "/toy.json"));
        assertEq(vm.parseJsonBytes32(journal, ".toyTx"), toFactory);
        assertEq(vm.parseJsonUint(journal, ".toyBlock"), 5);

        vm.writeJson(vm.toString(deployed), string.concat(dir, "/toy.json"), ".toy");
        bytes memory initcode = bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(uint256(3)));
        unit.send(bytes.concat(bytes32(uint256(1)), initcode));
        assertEq(unit.findCreationInput(net), initcode, "the creation input is the initcode after the salt");
    }
}

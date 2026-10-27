// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {Role, child, create, runtime} from "../src/Roles.sol";
import {Probes} from "../src/Probes.sol";
import {ParentPayload} from "./ParentPayload.sol";
import {ToyJournal} from "./ToyUnit.sol";

function PARENT() pure returns (Role memory) {
    return create("parent", "ParentPayload");
}

function TABLER() pure returns (Role memory) {
    return create("tabler", "ReturnsTable");
}

/// @dev A parent whose constructor creates `kid`, and one whose constructor returns `table`'s program.
contract ChildrenToy is ToyJournal {
    bool public undeclared;
    string public kidArtifact = "ChildPayload";
    string public programArtifact = "TablePayload";
    bytes32 public confirmed;

    function setUndeclared(bool undeclared_) external {
        undeclared = undeclared_;
    }

    function setArtifacts(string calldata kid_, string calldata table_) external {
        (kidArtifact, programArtifact) = (kid_, table_);
    }

    function confirm(bytes32 hash) external {
        confirmed = hash;
    }

    function kid() internal view returns (Role memory) {
        return child("kid", kidArtifact, PARENT(), "CHILD()");
    }

    function table() internal view returns (Role memory) {
        return runtime("table", programArtifact, TABLER());
    }

    function deploy(string calldata network) external step(network) {
        _deploy(PARENT());
        _deploy(TABLER());
    }

    function deployKid(string calldata network) external step(network) {
        _deploy(kid());
    }

    function check(string calldata network) external step(network) {
        _at(PARENT());
        _at(TABLER());
        _endCheck();
    }

    function atKid(string calldata network) external returns (address a) {
        _use(network);
        a = _at(kid());
        _done(false);
    }

    function _creationBlock(bytes32 hash, address, bool create2) internal view override returns (uint256, bytes32) {
        if (hash != confirmed || create2) return (0, 0);
        return (5, 0);
    }

    function _roles() internal view override returns (Role[] memory) {
        if (undeclared) return _list(PARENT(), TABLER(), table());
        return _list(PARENT(), kid(), TABLER(), table());
    }

    function _unit() internal pure override returns (string memory) {
        return "children";
    }
}

/// @dev Another unit, which reads `kid` from the children unit's journal.
contract ChildReader is ToyJournal {
    function read(string calldata network) external returns (address a) {
        _use(network);
        a = _at(child("kid", "ChildPayload", PARENT(), "CHILD()").unit("children"));
        _done(false);
    }

    function _unit() internal pure override returns (string memory) {
        return "child-reader";
    }
}

contract ChildrenTest is Test {
    address private ops = makeAddr("ops");
    ChildrenToy private unit = new ChildrenToy();
    string private network;
    string private dir;

    function _network(string memory name) private {
        vm.chainId(31337);
        network = string.concat("children-", name);
        dir = string.concat("cache/core-test/deployments/", network);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(dir, true);
        unit.setTestSender(ops);
        vm.writeFile(
            string.concat(dir, "/network.json"),
            string.concat('{"chains":{"main":{"rpc":"main","id":31337}},"deployer":"', vm.toString(ops), '"}')
        );
    }

    function _journal() private view returns (string memory) {
        return vm.readFile(string.concat(dir, "/children.json"));
    }

    function _set(string memory key, string memory value) private {
        vm.writeJson(value, string.concat(dir, "/children.json"), key);
    }

    function test_deploy_recordsAChild_asARole_withoutACommitOfItsOwn() public {
        _network("record");
        unit.deploy(network);

        string memory journal = _journal();
        address kid = address(ParentPayload(vm.parseJsonAddress(journal, ".parent")).CHILD());
        assertEq(vm.parseJsonAddress(journal, ".kid"), kid);
        assertEq(vm.parseJsonBytes32(journal, ".kidCodeHash"), kid.codehash);
        assertFalse(vm.keyExistsJson(journal, ".kidCommit"));
        string memory metadata = vm.parseJsonString(journal, ".kidMetadata");
        assertTrue(vm.contains(metadata, "ChildPayload.metadata.json"), metadata);
        assertTrue(vm.exists(metadata));
    }

    function test_deploy_recordsARuntime_atItsParentsAddress_withTheProgramsMetadata() public {
        _network("runtime");
        unit.deploy(network);

        string memory journal = _journal();
        address tabler = vm.parseJsonAddress(journal, ".tabler");
        assertEq(vm.parseJsonAddress(journal, ".table"), tabler);
        assertEq(vm.parseJsonBytes32(journal, ".tableCodeHash"), tabler.codehash);
        assertTrue(vm.contains(vm.parseJsonString(journal, ".tableMetadata"), "TablePayload.metadata.json"));
        assertTrue(vm.contains(vm.parseJsonString(journal, ".tablerMetadata"), "ReturnsTable.metadata.json"));
    }

    /// @dev A record written before the unit declared the child.
    function _deployWithoutKid() private {
        unit.setUndeclared(true);
        unit.deploy(network);
        unit.setUndeclared(false);
        assertFalse(vm.keyExistsJson(_journal(), ".kid"));
    }

    function test_check_recordsTheChildOfAnOlderRecord_andIsDueUntilThen() public {
        _network("due");
        _deployWithoutKid();
        assertTrue(Probes.due(address(unit), abi.encodeCall(ChildrenToy.check, (network)), ops));
        unit.check(network);
        assertEq(
            vm.parseJsonAddress(_journal(), ".kid"),
            address(ParentPayload(vm.parseJsonAddress(_journal(), ".parent")).CHILD())
        );
        assertFalse(Probes.due(address(unit), abi.encodeCall(ChildrenToy.check, (network)), ops));
    }

    function test_check_refusesARecordedChildItsParentNoLongerNames() public {
        _network("moved");
        unit.deploy(network);
        unit.check(network);
        _set(".kid", vm.toString(makeAddr("elsewhere")));
        vm.expectRevert(bytes("kid is no longer the contract the journal records: a person must resolve it"));
        unit.check(network);
    }

    function test_at_refusesAChildWhoseCodeIsNotItsArtifact() public {
        _network("other-code");
        _deployWithoutKid();
        unit.setArtifacts("TablePayload", "TablePayload");
        address kid = address(ParentPayload(vm.parseJsonAddress(_journal(), ".parent")).CHILD());
        vm.expectRevert(bytes(string.concat(vm.toString(kid), " is not TablePayload.sol:TablePayload")));
        unit.atKid(network);
    }

    function test_deploy_refusesARuntimeWhoseParentRunsAnotherProgram() public {
        _network("other-program");
        unit.setArtifacts("ChildPayload", "ChildPayload");
        vm.expectRevert(bytes("tabler's code does not start with ChildPayload's program"));
        unit.deploy(network);
    }

    function test_deploy_refusesAChild() public {
        _network("deploy-child");
        vm.expectRevert(bytes("kid is parent's: deploy parent"));
        unit.deployKid(network);
    }

    function test_at_anotherUnitReadsTheRecordedChild() public {
        _network("reader");
        unit.deploy(network);
        unit.check(network);
        ChildReader reader = new ChildReader();
        reader.setTestSender(ops);
        assertEq(reader.read(network), vm.parseJsonAddress(_journal(), ".kid"));
        _set(".kid", vm.toString(makeAddr("elsewhere")));
        vm.expectRevert(bytes("kid is no longer the contract the journal records: a person must resolve it"));
        reader.read(network);
    }

    // ==== Detection ====

    /// @dev A broadcast record of the parent's creation, listing what its constructor also created.
    function _recordParentCreation(address also) private returns (bytes32 hash) {
        hash = keccak256("the parent's creation");
        unit.confirm(hash);
        address parent = vm.parseJsonAddress(_journal(), ".parent");
        string memory chainDir = string.concat(dir, "/broadcast/ToyUnit.sol/", vm.toString(block.chainid));
        vm.createDir(chainDir, true);
        vm.writeFile(
            string.concat(chainDir, "/deploy-latest.json"),
            string.concat(
                '{"chain": 31337, "transactions": [{"hash": "',
                vm.toString(hash),
                '", "additionalContracts": [{"transactionType": "CREATE", "address": "',
                vm.toString(also),
                '"}]}], "receipts": [{"contractAddress": "',
                vm.toLowercase(vm.toString(parent)),
                '", "transactionHash": "',
                vm.toString(hash),
                '", "blockNumber": "0x5"}], "commit": "def456"}'
            )
        );
    }

    function test_receipt_ofACreationThatMadeAnUndeclaredContract_isRefused() public {
        _network("undeclared");
        unit.setUndeclared(true);
        unit.deploy(network);
        address kid = address(ParentPayload(vm.parseJsonAddress(_journal(), ".parent")).CHILD());
        _recordParentCreation(kid);
        vm.expectRevert(
            bytes(
                string.concat(
                    "parent's creation also created ",
                    vm.toString(kid),
                    ": declare it in _roles() as child(name, artifact, parent, getter)"
                )
            )
        );
        unit.check(network);
        assertFalse(vm.keyExistsJson(_journal(), ".parentTx"));
    }

    function test_receipt_ofACreationWhoseContractsAreDeclared_recordsThem() public {
        _network("declared");
        unit.deploy(network);
        address kid = address(ParentPayload(vm.parseJsonAddress(_journal(), ".parent")).CHILD());
        bytes32 hash = _recordParentCreation(kid);
        unit.check(network);
        string memory journal = _journal();
        assertEq(vm.parseJsonBytes32(journal, ".parentTx"), hash);
        assertEq(vm.parseJsonAddress(journal, ".kid"), kid);
        assertEq(vm.parseJsonString(journal, ".parentCommit"), "def456");
    }
}

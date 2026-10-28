// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {Role, child, create, create2, extern, runtime} from "../src/Roles.sol";
import {Probes} from "../src/Probes.sol";
import {NestPayload} from "./NestPayload.sol";
import {ParentPayload} from "./ParentPayload.sol";
import {StoragePayload} from "./StoragePayload.sol";
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
        return child("kid", kidArtifact, PARENT(), ParentPayload(address(0)).CHILD.selector);
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

    function atKidThenAsExtern(string calldata network) external step(network) {
        _at(PARENT());
        _at(kid());
        _at(extern("kid", "kid", bytes32(0)));
    }

    function atParentAsCreate2(string calldata network) external returns (address a) {
        _use(network);
        a = _at(create2("parent", "ParentPayload", ""));
        _done(false);
    }

    function recover(string calldata network) external returns (string memory) {
        return _recoverRoles(network);
    }

    function childWithArgs() external view {
        kid().args(abi.encode(uint256(3)));
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

/// @dev A child of a child: `nest` creates `mid`, which creates `leaf`.
contract NestToy is ToyJournal {
    function nest() internal pure returns (Role memory) {
        return create("nest", "NestPayload");
    }

    function mid() internal view returns (Role memory) {
        return child("mid", "ParentPayload", nest(), NestPayload(address(0)).PARENT.selector);
    }

    bytes32 public confirmed;

    function confirm(bytes32 hash) external {
        confirmed = hash;
    }

    function deploy(string calldata network) external step(network) {
        _deploy(nest());
    }

    function _creationBlock(bytes32 hash, address, bool create2) internal view override returns (uint256, bytes32) {
        if (hash != confirmed || create2) return (0, 0);
        return (5, 0);
    }

    function check(string calldata network) external step(network) {
        _at(nest());
        _endCheck();
    }

    function _roles() internal view override returns (Role[] memory) {
        return _list(nest(), mid(), child("leaf", "ChildPayload", mid(), ParentPayload(address(0)).CHILD.selector));
    }

    function _unit() internal pure override returns (string memory) {
        return "nest";
    }
}

/// @dev A child that its parent keeps in storage, not in an immutable.
contract StorageToy is ToyJournal {
    function store() internal pure returns (Role memory) {
        return create("store", "StoragePayload");
    }

    function deploy(string calldata network) external step(network) {
        _deploy(store());
    }

    function _roles() internal view override returns (Role[] memory) {
        return _list(store(), child("kept", "ChildPayload", store(), StoragePayload(address(0)).child.selector));
    }

    function _unit() internal pure override returns (string memory) {
        return "store";
    }
}

/// @dev Another unit, which reads `leaf` from the nest unit's journal.
contract LeafReader is ToyJournal {
    function read(string calldata network) external returns (address a) {
        _use(network);
        Role memory mid =
            child("mid", "ParentPayload", create("nest", "NestPayload"), NestPayload(address(0)).PARENT.selector);
        a = _at(child("leaf", "ChildPayload", mid, ParentPayload(address(0)).CHILD.selector).unit("nest"));
        _done(false);
    }

    function _unit() internal pure override returns (string memory) {
        return "leaf-reader";
    }
}

/// @dev Another unit, which reads `kid` from the children unit's journal.
contract ChildReader is ToyJournal {
    function read(string calldata network) external returns (address a) {
        _use(network);
        a = _at(child("kid", "ChildPayload", PARENT(), ParentPayload(address(0)).CHILD.selector).unit("children"));
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

    /// @dev As when the child landed with other code than the simulation that journaled it.
    function test_check_journalsAgainAChildRecordThatNoLongerDescribesIt() public {
        _network("stale");
        unit.deploy(network);
        address kid = vm.parseJsonAddress(_journal(), ".kid");
        _set(".kid", vm.toString(makeAddr("elsewhere")));
        assertTrue(Probes.due(address(unit), abi.encodeCall(ChildrenToy.check, (network)), ops));
        unit.check(network);
        assertEq(vm.parseJsonAddress(_journal(), ".kid"), kid);
        assertFalse(Probes.due(address(unit), abi.encodeCall(ChildrenToy.check, (network)), ops));
    }

    function test_deploy_ofAnOlderParent_leavesItsNewChildToCheck() public {
        _network("older-parent");
        _deployWithoutKid();
        string memory journal = _journal();
        assertFalse(Probes.due(address(unit), abi.encodeCall(ChildrenToy.deploy, (network)), ops));
        unit.deploy(network);
        assertEq(_journal(), journal);
    }

    function test_at_refusesARoleOtherThanItsDeclaration_evenOnceTheNameIsProven() public {
        _network("other-declaration-cached");
        unit.deploy(network);
        vm.expectRevert(bytes("kid differs from its declaration in children's _roles()"));
        unit.atKidThenAsExtern(network);
    }

    function test_at_ofAnotherUnitsChildOfAChild_isRefusedByName() public {
        _network("leaf-reader");
        NestToy nest = new NestToy();
        nest.setTestSender(ops);
        nest.deploy(network);
        LeafReader reader = new LeafReader();
        reader.setTestSender(ops);
        vm.expectRevert(bytes("another unit reads only a child of a CREATE or CREATE2 role, and mid is not"));
        reader.read(network);
    }

    function test_at_refusesARoleOfAnotherKind() public {
        _network("other-kind");
        unit.deploy(network);
        vm.expectRevert(bytes("parent differs from its declaration in children's _roles()"));
        unit.atParentAsCreate2(network);
    }

    function test_receipt_inAMultiChainRecord_readsOnlyTheSelectedChainsCreation() public {
        _network("multi");
        unit.deploy(network);
        address parent = vm.parseJsonAddress(_journal(), ".parent");
        address kid = vm.parseJsonAddress(_journal(), ".kid");
        bytes32 hash = keccak256("the parent's creation");
        unit.confirm(hash);
        string memory run = string.concat(dir, "/broadcast/multi/ToyUnit.sol-1");
        vm.createDir(run, true);
        string memory here = string.concat(
            '{"chain": 31337, "transactions": [{"transactionType": "CREATE", "contractAddress": "',
            vm.toLowercase(vm.toString(parent)),
            '", "additionalContracts": [{"address": "',
            vm.toString(kid),
            '"}]}], "receipts": [{"contractAddress": "',
            vm.toLowercase(vm.toString(parent)),
            '", "transactionHash": "',
            vm.toString(hash),
            '", "blockNumber": "0x5"}]}'
        );
        // The same deployer and nonce made the parent on another chain, whose child is elsewhere.
        string memory there = string.concat(
            '{"chain": 999, "transactions": [{"transactionType": "CREATE", "contractAddress": "',
            vm.toLowercase(vm.toString(parent)),
            '", "additionalContracts": [{"address": "',
            vm.toString(makeAddr("the other chain's child")),
            '"}]}], "receipts": []}'
        );
        vm.writeFile(string.concat(run, "/deploy.json"), string.concat('{"deployments": [', there, ", ", here, "]}"));
        unit.check(network);
        assertEq(vm.parseJsonBytes32(_journal(), ".parentTx"), hash);
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
        address tabler = vm.computeCreateAddress(ops, vm.getNonce(ops) + 1);
        vm.expectRevert(bytes(string.concat(vm.toString(tabler), "'s code does not start with ChildPayload's program")));
        unit.deploy(network);
        assertFalse(vm.keyExistsJson(_journal(), ".tabler"));
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
        _set(".parentNonce", "99");
        vm.expectRevert(bytes("parent's address is not its recorded deployer's CREATE at its recorded nonce"));
        reader.read(network);
    }

    // ==== Detection ====

    /// @dev A broadcast record of `parent`'s creation, listing what its constructor also created. Its
    ///      `transactions[]` hashes are swapped, as older forge versions wrote them: only `receipts[]` pairs a
    ///      hash with the created address.
    function _recordCreation(address parent, address[] memory also) private returns (bytes32 hash) {
        hash = keccak256("the parent's creation");
        string memory listed;
        for (uint256 i; i < also.length; ++i) {
            listed = string.concat(listed, i == 0 ? "" : ", ", '{"address": "', vm.toString(also[i]), '"}');
        }
        string memory chainDir = string.concat(dir, "/broadcast/ToyUnit.sol/", vm.toString(block.chainid));
        vm.createDir(chainDir, true);
        // A later call to the parent that creates a contract, here one with code, is no constructor's child.
        string memory call = string.concat(
            '{"transactionType": "CALL", "contractAddress": "',
            vm.toLowercase(vm.toString(parent)),
            '", "additionalContracts": [{"address": "',
            vm.toString(address(this)),
            '"}]}'
        );
        string memory txs = string.concat(
            '{"chain": 31337, "transactions": [{"transactionType": "CREATE", "hash": "',
            vm.toString(keccak256("another creation")),
            '", "contractAddress": "',
            vm.toLowercase(vm.toString(parent)),
            '", "additionalContracts": [',
            listed,
            ']}, {"transactionType": "CREATE", "hash": "',
            vm.toString(hash),
            '", "contractAddress": "',
            vm.toLowercase(vm.toString(makeAddr("another"))),
            '", "additionalContracts": []}, ',
            call,
            "]"
        );
        string memory receipts = string.concat(
            ', "receipts": [{"contractAddress": "',
            vm.toLowercase(vm.toString(parent)),
            '", "transactionHash": "',
            vm.toString(hash),
            '", "blockNumber": "0x5"}], "commit": "def456"}'
        );
        vm.writeFile(string.concat(chainDir, "/deploy-latest.json"), string.concat(txs, receipts));
    }

    function _recordParentCreation(address also) private returns (bytes32 hash) {
        address[] memory list = new address[](1);
        list[0] = also;
        hash = _recordCreation(vm.parseJsonAddress(_journal(), ".parent"), list);
        unit.confirm(hash);
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
                    ": declare it in _roles(), such as child(\"child\", \"ChildPayload\", <the parent role>, ParentPayload(address(0)).CHILD.selector)"
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

    function test_receipt_ofACreationWhoseChildMadeAChild_coversBoth() public {
        _network("nest-receipt");
        NestToy nest = new NestToy();
        nest.setTestSender(ops);
        nest.deploy(network);
        string memory journal = vm.readFile(string.concat(dir, "/nest.json"));
        address[] memory also = new address[](2);
        (also[0], also[1]) = (vm.parseJsonAddress(journal, ".mid"), vm.parseJsonAddress(journal, ".leaf"));
        nest.confirm(_recordCreation(vm.parseJsonAddress(journal, ".nest"), also));
        nest.check(network);
        assertTrue(vm.keyExistsJson(vm.readFile(string.concat(dir, "/nest.json")), ".nestTx"));
    }

    function test_deploy_journalsAChildOfAChild() public {
        _network("nest");
        NestToy nest = new NestToy();
        nest.setTestSender(ops);
        nest.deploy(network);
        string memory journal = vm.readFile(string.concat(dir, "/nest.json"));
        address mid = address(NestPayload(vm.parseJsonAddress(journal, ".nest")).PARENT());
        assertEq(vm.parseJsonAddress(journal, ".mid"), mid);
        assertEq(vm.parseJsonAddress(journal, ".leaf"), address(ParentPayload(mid).CHILD()));
    }

    // ==== Recovery ====

    /// @dev Deletes the journal and writes forge's record of both parents' creations.
    function _loseTheJournal() private {
        _loseTheJournal("");
    }

    /// @dev `alsoCreated`: an `additionalContracts` entry for the parent's creation.
    function _loseTheJournal(string memory alsoCreated) private {
        string memory lost = _journal();
        vm.removeFile(string.concat(dir, "/children.json"));
        string memory records = string.concat(dir, "/broadcast/ChildrenToy.s.sol/records");
        vm.createDir(records, true);
        vm.writeFile(
            string.concat(records, "/0-latest.json"),
            string.concat(
                '{"chain": 31337, "transactions": [',
                _create(
                    "ParentPayload",
                    vm.parseJsonAddress(lost, ".parent"),
                    vm.parseJsonUint(lost, ".parentNonce"),
                    alsoCreated
                ),
                ", ",
                _create(
                    "ReturnsTable", vm.parseJsonAddress(lost, ".tabler"), vm.parseJsonUint(lost, ".tablerNonce"), ""
                ),
                "]}"
            )
        );
    }

    function _create(string memory name, address addr, uint256 nonce, string memory alsoCreated)
        private
        view
        returns (string memory)
    {
        return string.concat(
            '{"transactionType": "CREATE", "contractName": "',
            name,
            '", "contractAddress": "',
            vm.toLowercase(vm.toString(addr)),
            '", "additionalContracts": [',
            alsoCreated,
            '], "transaction": {"from": "',
            vm.toLowercase(vm.toString(ops)),
            '", "nonce": "',
            vm.toString(bytes32(nonce)),
            '", "input": "',
            vm.toString(vm.getCode(string.concat(name, ".sol:", name))),
            '"}}'
        );
    }

    function test_recover_journalsTheChildrenOfTheRolesItFinds() public {
        _network("recover");
        unit.deploy(network);
        address kid = vm.parseJsonAddress(_journal(), ".kid");
        _loseTheJournal();
        unit.recover(network);
        assertEq(vm.parseJsonAddress(_journal(), ".kid"), kid);
        assertEq(vm.parseJsonAddress(_journal(), ".table"), vm.parseJsonAddress(_journal(), ".tabler"));
    }

    function test_recover_refusingAChild_journalsNothing() public {
        _network("recover-refused");
        unit.deploy(network);
        address kid = vm.parseJsonAddress(_journal(), ".kid");
        _loseTheJournal();
        unit.setArtifacts("TablePayload", "TablePayload");
        vm.expectRevert(bytes(string.concat(vm.toString(kid), " is not TablePayload.sol:TablePayload")));
        unit.recover(network);
        assertFalse(vm.exists(string.concat(dir, "/children.json")));
    }

    function test_recover_ofACreationThatMadeAnUndeclaredContract_journalsNothing() public {
        _network("recover-undeclared");
        unit.setUndeclared(true);
        unit.deploy(network);
        address kid = address(ParentPayload(vm.parseJsonAddress(_journal(), ".parent")).CHILD());
        _loseTheJournal(string.concat('{"address": "', vm.toString(kid), '"}'));
        vm.expectRevert(
            bytes(
                string.concat(
                    "parent's creation also created ",
                    vm.toString(kid),
                    ": declare it in _roles(), such as child(\"child\", \"ChildPayload\", <the parent role>, ParentPayload(address(0)).CHILD.selector)"
                )
            )
        );
        unit.recover(network);
        assertFalse(vm.exists(string.concat(dir, "/children.json")));
    }

    function test_args_ofAChild_isRefused() public {
        vm.expectRevert(bytes("kid's constructor arguments are its parent's: drop .args"));
        unit.childWithArgs();
    }

    function test_receipt_ignoresACreatedAddressWithNoCode() public {
        _network("no-code");
        unit.deploy(network);
        address[] memory also = new address[](2);
        (also[0], also[1]) = (vm.parseJsonAddress(_journal(), ".kid"), makeAddr("a simulated address"));
        bytes32 hash = _recordCreation(vm.parseJsonAddress(_journal(), ".parent"), also);
        unit.confirm(hash);
        unit.check(network);
        assertEq(vm.parseJsonBytes32(_journal(), ".parentTx"), hash);
    }

    function test_deploy_refusesAChildThatItsParentKeepsInStorage() public {
        _network("storage");
        StorageToy store = new StorageToy();
        store.setTestSender(ops);
        vm.expectRevert(bytes("store's getter for kept does not return an immutable: read it with _at as an extern"));
        store.deploy(network);
    }
}

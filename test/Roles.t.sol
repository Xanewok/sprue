// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {Role, create, create2, extern} from "../src/Roles.sol";
import {Probes} from "../src/Probes.sol";
import {SecondPayload} from "./SecondPayload.sol";
import {ToyPayload} from "./ToyPayload.sol";
import {ToyJournal} from "./ToyUnit.sol";

/// @dev The toy role as another unit reads it.
function TOY() pure returns (Role memory) {
    return create("toy", "ToyPayload").unit("roles");
}

/// @dev Two CREATE roles, the second built on the first, a CREATE2 role and an extern one.
contract RolesToy is ToyJournal {
    uint256 public tag = 1;
    bool public refuse;
    bytes32 public externHash;
    uint256 public checks;
    bool public stop;

    function setTag(uint256 tag_) external {
        tag = tag_;
    }

    function setRefuse(bool refuse_) external {
        refuse = refuse_;
    }

    function setExternHash(bytes32 hash) external {
        externHash = hash;
    }

    function setStop(bool stop_) external {
        stop = stop_;
    }

    function toy() internal pure returns (Role memory) {
        return TOY().args(_toyArgs).check(_toyCheck);
    }

    function second() internal pure returns (Role memory) {
        return create("second", "SecondPayload").args(_secondArgs);
    }

    function hook() internal pure returns (Role memory) {
        return create2("hook", "ToyPayload", "create2").args(abi.encode(uint256(7)));
    }

    function ext() internal view returns (Role memory) {
        return extern("ext", "ext", externHash);
    }

    function deploy(string calldata network) external step(network) {
        _deploy(toy());
    }

    function deployBoth(string calldata network) external step(network) {
        _deploy(toy());
        if (stop) return;
        _deploy(second());
    }

    function deployHook(string calldata network) external step(network) {
        _deploy(hook());
    }

    function deployExt(string calldata network) external step(network) {
        _deploy(ext());
    }

    function check(string calldata network) external step(network) {
        _at(toy());
        _at(second());
        _certify();
    }

    function checkReversed(string calldata network) external step(network) {
        _at(second());
        _at(toy());
        _certify();
    }

    function checkToyOnly(string calldata network) external step(network) {
        _at(toy());
        _certify();
    }

    function checkWithFact(string calldata network) external step(network) {
        _at(toy());
        _at(second());
        _certify(_certificate().withUint("extra", 5));
    }

    function atToy(string calldata network) external returns (address a) {
        _use(network);
        a = _at(toy());
        _done(false);
    }

    function atHook(string calldata network) external returns (address a) {
        _use(network);
        a = _at(hook());
        _done(false);
    }

    function atExt(string calldata network) external returns (address a) {
        _use(network);
        a = _at(ext());
        _done(false);
    }

    function recover(string calldata network) external returns (string memory) {
        return _recoverRoles(network);
    }

    function _toyArgs() internal view returns (bytes memory) {
        return abi.encode(tag);
    }

    function _secondArgs() internal returns (bytes memory) {
        return abi.encode(uint256(uint160(_at(toy()))));
    }

    function _toyCheck(address at, bytes memory a) internal {
        require(!refuse, "toy refused");
        require(ToyPayload(at).tag() == abi.decode(a, (uint256)), "toy's tag is not its argument");
        ++checks;
    }

    function _roles() internal pure override returns (Role[] memory) {
        return _list(toy(), second());
    }

    function _unit() internal pure override returns (string memory) {
        return "roles";
    }
}

/// @dev Another unit, which reads `TOY()` from the roles unit's journal.
contract ReaderToy is ToyJournal {
    function read(string calldata network) external returns (address a) {
        _use(network);
        a = _at(TOY());
        _done(false);
    }

    function _unit() internal pure override returns (string memory) {
        return "reader";
    }
}

contract RolesTest is Test {
    address private constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes private constant FACTORY_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    address private ops = makeAddr("ops");
    address private other = makeAddr("other key");
    RolesToy private unit = new RolesToy();
    string private network;
    string private dir;

    function _network(string memory name, string memory pin) private {
        vm.chainId(31337);
        network = string.concat("roles-", name);
        dir = string.concat("cache/core-test/deployments/", network);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(dir, true);
        unit.setTestSender(ops);
        string memory json = '{"chains":{"main":{"rpc":"main","id":31337}}';
        if (bytes(pin).length != 0) json = string.concat(json, ',"deployer":"', pin, '"');
        vm.writeFile(string.concat(dir, "/network.json"), string.concat(json, "}"));
    }

    function _journal() private view returns (string memory) {
        return vm.readFile(string.concat(dir, "/roles.json"));
    }

    function _set(string memory key, string memory value) private {
        vm.writeJson(value, string.concat(dir, "/roles.json"), key);
    }

    // ==== CREATE roles ====

    function test_deploy_sendsOnce_andARerunProvesTheReuse_withItsCheck() public {
        _network("once", vm.toString(ops));
        unit.deploy(network);
        address toy = vm.parseJsonAddress(_journal(), ".toy");
        assertEq(vm.getNonce(ops), 1);

        unit.deploy(network);
        assertEq(vm.getNonce(ops), 1, "a rerun sent");
        assertEq(unit.checks(), 1, "the reuse ran no check");
        assertEq(unit.atToy(network), toy);
    }

    function test_probe_judgesADeployStepDue_thenDone() public {
        _network("probe", vm.toString(ops));
        assertTrue(Probes.due(address(unit), abi.encodeCall(RolesToy.deploy, (network)), ops));
        unit.deploy(network);
        assertFalse(Probes.due(address(unit), abi.encodeCall(RolesToy.deploy, (network)), ops));
    }

    function test_deploy_onAPinnedNetwork_refusesAnotherKey_evenWithTheOptIn() public {
        _network("strict", vm.toString(ops));
        unit.allowOtherDeployer();
        unit.setTestSender(other);
        vm.expectRevert(
            bytes(
                string.concat(
                    vm.toString(other),
                    " is not ",
                    dir,
                    "/network.json's deployer ",
                    vm.toString(ops),
                    ": a declared role's creation is proven by the pin, so run with that key, or change the pin in a reviewed commit"
                )
            )
        );
        unit.deploy(network);
        vm.stopBroadcast();
    }

    function test_deploy_aRerunAsAnotherKey_sendsNothingAndPasses() public {
        _network("rerun", vm.toString(ops));
        unit.deploy(network);
        unit.setTestSender(other);
        unit.deploy(network);
        assertEq(vm.getNonce(other), 0);
    }

    function test_at_refusesARecordedDeployerOtherThanThePin() public {
        _network("pin", vm.toString(ops));
        unit.deploy(network);
        vm.writeFile(
            string.concat(dir, "/network.json"),
            string.concat('{"chains":{"main":{"rpc":"main","id":31337}},"deployer":"', vm.toString(other), '"}')
        );
        vm.expectRevert(bytes("toy's recorded deployer is not network.json's deployer"));
        unit.atToy(network);
    }

    function test_at_onAnUnpinnedNetwork_provesByTheRecordedDeployer() public {
        _network("unpinned", "");
        unit.deploy(network);
        address toy = vm.parseJsonAddress(_journal(), ".toy");
        assertEq(unit.atToy(network), toy);

        _set(".toyDeployer", string.concat('"', vm.toString(other), '"'));
        vm.expectRevert(bytes("toy's address is not its recorded deployer's CREATE at its recorded nonce"));
        unit.atToy(network);
    }

    function test_at_refusesARecordOfOtherArgumentsOrNonce() public {
        _network("record", vm.toString(ops));
        unit.deploy(network);
        unit.setTag(2);
        vm.expectRevert(bytes("toy's constructor arguments differ from roles.json"));
        unit.atToy(network);

        unit.setTag(1);
        _set(".toyNonce", "5");
        vm.expectRevert(bytes("toy's address is not its recorded deployer's CREATE at its recorded nonce"));
        unit.atToy(network);
    }

    function test_at_refusesARoleNoTransactionShowsCreated_unlessATestTrustsIt() public {
        _network("unshown", vm.toString(ops));
        unit.deploy(network);
        RolesToy fresh = new RolesToy();
        fresh.setTestSender(ops);
        vm.expectRevert(
            bytes(
                "neither roles.json, a broadcast record nor the chain shows the transaction that created toy: journal it as toyTx"
            )
        );
        fresh.atToy(network);

        fresh.trustTestCreations();
        assertEq(fresh.atToy(network), vm.parseJsonAddress(_journal(), ".toy"));
    }

    function test_check_runsOnEveryReuse_andItsRefusalStopsTheStep() public {
        _network("check", vm.toString(ops));
        unit.deploy(network);
        unit.setRefuse(true);
        vm.expectRevert(bytes("toy refused"));
        unit.deploy(network);
        vm.stopBroadcast();
        vm.expectRevert(bytes("toy refused"));
        unit.atToy(network);
    }

    function test_deploy_aLaterRoleReadsAnEarlierOne_inADryRun_whichJournalsNothing() public {
        _network("dry", vm.toString(ops));
        unit.simulate();
        unit.deployBoth(network);
        assertFalse(vm.exists(string.concat(dir, "/roles.json")), "a dry run journaled");
        address toy = vm.computeCreateAddress(ops, 0);
        address second = vm.computeCreateAddress(ops, 1);
        assertEq(SecondPayload(second).tag(), uint256(uint160(toy)));
    }

    function test_step_anEarlyReturnStillEndsTheStep() public {
        _network("early", vm.toString(ops));
        unit.setStop(true);
        unit.deployBoth(network);
        assertFalse(vm.keyExistsJson(_journal(), ".second"));
        unit.setStop(false);
        unit.deployBoth(network);
        assertEq(vm.getNonce(ops), 2);
        assertEq(SecondPayload(vm.parseJsonAddress(_journal(), ".second")).tag(), uint256(uint160(unit.atToy(network))));
    }

    // ==== Certificates ====

    function test_certify_listsTheDeclaredRolesInOrder_whateverOrderTheStepProvedThem() public {
        _network("certify", vm.toString(ops));
        unit.deployBoth(network);
        unit.check(network);
        string memory first = _journal();
        assertEq(vm.parseJsonAddress(first, ".checked.toy"), vm.parseJsonAddress(first, ".toy"));
        assertEq(vm.parseJsonAddress(first, ".checked.second"), vm.parseJsonAddress(first, ".second"));
        assertTrue(vm.keyExistsJson(first, ".checked.secondCodeHash"));

        unit.checkReversed(network);
        assertEq(_journal(), first, "the order of _at changed the certificate");
    }

    function test_certify_refusesADeclaredRoleTheStepDidNotProve() public {
        _network("unproved", vm.toString(ops));
        unit.deployBoth(network);
        vm.expectRevert(bytes("the step did not prove second"));
        unit.checkToyOnly(network);
    }

    function test_certificate_takesTheStepsOwnFacts() public {
        _network("facts", vm.toString(ops));
        unit.deployBoth(network);
        unit.checkWithFact(network);
        assertEq(vm.parseJsonUint(_journal(), ".checked.extra"), 5);
    }

    // ==== Other kinds ====

    function test_create2_deploysAtTheInputsAddress_thenProvesItByTheRecordedInitcode() public {
        _network("create2", vm.toString(ops));
        vm.etch(FACTORY, FACTORY_CODE);
        bytes32 salt = bytes32(uint256(5));
        bytes memory initcode = bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(uint256(7)));
        address at = vm.computeCreate2Address(salt, keccak256(initcode), FACTORY);
        vm.writeFile(
            string.concat(dir, "/roles.input.json"),
            string.concat('{"create2":{"salt":"', vm.toString(salt), '","address":"', vm.toString(at), '"}}')
        );
        unit.deployHook(network);
        assertEq(ToyPayload(at).tag(), 7);
        uint256 nonce = vm.getNonce(ops);
        unit.deployHook(network);
        assertEq(vm.getNonce(ops), nonce, "a rerun sent");
        assertEq(unit.atHook(network), at);

        _set(".hookArgs", '"0x01"');
        vm.expectRevert(bytes("hook's constructor arguments differ from roles.json"));
        unit.atHook(network);
        _set(".hookArgs", string.concat('"', vm.toString(abi.encode(uint256(7))), '"'));
        _set(".hookInitcodeHash", string.concat('"', vm.toString(bytes32(uint256(1))), '"'));
        vm.expectRevert(bytes("hook's address is not the CREATE2 factory's for its recorded salt and initcode"));
        unit.atHook(network);
    }

    function test_extern_isTheInputsAddress_withThePinnedCode() public {
        _network("extern", vm.toString(ops));
        address ext = address(new ToyPayload(3));
        vm.writeFile(string.concat(dir, "/roles.input.json"), string.concat('{"ext":"', vm.toString(ext), '"}'));
        unit.setExternHash(ext.codehash);
        assertEq(unit.atExt(network), ext);

        unit.setExternHash(bytes32(uint256(1)));
        vm.expectRevert(bytes("ext's code is not the code its role pins"));
        unit.atExt(network);
        vm.expectRevert(bytes("ext is extern: read it with _at"));
        unit.deployExt(network);
    }

    function test_at_readsAnotherUnitsRole_byItsJournaledIdentity() public {
        _network("reader", vm.toString(ops));
        unit.deploy(network);
        ReaderToy reader = new ReaderToy();
        assertEq(reader.read(network), vm.parseJsonAddress(_journal(), ".toy"));

        _set(".toyNonce", "3");
        vm.expectRevert(bytes("toy's address is not its recorded deployer's CREATE at its recorded nonce"));
        reader.read(network);
    }

    // ==== Recovery ====

    function test_recover_rebuildsTheDeclaredRoles_aLaterOneFromTheEarliersFoundAddress() public {
        _network("recover", vm.toString(ops));
        unit.deployBoth(network);
        string memory lost = _journal();
        vm.removeFile(string.concat(dir, "/roles.json"));
        address toy = vm.parseJsonAddress(lost, ".toy");
        address second = vm.parseJsonAddress(lost, ".second");
        string memory records = string.concat(dir, "/broadcast/RolesToy.s.sol/records");
        vm.createDir(records, true);
        vm.writeFile(
            string.concat(records, "/0-latest.json"),
            string.concat(
                '{"chain": 31337, "transactions": [',
                _create("ToyPayload", toy, 0, abi.encode(uint256(1))),
                ", ",
                _create("SecondPayload", second, 1, abi.encode(uint256(uint160(toy)))),
                "]}"
            )
        );

        unit.recover(network);
        string memory got = _journal();
        assertEq(vm.parseJsonAddress(got, ".toy"), toy);
        assertEq(vm.parseJsonAddress(got, ".second"), second);
        assertEq(vm.parseJsonBytes(got, ".secondArgs"), abi.encode(uint256(uint160(toy))));
        unit.deployBoth(network);
        assertEq(vm.getNonce(ops), 2, "a step after recover sent");
    }

    function _create(string memory name, address addr, uint256 nonce, bytes memory args)
        private
        view
        returns (string memory)
    {
        return string.concat(
            '{"transactionType": "CREATE", "contractName": "',
            name,
            '", "contractAddress": "',
            vm.toLowercase(vm.toString(addr)),
            '", "transaction": {"from": "',
            vm.toLowercase(vm.toString(ops)),
            '", "nonce": "',
            vm.toString(bytes32(nonce)),
            '", "input": "',
            vm.toString(bytes.concat(vm.getCode(string.concat(name, ".sol:", name)), args)),
            '"}}'
        );
    }
}

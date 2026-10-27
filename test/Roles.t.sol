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
    bool public refuseSecond;

    function setRefuseSecond(bool refuse_) external {
        refuseSecond = refuse_;
    }

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
        return TOY().args(_toyArgs).ensure(_toyCheck);
    }

    function second() internal pure returns (Role memory) {
        return create("second", "SecondPayload").args(_secondArgs);
    }

    function undeclared() internal pure returns (Role memory) {
        return create("undeclared", "ToyPayload").args(abi.encode(uint256(9)));
    }

    function selfReading() internal pure returns (Role memory) {
        return TOY().args(_toyArgs).ensure(_readsItself);
    }

    function deploy(string calldata network) external step(network) {
        _deploy(toy());
    }

    function deployBoth(string calldata network) external step(network) {
        _deploy(toy());
        if (stop) return;
        _deploy(second());
    }

    function deployUndeclared(string calldata network) external step(network) {
        _deploy(undeclared());
    }

    function atSelfReading(string calldata network) external returns (address a) {
        _use(network);
        a = _at(selfReading());
        _done(false);
    }

    function check(string calldata network) external step(network) {
        _at(toy());
        _at(second());
        _endCheck();
    }

    function checkReversed(string calldata network) external step(network) {
        _at(second());
        _at(toy());
        _endCheck();
    }

    function checkToyOnly(string calldata network) external step(network) {
        _at(toy());
        _endCheck();
    }

    function bothArgs(bool bytesFirst) external pure {
        Role memory r = create("both", "ToyPayload");
        if (bytesFirst) r.args(abi.encode(uint256(1))).args(_toyArgs);
        else r.args(_toyArgs).args(abi.encode(uint256(1)));
    }

    /// @dev `vm.chainId` stands for a fork switch: no RPC serves a second chain under `forge test`.
    function atToyOnTwoChains(string calldata network, uint256 other, bool emptyThere)
        external
        step(network)
        returns (address here, address there)
    {
        here = _at(toy());
        _at(toy());
        vm.chainId(other);
        if (emptyThere) vm.etch(here, "");
        there = _at(toy());
        vm.chainId(31337);
    }

    function atToyOutsideAStep() external returns (address) {
        return _at(toy());
    }

    function atToy(string calldata network) external returns (address a) {
        _use(network);
        a = _at(toy());
        _done(false);
    }

    function recover(string calldata network) external returns (string memory) {
        return _recoverRoles(network);
    }

    function _toyArgs() internal view returns (bytes memory) {
        return abi.encode(tag);
    }

    function _secondArgs() internal returns (bytes memory) {
        require(!refuseSecond, "second refused");
        return abi.encode(uint256(uint160(_at(toy()))));
    }

    function _readsItself(address, bytes memory) internal {
        _at(selfReading());
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

/// @dev A CREATE2 role and an extern one, each declared.
contract KindsToy is ToyJournal {
    bytes32 public externHash;

    function setExternHash(bytes32 hash) external {
        externHash = hash;
    }

    uint256 public hookTag = 7;

    function setHookTag(uint256 tag) external {
        hookTag = tag;
    }

    function hook() internal view returns (Role memory) {
        return create2("hook", "ToyPayload", "create2").args(abi.encode(hookTag));
    }

    function ext() internal view returns (Role memory) {
        return extern("ext", "ext", externHash);
    }

    function deployHook(string calldata network) external step(network) {
        _deploy(hook());
    }

    function deployExt(string calldata network) external step(network) {
        _deploy(ext());
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

    function _roles() internal view override returns (Role[] memory) {
        return _list(hook(), ext());
    }

    function _unit() internal pure override returns (string memory) {
        return "kinds";
    }
}

/// @dev Two roles of one artifact, which a recovery tells apart by their arguments.
contract TwinToy is ToyJournal {
    function left() internal pure returns (Role memory) {
        return create("left", "ToyPayload").args(abi.encode(uint256(1)));
    }

    function right() internal pure returns (Role memory) {
        return create("right", "ToyPayload").args(abi.encode(uint256(2)));
    }

    function deploy(string calldata network) external step(network) {
        _deploy(left());
        _deploy(right());
    }

    function recover(string calldata network) external returns (string memory) {
        return _recoverRoles(network);
    }

    function _roles() internal pure override returns (Role[] memory) {
        return _list(left(), right());
    }

    function _unit() internal pure override returns (string memory) {
        return "twin";
    }
}

/// @dev Another unit, which reads `TOY()` from the roles unit's journal.
contract ReaderToy is ToyJournal {
    function read(string calldata network) external returns (address a) {
        _use(network);
        a = _at(TOY());
        _done(false);
    }

    function readWith(string calldata network, bytes calldata args) external returns (address a) {
        _use(network);
        a = _at(TOY().args(args));
        _done(false);
    }

    /// @dev The builder reads the roles unit's journal as its own.
    function readBuilt(string calldata network) external returns (address a) {
        _use(network);
        a = _at(TOY().args(_journaledArgs));
        _done(false);
    }

    function readHook(string calldata network, bytes calldata args) external returns (address a) {
        _use(network);
        a = _at(create2("hook", "ToyPayload", "create2").args(args).unit("kinds"));
        _done(false);
    }

    function readExt(string calldata network, bytes32 pinned) external returns (address a) {
        _use(network);
        a = _at(extern("ext", "ext", pinned).unit("kinds"));
        _done(false);
    }

    function _journaledArgs() private view returns (bytes memory) {
        return vm.parseJsonBytes(_journal(), ".toyArgs");
    }

    function _unit() internal pure override returns (string memory) {
        return "reader";
    }
}

/// @dev `ReaderToy` on a chain where `confirmed` created the role and `sent` is its transaction's input.
contract LandedReader is ReaderToy {
    bytes32 public confirmed;
    bytes public sent;

    function confirm(bytes32 hash, bytes calldata input) external {
        (confirmed, sent) = (hash, input);
    }

    function _createdIn(bytes32 hash, address, bool) internal view override returns (uint256) {
        return hash == confirmed ? 5 : 0;
    }

    function _sentInput(bytes32) internal view override returns (bytes memory) {
        return sent;
    }
}

/// @dev The chain as a test confirms it: `confirmed` created the toy, and sent the toy's initcode.
contract LandedToy is RolesToy {
    bytes32 public confirmed;

    function confirm(bytes32 hash) external {
        confirmed = hash;
    }

    function _createdIn(bytes32 hash, address, bool create2) internal view override returns (uint256) {
        return hash == confirmed && !create2 ? 5 : 0;
    }

    function _sentInput(bytes32) internal view override returns (bytes memory) {
        return bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(uint256(1)));
    }
}

contract RolesTest is Test {
    address private constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes private constant FACTORY_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    address private ops = makeAddr("ops");
    address private other = makeAddr("other key");
    RolesToy private unit = new RolesToy();
    KindsToy private kinds = new KindsToy();
    string private network;
    string private dir;

    function _network(string memory name, string memory pin) private {
        vm.chainId(31337);
        network = string.concat("roles-", name);
        dir = string.concat("cache/core-test/deployments/", network);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(dir, true);
        unit.setTestSender(ops);
        kinds.setTestSender(ops);
        string memory json = '{"chains":{"main":{"rpc":"main","id":31337}}';
        if (bytes(pin).length != 0) json = string.concat(json, ',"deployer":"', pin, '"');
        vm.writeFile(string.concat(dir, "/network.json"), string.concat(json, "}"));
    }

    function _journal() private view returns (string memory) {
        return vm.readFile(string.concat(dir, "/roles.json"));
    }

    function _set(string memory key, string memory value) private {
        _setIn("roles", key, value);
    }

    function _setIn(string memory unit_, string memory key, string memory value) private {
        vm.writeJson(value, string.concat(dir, "/", unit_, ".json"), key);
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

    function test_args_refusesBothForms() public {
        vm.expectRevert(bytes("both's .args is given both as bytes and as a function: keep one"));
        unit.bothArgs(true);
        vm.expectRevert(bytes("both's .args is given both as bytes and as a function: keep one"));
        unit.bothArgs(false);
    }

    function test_at_provesAgainOnAnotherChainOfTheStep() public {
        _network("chains", vm.toString(ops));
        unit.deploy(network);
        unit.trustTestCreations();
        uint256 checks = unit.checks();
        (address here, address there) = unit.atToyOnTwoChains(network, 4242, false);
        assertEq(there, here, "each chain's address");
        assertEq(unit.checks(), checks + 2, "one proof for each chain");
        vm.expectRevert(
            bytes(
                string.concat(
                    "toy at ",
                    vm.toString(here),
                    " has no code: if the RPC lags behind the chain, run again once it shows the deployment"
                )
            )
        );
        unit.atToyOnTwoChains(network, 4242, true);
    }

    function test_trustTestCreationOf_trustsTheJournaledIntentOfOneRoleOnly() public {
        _network("trust-one", vm.toString(ops));
        unit.deployBoth(network);
        RolesToy later = new RolesToy();
        later.setTestSender(ops);
        later.trustTestCreationOf(_journal(), "toy");
        assertEq(later.atToy(network), vm.parseJsonAddress(_journal(), ".toy"));
        vm.expectRevert(
            bytes(
                "neither roles.json, a broadcast record nor the chain shows the transaction that created second: journal it as secondTx"
            )
        );
        later.check(network);
    }

    function test_recover_withoutASender_isRefused() public {
        _network("recover-no-sender", vm.toString(ops));
        RolesToy unsent = new RolesToy();
        vm.expectRevert(bytes("pass --sender <deployer>: the sender of the lost deployments"));
        unsent.recover(network);
    }

    function test_at_aJournalWithoutTheRole_isRefusedByName() public {
        _network("unjournaled", vm.toString(ops));
        vm.expectRevert(bytes("roles.json records no toyCodeHash"));
        unit.atToy(network);
    }

    /// @dev forge simulates a send in an earlier block than the one it lands in, so a constructor that stores
    ///      `block.timestamp` in an immutable lands with another code hash than the journal's simulated one.
    function test_at_aRoleThatLandedWithOtherCodeThanItsSimulation_isProvenByItsCreationInput() public {
        _network("landed", vm.toString(ops));
        LandedToy landed = new LandedToy();
        landed.setTestSender(ops);
        landed.deploy(network);
        string memory path = string.concat(dir, "/roles.json");
        address addr = vm.parseJsonAddress(vm.readFile(path), ".toy");
        vm.etch(addr, bytes.concat(addr.code, hex"00")); // unreachable: the same behaviour, another code hash
        bytes32 hash = keccak256("the toy's creation");
        vm.writeJson(vm.toString(hash), path, ".toyTx");

        vm.expectRevert(bytes("toy's code differs from roles.json"));
        landed.atToy(network);

        landed.confirm(hash);
        assertEq(landed.atToy(network), addr);
        assertEq(vm.parseJsonBytes32(vm.readFile(path), ".toyCodeHash"), addr.codehash);
    }

    /// @dev As for a CREATE role, but a CREATE2 address commits to the journaled initcode: no transaction is read.
    function test_at_aCreate2RoleThatLandedWithOtherCodeThanItsSimulation_isProvenByItsAddress() public {
        _network("landed2", vm.toString(ops));
        bytes32 salt = bytes32(uint256(6));
        bytes memory initcode = bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(uint256(7)));
        address at = vm.computeCreate2Address(salt, keccak256(initcode), FACTORY);
        vm.writeFile(
            string.concat(dir, "/kinds.input.json"),
            string.concat('{"create2":{"salt":"', vm.toString(salt), '","address":"', vm.toString(at), '"}}')
        );
        kinds.deployHook(network);
        vm.etch(at, bytes.concat(at.code, hex"00")); // unreachable: the same behaviour, another code hash

        assertEq(kinds.atHook(network), at);
        assertEq(vm.parseJsonBytes32(vm.readFile(string.concat(dir, "/kinds.json")), ".hookCodeHash"), at.codehash);
    }

    function test_at_outsideAStep_provesOnEveryCall() public {
        _network("outside", vm.toString(ops));
        unit.deploy(network);
        uint256 checks = unit.checks();
        unit.atToyOutsideAStep();
        unit.atToyOutsideAStep();
        assertEq(unit.checks(), checks + 2, "a call outside a step reused an earlier proof");
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
                    ": only the pin sends a declared CREATE role, whose address follows from its sender: sign as the pin"
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

    /// @dev The journal's arguments, edited to match a changed input, do not pass for the ones the creation sent.
    function test_at_refusesArgumentsTheCreationDidNotSend_andATxThatCreatedNoToy() public {
        _network("sent-args", vm.toString(ops));
        unit.deploy(network);
        LandedToy fresh = new LandedToy();
        fresh.setTestSender(ops);
        bytes32 hash = keccak256("the toy's creation");
        _set(".toyTx", vm.toString(hash));
        vm.expectRevert(bytes("toyTx in roles.json did not create toy: a person must resolve it"));
        fresh.atToy(network);

        fresh.confirm(hash);
        assertEq(fresh.atToy(network), vm.parseJsonAddress(_journal(), ".toy"));

        fresh.setTag(2);
        _set(".toyArgs", vm.toString(abi.encode(uint256(2))));
        vm.expectRevert(
            bytes("toy's creation sent other constructor arguments than its input: a person must resolve it")
        );
        fresh.atToy(network);
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

    // ==== Ending a check ====

    function test_endCheck_refusesADeclaredRoleTheStepDidNotProve() public {
        _network("unproved", vm.toString(ops));
        unit.deployBoth(network);
        vm.expectRevert(bytes("the step did not prove second"));
        unit.checkToyOnly(network);
    }

    /// @dev A receipt is findable for the role the step proved; the one it skipped is the refusal, not a due step.
    function test_endCheck_judgesNoReceiptDueWhileADeclaredRoleIsUnproved() public {
        _network("unproved-probe", vm.toString(ops));
        LandedToy landed = new LandedToy();
        landed.setTestSender(ops);
        landed.deployBoth(network);
        address toy = vm.parseJsonAddress(_journal(), ".toy");
        landed.confirm(keccak256("the toy's creation"));
        string memory chainDir = string.concat(dir, "/broadcast/ToyUnit.sol/", vm.toString(block.chainid));
        vm.createDir(chainDir, true);
        vm.writeFile(
            string.concat(chainDir, "/deploy-latest.json"),
            string.concat(
                '{"chain": ',
                vm.toString(block.chainid),
                ', "transactions": [], "receipts": [{"contractAddress": "',
                vm.toLowercase(vm.toString(toy)),
                '", "transactionHash": "',
                vm.toString(keccak256("the toy's creation")),
                '", "blockNumber": "0x1"}]}'
            )
        );
        vm.expectRevert(bytes("the step did not prove second"));
        Probes.due(address(landed), abi.encodeCall(RolesToy.checkToyOnly, (network)), ops);
    }

    function test_endCheck_doesNotDependOnTheOrderTheStepProvedTheRoles() public {
        _network("order", vm.toString(ops));
        unit.deployBoth(network);
        _set(".toyTx", '"0x01"');
        _set(".toyBlock", "1");
        _set(".secondTx", '"0x02"');
        _set(".secondBlock", "1");
        string memory journal = _journal();
        unit.check(network);
        unit.checkReversed(network);
        assertEq(_journal(), journal);
    }

    // ==== Other kinds ====

    function test_create2_deploysAtTheInputsAddress_thenProvesItByTheRecordedInitcode() public {
        _network("create2", vm.toString(ops));
        vm.etch(FACTORY, FACTORY_CODE);
        bytes32 salt = bytes32(uint256(5));
        bytes memory initcode = bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(uint256(7)));
        address at = vm.computeCreate2Address(salt, keccak256(initcode), FACTORY);
        vm.writeFile(
            string.concat(dir, "/kinds.input.json"),
            string.concat('{"create2":{"salt":"', vm.toString(salt), '","address":"', vm.toString(at), '"}}')
        );
        kinds.deployHook(network);
        assertEq(ToyPayload(at).tag(), 7);
        uint256 nonce = vm.getNonce(ops);
        kinds.deployHook(network);
        assertEq(vm.getNonce(ops), nonce, "a rerun sent");
        assertEq(kinds.atHook(network), at);

        _setIn("kinds", ".hookArgs", '"0x01"');
        vm.expectRevert(bytes("hook's constructor arguments differ from kinds.json"));
        kinds.atHook(network);
        _setIn("kinds", ".hookArgs", string.concat('"', vm.toString(abi.encode(uint256(7))), '"'));
        _setIn("kinds", ".hookInitcodeHash", string.concat('"', vm.toString(bytes32(uint256(1))), '"'));
        vm.expectRevert(bytes("hook's address is not the CREATE2 factory's for its recorded salt and initcode"));
        kinds.atHook(network);
    }

    function test_extern_isTheInputsAddress_withThePinnedCode() public {
        _network("extern", vm.toString(ops));
        address ext = address(new ToyPayload(3));
        vm.writeFile(string.concat(dir, "/kinds.input.json"), string.concat('{"ext":"', vm.toString(ext), '"}'));
        kinds.setExternHash(ext.codehash);
        assertEq(kinds.atExt(network), ext);

        kinds.setExternHash(bytes32(uint256(1)));
        vm.expectRevert(bytes("ext's code is not the code its role pins"));
        kinds.atExt(network);
        vm.expectRevert(bytes("ext is extern: read it with _at"));
        kinds.deployExt(network);
    }

    function test_at_readsAnotherUnitsRole_byItsJournaledIdentity() public {
        _network("reader", vm.toString(ops));
        unit.deploy(network);
        ReaderToy reader = new ReaderToy();
        reader.trustTestCreations();
        assertEq(reader.read(network), vm.parseJsonAddress(_journal(), ".toy"));

        _set(".toyNonce", "3");
        vm.expectRevert(bytes("toy's address is not its recorded deployer's CREATE at its recorded nonce"));
        reader.read(network);
    }

    function test_at_anotherUnitsRole_isRefusedWhenItsCodeIsNotTheJournaled() public {
        _network("reader-code", vm.toString(ops));
        unit.deploy(network);
        ReaderToy reader = new ReaderToy();
        reader.trustTestCreations();
        address toy = vm.parseJsonAddress(_journal(), ".toy");

        vm.etch(toy, bytes.concat(toy.code, hex"00"));
        vm.expectRevert(bytes("toy's code differs from roles.json"));
        reader.read(network);

        vm.etch(toy, "");
        vm.expectRevert(
            bytes(
                string.concat(
                    "toy at ",
                    vm.toString(toy),
                    " has no code: if the RPC lags behind the chain, run again once it shows the deployment"
                )
            )
        );
        reader.read(network);
    }

    function test_at_anotherUnitsRole_isRefusedWhenNoTransactionShowsItCreated() public {
        _network("reader-unshown", vm.toString(ops));
        unit.deploy(network);
        ReaderToy reader = new ReaderToy();
        vm.expectRevert(
            bytes(
                "neither roles.json, a broadcast record nor the chain shows the transaction that created toy: journal it as toyTx"
            )
        );
        reader.read(network);
    }

    /// @dev The journal's arguments, edited to another consistent set, do not pass for what the creation sent.
    function test_at_anotherUnitsRole_isRefusedWhenItsJournaledArgumentsAreNotTheCreations() public {
        _network("reader-sent", vm.toString(ops));
        unit.deploy(network);
        LandedReader reader = new LandedReader();
        bytes32 hash = keccak256("the toy's creation");
        _set(".toyTx", vm.toString(hash));
        reader.confirm(hash, bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(uint256(1))));
        assertEq(reader.read(network), vm.parseJsonAddress(_journal(), ".toy"));

        _set(".toyArgs", vm.toString(abi.encode(uint256(2))));
        vm.expectRevert(
            bytes("toy's creation sent other constructor arguments than its input: a person must resolve it")
        );
        reader.read(network);
    }

    function test_at_anotherUnitsRole_isRefusedWhenItsJournaledArgumentsAreNotTheBuilders() public {
        _network("reader-builder", vm.toString(ops));
        unit.deploy(network);
        ReaderToy reader = new ReaderToy();
        reader.trustTestCreations();
        address toy = vm.parseJsonAddress(_journal(), ".toy");
        assertEq(reader.readWith(network, abi.encode(uint256(1))), toy);

        vm.expectRevert(bytes("toy's constructor arguments differ from roles.json"));
        reader.readWith(network, abi.encode(uint256(2)));
    }

    function test_at_anotherUnitsBuilder_runsAsItsUnit() public {
        _network("reader-as", vm.toString(ops));
        unit.deploy(network);
        ReaderToy reader = new ReaderToy();
        reader.trustTestCreations();
        assertEq(reader.readBuilt(network), vm.parseJsonAddress(_journal(), ".toy"));
    }

    function test_at_anotherUnitsCreate2Role_isRefusedWhenItsArgumentsAreNotItsInitcodeHashs() public {
        _network("reader-create2", vm.toString(ops));
        vm.etch(FACTORY, FACTORY_CODE);
        bytes32 salt = bytes32(uint256(5));
        bytes memory initcode = bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(uint256(7)));
        address at = vm.computeCreate2Address(salt, keccak256(initcode), FACTORY);
        vm.writeFile(
            string.concat(dir, "/kinds.input.json"),
            string.concat('{"create2":{"salt":"', vm.toString(salt), '","address":"', vm.toString(at), '"}}')
        );
        kinds.deployHook(network);
        ReaderToy reader = new ReaderToy();
        assertEq(reader.readHook(network, abi.encode(uint256(7))), at);

        _setIn("kinds", ".hookArgs", string.concat('"', vm.toString(abi.encode(uint256(8))), '"'));
        vm.expectRevert(
            bytes(
                "hook's constructor arguments are not the ones its recorded initcode hash commits to: a person must resolve it"
            )
        );
        reader.readHook(network, abi.encode(uint256(8)));
    }

    function test_at_aCreate2Role_isRefusedWhenItsArgumentsAreNotItsInitcodeHashs() public {
        _network("create2-tie", vm.toString(ops));
        vm.etch(FACTORY, FACTORY_CODE);
        bytes32 salt = bytes32(uint256(5));
        bytes memory initcode = bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(uint256(7)));
        address at = vm.computeCreate2Address(salt, keccak256(initcode), FACTORY);
        vm.writeFile(
            string.concat(dir, "/kinds.input.json"),
            string.concat('{"create2":{"salt":"', vm.toString(salt), '","address":"', vm.toString(at), '"}}')
        );
        kinds.deployHook(network);
        kinds.setHookTag(8);
        _setIn("kinds", ".hookArgs", string.concat('"', vm.toString(abi.encode(uint256(8))), '"'));
        vm.expectRevert(
            bytes(
                "hook's constructor arguments are not the ones its recorded initcode hash commits to: a person must resolve it"
            )
        );
        kinds.atHook(network);
    }

    /// @dev A source edit changes the creation code: the factory call shows the arguments instead.
    function test_at_aCreate2Role_ofAnEditedBuild_isProvenByItsFactoryCall() public {
        _network("create2-edited", vm.toString(ops));
        vm.etch(FACTORY, FACTORY_CODE);
        bytes32 salt = bytes32(uint256(5));
        bytes memory old = bytes.concat(hex"aabb", abi.encode(uint256(7)));
        address at = vm.computeCreate2Address(salt, keccak256(old), FACTORY);
        vm.etch(at, address(new ToyPayload(7)).code);
        string memory j = string.concat(
            '{"hook":"',
            vm.toString(at),
            '","hookSalt":"',
            vm.toString(salt),
            '","hookInitcodeHash":"',
            vm.toString(keccak256(old)),
            '","hookCodeHash":"',
            vm.toString(at.codehash),
            '","hookArgs":"',
            vm.toString(abi.encode(uint256(7))),
            '","hookTx":"',
            vm.toString(keccak256("the hook's creation")),
            '","mainChainId":31337}'
        );
        vm.writeFile(string.concat(dir, "/kinds.json"), j);
        LandedReader reader = new LandedReader();
        reader.confirm(keccak256("the hook's creation"), bytes.concat(salt, old));
        assertEq(reader.readHook(network, abi.encode(uint256(7))), at);

        reader.confirm(keccak256("the hook's creation"), bytes.concat(salt, hex"aabb", abi.encode(uint256(9))));
        vm.expectRevert(
            bytes(
                "hook's constructor arguments are not the ones its recorded initcode hash commits to: a person must resolve it"
            )
        );
        reader.readHook(network, abi.encode(uint256(7)));
    }

    function test_at_anotherUnitsExternRole_isTheInputsAddressWithThePinnedCode() public {
        _network("reader-extern", vm.toString(ops));
        ReaderToy reader = new ReaderToy();
        address ext = address(new ToyPayload(3));
        vm.expectRevert();
        reader.readExt(network, ext.codehash);

        vm.writeFile(string.concat(dir, "/kinds.input.json"), string.concat('{"ext":"', vm.toString(ext), '"}'));
        assertEq(reader.readExt(network, ext.codehash), ext);

        vm.expectRevert(bytes("ext's code is not the code its role pins"));
        reader.readExt(network, bytes32(uint256(1)));

        vm.etch(ext, "");
        vm.expectRevert(
            bytes(
                string.concat(
                    "ext at ",
                    vm.toString(ext),
                    " has no code: if the RPC lags behind the chain, run again once it shows the deployment"
                )
            )
        );
        reader.readExt(network, ext.codehash);
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

    // ==== Review cases ====

    function test_deploy_aRefusalOfALaterRole_leavesTheEarliersIntent_whichTheRerunSendsAsPlanned() public {
        _network("refused", vm.toString(ops));
        unit.setRefuseSecond(true);
        vm.expectRevert(bytes("second refused"));
        unit.deployBoth(network);
        string memory journal = _journal();
        address planned = vm.parseJsonAddress(journal, ".toy");
        assertEq(planned.code.length, 0, "the refused step's CREATE stayed");
        assertEq(vm.parseJsonString(journal, ".toyCommit"), "pending");

        unit.setRefuseSecond(false);
        unit.deployBoth(network);
        assertEq(vm.parseJsonAddress(_journal(), ".toy"), planned, "the rerun did not send the planned intent");
        assertTrue(planned.code.length != 0);
    }

    function test_deploy_refusesARoleOutsideRoles() public {
        _network("undeclared", vm.toString(ops));
        vm.expectRevert(bytes("undeclared is not in roles's _roles(): declare it there"));
        unit.deployUndeclared(network);
    }

    function test_check_thatReadsItsOwnRole_refusesByName() public {
        _network("self", vm.toString(ops));
        unit.deploy(network);
        vm.expectRevert(bytes("toy's .ensure reads toy itself: use the address and arguments it is given"));
        unit.atSelfReading(network);
    }

    /// @dev A pin's rotation is unsupported, so a network.json written for one is refused, not read in part.
    function test_pin_aNetworkThatListsFormerDeployers_isRefusedByName() public {
        _network("rotate", vm.toString(ops));
        unit.deploy(network);
        vm.writeFile(
            string.concat(dir, "/network.json"),
            string.concat(
                '{"chains":{"main":{"rpc":"main","id":31337}},"deployer":"',
                vm.toString(ops),
                '","formerDeployers":["',
                vm.toString(other),
                '"]}'
            )
        );
        bytes memory refusal = bytes(
            "network.json lists formerDeployers, which sprue no longer reads: a change of the pin is not supported; remove the field, and a role an earlier key created is refused"
        );
        vm.expectRevert(refusal);
        unit.atToy(network);
        vm.expectRevert(refusal);
        unit.deploy(network);
    }

    function test_create2_isProvenWhoeverSentIt() public {
        _network("create2-any", vm.toString(ops));
        vm.etch(FACTORY, FACTORY_CODE);
        bytes32 salt = bytes32(uint256(6));
        bytes memory initcode = bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(uint256(7)));
        address at = vm.computeCreate2Address(salt, keccak256(initcode), FACTORY);
        vm.writeFile(
            string.concat(dir, "/kinds.input.json"),
            string.concat('{"create2":{"salt":"', vm.toString(salt), '","address":"', vm.toString(at), '"}}')
        );
        kinds.allowOtherDeployer();
        kinds.setTestSender(other);
        kinds.deployHook(network);
        kinds.setTestSender(ops);
        assertEq(kinds.atHook(network), at);
    }

    function test_recover_tellsTwoRolesOfOneArtifactApart_byTheirArguments() public {
        _network("twin", vm.toString(ops));
        TwinToy twin = new TwinToy();
        twin.setTestSender(ops);
        twin.deploy(network);
        string memory lost = vm.readFile(string.concat(dir, "/twin.json"));
        vm.removeFile(string.concat(dir, "/twin.json"));
        address left = vm.parseJsonAddress(lost, ".left");
        address right = vm.parseJsonAddress(lost, ".right");
        string memory records = string.concat(dir, "/broadcast/TwinToy.s.sol/records");
        vm.createDir(records, true);
        vm.writeFile(
            string.concat(records, "/0-latest.json"),
            string.concat(
                '{"chain": 31337, "transactions": [',
                _create("ToyPayload", left, 0, abi.encode(uint256(1))),
                ", ",
                _create("ToyPayload", right, 1, abi.encode(uint256(2))),
                "]}"
            )
        );
        twin.recover(network);
        string memory got = vm.readFile(string.concat(dir, "/twin.json"));
        assertEq(vm.parseJsonAddress(got, ".left"), left);
        assertEq(vm.parseJsonAddress(got, ".right"), right);
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

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

    function hook() internal pure returns (Role memory) {
        return create2("hook", "ToyPayload", "create2").args(abi.encode(uint256(7)));
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

/// @dev An extern role fixed at one address, optional, required on a chain the test sets, with the input key defaulted.
contract AtToy is ToyJournal {
    address public canonical;
    bytes32 public externHash;
    uint256 public requiredChain = 777;

    function setRequired(uint256 chainId) external {
        requiredChain = chainId;
    }

    function set(address at_, bytes32 hash) external {
        (canonical, externHash) = (at_, hash);
    }

    bool public rejects;

    function setRejects() external {
        rejects = true;
    }

    function _reject(address, bytes memory) private pure {
        revert("ext's ensure rejects");
    }

    function ext() internal view returns (Role memory r) {
        r = extern("ext", externHash).at(canonical).optional().requiredOn(requiredChain);
        if (rejects) r = r.ensure(_reject);
    }

    function absentThenPresent(string calldata network, string calldata inputPath, string calldata input)
        external
        returns (address, address)
    {
        _use(network);
        address first = _at(ext());
        vm.etch(canonical, externCode);
        vm.writeFile(inputPath, input);
        address second = _at(ext());
        _done(false);
        return (first, second);
    }

    bytes public externCode;

    function setCode(bytes calldata code) external {
        externCode = code;
    }

    function atExt(string calldata network) external returns (address a) {
        _use(network);
        a = _at(ext());
        _done(false);
    }

    function atExtTwice(string calldata network, bytes calldata codeBetween) external returns (address, address) {
        _use(network);
        address first = _at(ext());
        vm.etch(canonical, codeBetween);
        address second = _at(ext());
        _done(false);
        return (first, second);
    }

    function endAfter(string calldata network, bytes calldata codeBetween) external returns (string memory) {
        _use(network);
        _at(ext());
        vm.etch(canonical, codeBetween);
        return _endCheck();
    }

    function readOther(string calldata network) external returns (address) {
        _use(network);
        return _atOther(ext().unit("at"));
    }

    function _roles() internal view override returns (Role[] memory) {
        return _list(ext());
    }

    function _unit() internal pure override returns (string memory) {
        return "at";
    }
}

/// @dev Another unit, which reads `TOY()` from the roles unit's journal.
contract ReaderToy is ToyJournal {
    function read(string calldata network) external returns (address a) {
        _use(network);
        a = _at(TOY());
        _done(false);
    }

    function readExt(string calldata network, bytes32 pinned) external returns (address a) {
        _use(network);
        a = _at(extern("ext", "ext", pinned).unit("kinds"));
        _done(false);
    }

    function _unit() internal pure override returns (string memory) {
        return "reader";
    }
}

/// @dev The chain as a test confirms it: `confirmed` created the toy, and sent the toy's initcode; `history`
///      names the chain's blocks.
contract LandedToy is RolesToy {
    bytes32 public confirmed;

    function confirm(bytes32 hash) external {
        confirmed = hash;
    }

    /// @dev A reorg right after the receipt is read, when `reorgAfterReceipt` is set.
    function _creationBlock(bytes32 hash, address, bool create2) internal override returns (uint256, bytes32) {
        if (hash != confirmed || create2) return (0, 0);
        bytes32 blockHash = _blockHash(5);
        if (reorgAfterReceipt) history = "reorged";
        return (5, blockHash);
    }

    bool public reorgAfterReceipt;

    function setReorgAfterReceipt(bool reorg) external {
        reorgAfterReceipt = reorg;
    }

    function _sentInput(bytes32) internal view override returns (bytes memory) {
        return bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(uint256(1)));
    }

    bytes32 public history;

    function setHistory(bytes32 history_) external {
        history = history_;
    }

    function _blockHash(uint256 number) internal view override returns (bytes32) {
        return keccak256(abi.encode(history, number));
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

    /// @dev A proof outlives the reverted state that made it, as a probe's does: the run does not read the
    ///      creation again, even where the chain would now say otherwise.
    function test_at_aProofOutlivesARevertOfTheStateThatMadeIt() public {
        _network("kept", vm.toString(ops));
        unit.deploy(network);
        LandedToy fresh = new LandedToy();
        fresh.setTestSender(ops);
        bytes32 hash = keccak256("the toy's creation");
        _set(".toyTx", vm.toString(hash));
        fresh.confirm(hash);
        uint256 before = vm.snapshotState();
        address toy = fresh.atToy(network);
        vm.revertToState(before);
        fresh.confirm(0);
        assertEq(fresh.atToy(network), toy);
    }

    function _provenOnce(string memory name) private returns (LandedToy fresh, address toy) {
        _network(name, vm.toString(ops));
        unit.deploy(network);
        fresh = new LandedToy();
        fresh.setTestSender(ops);
        bytes32 hash = keccak256("the toy's creation");
        _set(".toyTx", vm.toString(hash));
        fresh.confirm(hash);
        toy = fresh.atToy(network);
        fresh.confirm(0);
    }

    /// @dev A kept proof is the address's: another address the chain shows no creation of is refused.
    function test_at_aKeptProofCoversNoOtherAddress() public {
        (LandedToy fresh, address toy) = _provenOnce("kept-addr");
        address second = vm.computeCreateAddress(ops, 1);
        vm.etch(second, toy.code);
        _set(".toy", vm.toString(second));
        _set(".toyNonce", "1");
        vm.expectRevert(bytes("toyTx in roles.json did not create toy: a person must resolve it"));
        fresh.atToy(network);
    }

    /// @dev A kept proof is the chain's: the same address on another chain id is proven again.
    function test_at_aKeptProofCoversNoOtherChain() public {
        (LandedToy fresh,) = _provenOnce("kept-chain");
        vm.chainId(5);
        vm.writeFile(
            string.concat(dir, "/network.json"),
            string.concat('{"chains":{"main":{"rpc":"main","id":5}},"deployer":"', vm.toString(ops), '"}')
        );
        _set(".mainChainId", "5");
        vm.expectRevert(bytes("toyTx in roles.json did not create toy: a person must resolve it"));
        fresh.atToy(network);
    }

    /// @dev A kept proof holds only on the history that showed it: another history of the same chain id, or a
    ///      reorg of the creation's block, proves the creation again.
    function test_at_aKeptProofHoldsOnlyOnTheHistoryThatShowedIt() public {
        (LandedToy fresh, address toy) = _provenOnce("kept-history");
        assertEq(fresh.atToy(network), toy);
        fresh.setHistory("another");
        vm.expectRevert(bytes("toyTx in roles.json did not create toy: a person must resolve it"));
        fresh.atToy(network);
    }

    /// @dev A kept proof names the block of the receipt it checked: a reorg after that read leaves it unused.
    function test_at_aKeptProofNamesTheBlockOfTheReceiptItChecked() public {
        _network("kept-receipt", vm.toString(ops));
        unit.deploy(network);
        LandedToy fresh = new LandedToy();
        fresh.setTestSender(ops);
        bytes32 hash = keccak256("the toy's creation");
        _set(".toyTx", vm.toString(hash));
        fresh.confirm(hash);
        fresh.setReorgAfterReceipt(true);
        fresh.atToy(network);
        fresh.confirm(0);
        vm.expectRevert(bytes("toyTx in roles.json did not create toy: a person must resolve it"));
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
        assertEq(reader.read(network), vm.parseJsonAddress(_journal(), ".toy"));

        _set(".toyNonce", "3");
        vm.expectRevert(bytes("toy's address is not its recorded deployer's CREATE at its recorded nonce"));
        reader.read(network);
    }

    function test_at_anotherUnitsRole_isRefusedWhenItsCodeIsNotTheJournaled() public {
        _network("reader-code", vm.toString(ops));
        unit.deploy(network);
        ReaderToy reader = new ReaderToy();
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

    // ==== Extern roles with a canonical address ====

    function _atInput(string memory value) private {
        vm.writeFile(string.concat(dir, "/at.input.json"), string.concat('{"ext":', value, "}"));
    }

    function _atFixture() private returns (AtToy t, address ext) {
        t = new AtToy();
        ext = address(new ToyPayload(3));
        t.set(ext, ext.codehash);
    }

    function test_extern_at_isTheInputsAddressWhenItIsTheCanonicalOne_underTheDefaultKey() public {
        _network("extern-at", vm.toString(ops));
        (AtToy t, address ext) = _atFixture();
        _atInput(string.concat('"', vm.toString(ext), '"'));
        assertEq(t.atExt(network), ext);
        assertEq(t.readOther(network), ext);
    }

    function test_extern_at_refusesAnotherAddress_evenWithThePinnedCode() public {
        _network("extern-at-other", vm.toString(ops));
        (AtToy t, address ext) = _atFixture();
        address clone = makeAddr("clone");
        vm.etch(clone, ext.code);
        _atInput(string.concat('"', vm.toString(clone), '"'));
        bytes memory reason =
            bytes(string.concat("ext's input names ", vm.toString(clone), ", not its canonical ", vm.toString(ext)));
        vm.expectRevert(reason);
        t.atExt(network);
        vm.expectRevert(reason);
        t.readOther(network);
    }

    function test_extern_at_keepsTheCodeHashCheck() public {
        _network("extern-at-code", vm.toString(ops));
        (AtToy t, address ext) = _atFixture();
        _atInput(string.concat('"', vm.toString(ext), '"'));
        t.set(ext, bytes32(uint256(1)));
        vm.expectRevert(bytes("ext's code is not the code its role pins"));
        t.atExt(network);
    }

    function test_extern_optional_absentIsAZeroAddress_whileTheCanonicalAddressHoldsNoCode() public {
        _network("extern-absent", vm.toString(ops));
        (AtToy t, address ext) = _atFixture();
        vm.etch(ext, "");
        _atInput('"absent"');
        assertEq(t.atExt(network), address(0));
        assertEq(t.readOther(network), address(0));
    }

    function test_extern_optional_refusesAbsenceOnceCodeAppears_onEveryRead() public {
        _network("extern-absent-code", vm.toString(ops));
        (AtToy t, address ext) = _atFixture();
        vm.etch(ext, "");
        _atInput('"absent"');
        assertEq(t.atExt(network), address(0));

        vm.etch(ext, hex"00");
        bytes memory reason = bytes(
            string.concat("ext is absent in the input, but ", vm.toString(ext), " holds code: name it in the input")
        );
        vm.expectRevert(reason);
        t.atExt(network);
        vm.expectRevert(reason);
        t.readOther(network);
    }

    function test_extern_requiredOn_refusesAbsenceOnThatChain_only() public {
        _network("extern-required", vm.toString(ops));
        (AtToy t, address ext) = _atFixture();
        vm.etch(ext, "");
        _atInput('"absent"');
        assertEq(t.atExt(network), address(0));
        t.setRequired(31337);
        vm.expectRevert(bytes("ext is required on chain 31337: name it in the input"));
        t.atExt(network);
        vm.expectRevert(bytes("ext is required on chain 31337: name it in the input"));
        t.readOther(network);
    }

    function test_extern_at_refusesAnEarlierProof_whenTheCodeAppearsInTheSameStep() public {
        _network("extern-twice-absent", vm.toString(ops));
        (AtToy t, address ext) = _atFixture();
        vm.etch(ext, "");
        _atInput('"absent"');
        vm.expectRevert(
            bytes(
                string.concat("ext is absent in the input, but ", vm.toString(ext), " holds code: name it in the input")
            )
        );
        t.atExtTwice(network, hex"00");
    }

    function test_extern_at_refusesAnEarlierProof_whenThePinnedCodeChangesInTheSameStep() public {
        _network("extern-twice-code", vm.toString(ops));
        (AtToy t, address ext) = _atFixture();
        _atInput(string.concat('"', vm.toString(ext), '"'));
        vm.expectRevert(bytes("ext's code is not the code its role pins"));
        t.atExtTwice(network, hex"00");
    }

    function test_extern_at_sameStepReadsAgree_whenNothingChanges() public {
        _network("extern-twice-same", vm.toString(ops));
        (AtToy t, address ext) = _atFixture();
        _atInput(string.concat('"', vm.toString(ext), '"'));
        (address a, address b) = t.atExtTwice(network, ext.code);
        assertEq(a, ext);
        assertEq(b, ext);
    }

    function test_extern_endCheck_refusesAStaleAbsence() public {
        _network("extern-end-absent", vm.toString(ops));
        (AtToy t, address ext) = _atFixture();
        vm.etch(ext, "");
        _atInput('"absent"');
        vm.expectRevert(
            bytes(
                string.concat("ext is absent in the input, but ", vm.toString(ext), " holds code: name it in the input")
            )
        );
        t.endAfter(network, hex"00");
    }

    function test_extern_at_runsEnsureOnTheFirstPresentReadOfAStep() public {
        _network("extern-ensure-transition", vm.toString(ops));
        (AtToy t, address ext) = _atFixture();
        t.setCode(ext.code);
        t.setRejects();
        vm.etch(ext, "");
        _atInput('"absent"');
        vm.expectRevert(bytes("ext's ensure rejects"));
        t.absentThenPresent(
            network, string.concat(dir, "/at.input.json"), string.concat('{"ext":"', vm.toString(ext), '"}')
        );
    }

    function test_extern_at_refusesTheZeroAddress() public {
        vm.expectRevert(bytes("ext's .at is the zero address"));
        this.buildAtZero();
    }

    function buildAtZero() external pure {
        extern("ext", bytes32(0)).at(address(0));
    }

    function test_extern_requiredOn_accumulates() public {
        Role memory r = extern("ext", bytes32(0)).at(address(1)).optional().requiredOn(5).requiredOn(6);
        assertEq(r.requiredChains.length, 2);
        assertEq(r.requiredChains[0], 5);
        assertEq(r.requiredChains[1], 6);
    }

    function test_extern_requiredOn_acceptsAPresentInput() public {
        _network("extern-required-present", vm.toString(ops));
        (AtToy t, address ext) = _atFixture();
        _atInput(string.concat('"', vm.toString(ext), '"'));
        t.setRequired(31337);
        assertEq(t.atExt(network), ext);
    }

    function test_extern_builders_refuseWhatTheyCannotMean() public {
        Role memory r = extern("ext", bytes32(0));
        assertEq(r.key, "ext");
        vm.expectRevert(bytes("ext's .optional needs .at: absence is proven at one address"));
        this.buildOptional();
        vm.expectRevert(bytes("ext's .requiredOn needs .optional first"));
        this.buildRequiredOn();
        vm.expectRevert(bytes("t's .at is for an extern role"));
        this.buildAtOnCreate();
    }

    function buildOptional() external pure {
        extern("ext", bytes32(0)).optional();
    }

    function buildRequiredOn() external pure {
        extern("ext", bytes32(0)).requiredOn(1);
    }

    function buildAtOnCreate() external pure {
        create("t", "ToyPayload").at(address(1));
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

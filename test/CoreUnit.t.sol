// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {unitInputHash, unitInputPath} from "../src/Journal.sol";
import {Probes} from "../src/Probes.sol";
import {Unit} from "../src/Unit.sol";
import {ToyPayload} from "./ToyPayload.sol";
import {DirtyToyUnit, ToyUnit} from "./ToyUnit.sol";

/// @dev `Unit` over this repository's `sprue.json`.
contract UnitHarness is Unit {
    function _unit() internal pure override returns (string memory) {
        return "harness";
    }

    function requireTestChain() external view {
        _requireTestChain();
    }
}

/// @notice The unit layer (`Journal`, `ForgeBroadcasts`, `Deployment`) with a unit of its own and no
///         project: the nonce fence, the deployer pin, `_deployIdentified`, recovery and certificates.
contract CoreUnitTest is Test {
    uint256 private constant FENCED = 777;
    uint256 private constant FREE = 31337;
    string private constant OPT_IN = "CORE_TEST_UNEXPECTED_DEPLOYER";
    string private constant DIRTY = "CORE_TEST_DIRTY_MARK";
    string private constant SCRIPT = "ToyUnit.sol";

    address private ops = makeAddr("ops");
    address private other = makeAddr("other key");
    ToyUnit private unit = new ToyUnit();
    string private network;
    string private dir;

    // ==== The nonce fence ====

    function test_fence_aJournalLostWithItsRecords_refusesASecondDeploymentAtTheSendersNonce() public {
        _network("lost", FENCED, "");
        unit.deploy(network);
        address lost = _journalOf("toy", ".toy");
        vm.removeFile(string.concat(dir, "/toy.json"));

        vm.expectRevert(bytes(_refusal(lost, ops, 0)));
        unit.deploy(network);
        vm.stopBroadcast();
    }

    function test_fence_theLastUsedNonceIsRead_fromBothEntryPoints_andARetiredAddressPasses() public {
        _network("last", FENCED, "");
        _record("known", _stray(ops), ops, 0);
        vm.setNonce(ops, 2);
        address lost = _stray(ops);

        vm.expectRevert(bytes(_refusal(lost, ops, 2)));
        unit.landed(network, ops);
        vm.expectRevert(bytes(_refusal(lost, ops, 2)));
        unit.recordedRole(network);

        vm.writeFile(string.concat(dir, "/toy.json"), string.concat('{"retired": ["', vm.toString(lost), '"]}'));
        assertEq(unit.landed(network, ops), address(0));
        assertEq(unit.recordedRole(network), address(0));
    }

    function test_fence_aMalformedInput_doesNotAbortIt() public {
        _network("malformed-input", FENCED, "");
        _record("known", _stray(ops), ops, 0);
        vm.writeFile(string.concat(dir, "/toy.input.json"), "not json");
        assertEq(unit.landed(network, ops), address(0));
    }

    /// @dev A dependency field names an address without saying who made it; a role record with
    ///      another code hash is another chain's deployment at the same nonce.
    function test_fence_onlyARoleRecordWithItsCodeHash_accountsForAnAddress() public {
        _network("named", FENCED, "");
        address x = _stray(ops);
        vm.writeFile(string.concat(dir, "/other.json"), string.concat('{"dependency": "', vm.toString(x), '"}'));
        vm.expectRevert(bytes(_refusal(x, ops, 0)));
        unit.landed(network, ops);

        _record("source", x, ops, 0);
        vm.writeJson(
            vm.toString(keccak256("another chain's code")), string.concat(dir, "/source.json"), ".sourceCodeHash"
        );
        vm.expectRevert(bytes(_refusal(x, ops, 0)));
        unit.landed(network, ops);

        _record("source", x, ops, 0);
        assertEq(unit.landed(network, ops), address(0));
    }

    /// @dev The intent's nonce was used by another transaction, so the step would deploy afresh.
    function test_fence_aLostIntent_isFencedLikeAnAbsentRole() public {
        _network("intent", FENCED, "");
        address intent = vm.computeCreateAddress(ops, 0);
        vm.setNonce(ops, 1);
        address lost = _stray(ops);
        vm.writeFile(
            string.concat(dir, "/toy.json"),
            string.concat(
                '{"toy": "', vm.toString(intent), '", "toyDeployer": "', vm.toString(ops), '", "toyNonce": 0}'
            )
        );

        vm.expectRevert(bytes(_refusal(lost, ops, 1)));
        unit.landed(network, ops);
        vm.expectRevert(bytes(_refusal(lost, ops, 1)));
        unit.recordedRole(network);
    }

    function test_fence_everyRecordedDeployerIsRead() public {
        _network("deployers", FENCED, "");
        _record("known", _stray(other), other, 0);
        address lost = _stray(other);

        vm.expectRevert(bytes(_refusal(lost, other, 1)));
        unit.landed(network, ops);
        vm.expectRevert(bytes(_refusal(lost, other, 1)));
        unit.recordedRole(network);
    }

    /// @dev No journal records the pinned key, and the due view has no sender of its own.
    function test_fence_theNetworksPinnedDeployer_isRead() public {
        _network("pinned", FENCED, vm.toString(ops));
        address lost = _stray(ops);

        vm.expectRevert(bytes(_refusal(lost, ops, 0)));
        unit.recordedRole(network);
        vm.expectRevert(bytes(_refusal(lost, ops, 0)));
        unit.landed(network, other);
    }

    function test_fence_aDeployerPastTheBound_isRefused() public {
        _network("bound", FENCED, "");
        vm.setNonce(ops, 256);
        assertEq(unit.landed(network, ops), address(0));

        vm.setNonce(ops, 257);
        vm.expectRevert(
            bytes(
                string.concat(
                    vm.toString(ops),
                    " has used more nonces than the fence reads: a person must account for its deployments, or use a fresh deploy key, or list the chain in chains.unrecordedDeploys[<id>]"
                )
            )
        );
        unit.landed(network, ops);
    }

    /// @dev Read where the graph reads it, `paths.deployments`, though the unit's own files are elsewhere.
    function test_check_recordsTheGraphsHashOfTheUnitsInput_whenItHasOne() public {
        _network("input-hash", FREE, "");
        unit.deploy(network);
        unit.check(network);
        assertFalse(vm.keyExistsJson(vm.readFile(string.concat(dir, "/toy.json")), ".checked.inputHash"));

        string memory input = unitInputPath(network, "toy");
        vm.createDir(string.concat("deployments/", network), true);
        vm.writeFile(input, '{"n":1,"m":"x"}');
        unit.check(network);
        bytes32 recorded = vm.parseJsonBytes32(vm.readFile(string.concat(dir, "/toy.json")), ".checked.inputHash");
        assertEq(recorded, unitInputHash(network, "toy"));
        vm.writeFile(input, '{ "m": "x",\n  "n": 1 }\n');
        assertEq(unitInputHash(network, "toy"), recorded, "a formatting edit changed the hash");
        vm.writeFile(input, '{"n":2,"m":"x"}');
        assertTrue(unitInputHash(network, "toy") != recorded);
        vm.removeDir(string.concat("deployments/", network), true);
    }

    // ==== The deployer pin ====

    function test_fence_appliesOnlyWhereTheProjectFencesAChain() public {
        _network("unfenced", FREE, "");
        _stray(ops);
        assertEq(unit.landed(network, ops), address(0));
    }

    function test_pin_aRerunThatSendsNothing_passesWithAnySender() public {
        _network("rerun", FREE, vm.toString(ops));
        unit.deploy(network);

        unit.setTestSender(other);
        unit.deploy(network);
        unit.check(network);
        assertEq(vm.getNonce(other), 0);
    }

    function test_pin_aMalformedZeroOrForgesDefaultPin_isRefusedBeforeAnySend() public {
        string[5] memory pins =
            ["not an address", "0x1234", "ops", vm.toString(address(0)), vm.toString(DEFAULT_SENDER)];
        for (uint256 i; i < pins.length; ++i) {
            _network("bad-pin", FREE, pins[i]);
            if (i < 3) {
                vm.expectRevert();
            } else {
                vm.expectRevert(
                    "network.json's deployer is the zero or forge's default address: fix it, or remove the field"
                );
            }
            unit.deploy(network);
            vm.stopBroadcast();
            assertFalse(vm.exists(string.concat(dir, "/toy.json")));
        }
    }

    /// @dev The toy reads a variable of its own, so no other suite sees it.
    function test_pin_theDefaultOptIn_isTheVariableExactly1() public {
        string[4] memory refused = ["", "true", "0", "yes"];
        for (uint256 i; i < refused.length; ++i) {
            vm.setEnv(OPT_IN, refused[i]);
            assertFalse(unit.envAllows(), refused[i]);
        }
        vm.setEnv(OPT_IN, "1");
        assertTrue(unit.envAllows());
        vm.setEnv(OPT_IN, "");
    }

    // ==== _deployIdentified ====

    function test_deploy_journalsTheIntentBeforeTheAddress_andTheHookRunsOnlyForANewDeployment() public {
        _network("hook", FREE, "");

        assertEq(
            unit.deploy(network),
            string.concat("forge script toy.s.sol --sig 'plan(string,string)' ", network, " <node> --rpc-url main")
        );
        assertEq(unit.hooks(), 1);
        assertFalse(unit.journaledAtHook(), "the hook ran after the address was journaled");
        string memory m = vm.readFile(string.concat(dir, "/toy.json"));
        assertEq(vm.parseJsonUint(m, ".mainChainId"), block.chainid);
        assertEq(vm.parseJsonBytes(m, ".toyArgs"), abi.encode(1));
        assertEq(
            vm.parseJsonBytes32(m, ".toyInitcodeHash"),
            keccak256(bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(1)))
        );
        assertEq(vm.parseJsonString(m, ".toyCommit"), "pending");

        unit.deploy(network);
        assertEq(unit.hooks(), 1, "a landed role was a new deployment");
    }

    /// @dev A pending intent is sent again only as the same transaction: the sender at the
    ///      recorded nonce, with the recorded initcode.
    function test_deploy_aPendingIntent_isSentAgainOnlyAsTheSameTransaction() public {
        _network("pending", FREE, "");
        uint256 nonce = vm.getNonce(ops);
        uint256 before = vm.snapshotState();
        unit.deploy(network);
        address intent = _journalOf("toy", ".toy");
        vm.revertToState(before);
        assertEq(intent.code.length, 0);

        unit.setTag(2);
        vm.expectRevert(bytes(_pending(nonce, ops)));
        unit.deploy(network);
        vm.stopBroadcast();
        unit.setTag(1);

        unit.setTestSender(other);
        vm.setNonce(other, uint64(nonce));
        vm.expectRevert(bytes(_pending(nonce, ops)));
        unit.deploy(network);
        vm.stopBroadcast();

        unit.setTestSender(ops);
        unit.deploy(network);
        assertGt(intent.code.length, 0);
        assertEq(_journalOf("toy", ".toy"), intent);
        assertEq(vm.getNonce(ops), nonce + 1);
    }

    function test_deploy_anIntentAtALaterNonceThanTheSenders_isRefused() public {
        _network("later-nonce", FREE, "");
        uint256 nonce = vm.getNonce(ops);
        uint256 before = vm.snapshotState();
        unit.deploy(network);
        vm.revertToState(before);
        string memory path = string.concat(dir, "/toy.json");
        vm.writeJson(vm.toString(nonce + 1), path, ".toyNonce");
        vm.writeJson(vm.toString(vm.computeCreateAddress(ops, nonce + 1)), path, ".toy");

        vm.expectRevert(bytes(_pending(nonce + 1, ops)));
        unit.deploy(network);
        vm.stopBroadcast();

        address elsewhere = vm.computeCreateAddress(ops, nonce);
        vm.writeJson(vm.toString(elsewhere), path, ".toy");
        vm.expectRevert(
            bytes(string.concat(vm.toString(elsewhere), " is not the recorded deployer's CREATE at the recorded nonce"))
        );
        unit.deploy(network);
        vm.stopBroadcast();
    }

    /// @dev The journal would take a receipt if the refusal came after `_recordDeployment`; a
    ///      revert does not undo a file write.
    function test_deploy_authenticatesAReusedAddressBeforeAnyJournalWrite() public {
        _network("authenticate", FREE, "");
        unit.deploy(network);
        string memory path = string.concat(dir, "/toy.json");
        string memory journal = vm.readFile(path);
        unit.setRefuseReuse(true);

        vm.expectRevert(bytes("the check refused the reuse"));
        unit.deploy(network);
        vm.stopBroadcast();
        assertEq(vm.readFile(path), journal);
    }

    function test_theRunnerExportsTheVariablesTheCoreReads() public {
        (string memory optIn, string memory dirty) = unit.defaultVariables();
        string memory runner = vm.readFile("bin/sprue.mjs");
        assertTrue(vm.contains(runner, string.concat("process.env.", optIn, ' = "1"')), optIn);
        assertTrue(vm.contains(runner, string.concat("process.env.", dirty, " = ")), dirty);
    }

    function test_deploy_aRecordedRoleKeepsTheCodeItsJournalNames() public {
        _network("recorded-code", FREE, "");
        unit.deploy(network);
        string memory path = string.concat(dir, "/toy.json");
        string memory journal = vm.readFile(path);

        vm.writeJson(vm.toString(bytes32(uint256(1))), path, ".toyCodeHash");
        vm.expectRevert(bytes("toy's code differs from toy.json"));
        unit.landed(network, ops);
        vm.expectRevert(bytes("toy's code differs from toy.json"));
        unit.recordedRole(network);
        address toy = _journalOf("toy", ".toy");
        bytes memory code = toy.code;
        vm.etch(toy, "");
        vm.expectRevert(bytes(_noCode("toy", toy)));
        unit.check(network);
        vm.etch(toy, code);

        vm.writeFile(path, vm.replace(journal, '"toyCodeHash"', '"toyCodeHashX"'));
        vm.expectRevert(bytes("toy.json records no toyCodeHash"));
        unit.landed(network, ops);

        vm.writeJson(vm.toString(address(0)), path, ".toy");
        vm.expectRevert(bytes("journal toy is the zero address"));
        unit.landed(network, ops);
    }

    function test_deploy_aSimulationJournalsNothing() public {
        _network("simulation", FREE, "");
        unit.simulate();

        unit.deploy(network);

        assertFalse(vm.exists(string.concat(dir, "/toy.json")));
        assertEq(unit.hooks(), 0);
    }

    function test_deploy_recordsTheReceiptOnlyTheChainConfirms() public {
        _network("receipt", FREE, "");
        unit.deploy(network);
        address addr = _journalOf("toy", ".toy");
        bytes32 first = keccak256("a send of the same address that failed");
        bytes32 hash = keccak256("the payload's creation");
        string memory path = string.concat(dir, "/toy.json");
        _writeReceipts("run-latest.json", '"abc1234"', addr, first, hash);

        unit.deploy(network);
        assertFalse(vm.keyExistsJson(vm.readFile(path), ".toyTx"), "an unconfirmed receipt was recorded");
        assertEq(vm.parseJsonString(vm.readFile(path), ".toyCommit"), "pending");

        unit.confirm(hash);
        unit.deploy(network);
        string memory m = vm.readFile(path);
        assertEq(vm.parseJsonBytes32(m, ".toyTx"), hash);
        assertEq(vm.parseJsonUint(m, ".toyBlock"), 5);
        assertEq(vm.parseJsonString(m, ".toyCommit"), "abc1234");

        bytes32 later = keccak256("a later record");
        _writeReceipts("run-later.json", '"abc1234"', addr, later, later);
        unit.confirm(later);
        unit.deploy(network);
        assertEq(vm.parseJsonBytes32(vm.readFile(path), ".toyTx"), hash, "a recorded receipt was replaced");
    }

    /// @dev forge simulates a send in an earlier block than the one it lands in, so a constructor that stores
    ///      `block.timestamp` in an immutable lands with another code hash than the journal's simulated one.
    function test_deploy_aRoleThatLandedWithOtherCodeThanItsSimulation_isProvenByItsCreationInput() public {
        _network("landed-code", FREE, "");
        unit.deploy(network);
        address addr = _journalOf("toy", ".toy");
        vm.etch(addr, bytes.concat(addr.code, hex"00")); // unreachable: the same behaviour, another code hash
        bytes32 hash = keccak256("the payload's creation");
        _writeReceipts("run-latest.json", '"abc1234"', addr, hash, hash);
        unit.confirm(hash);
        string memory path = string.concat(dir, "/toy.json");
        string memory simulated = vm.readFile(path);

        assertFalse(Probes.due(address(unit), abi.encodeCall(ToyUnit.deploy, (network)), ops));
        assertEq(vm.readFile(path), simulated, "a probe journaled the landed code");
        unit.send(bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(uint256(2))));
        vm.expectRevert(bytes("toy's code differs from toy.json"));
        unit.deploy(network);
        vm.stopBroadcast();

        unit.send("");
        vm.writeJson(vm.toString(keccak256("a transaction that created no toy")), path, ".toyTx");
        vm.expectRevert(bytes("toy's code differs from toy.json"));
        unit.deploy(network);
        vm.stopBroadcast();

        vm.writeFile(path, simulated);
        unit.deploy(network);
        assertEq(vm.parseJsonBytes32(vm.readFile(path), ".toyCodeHash"), addr.codehash);
        unit.check(network);
    }

    /// @dev Only the unit's own script's records are read: its runs on this chain and its multi-chain runs.
    function test_recordReceipt_readsOnlyTheScriptsOwnRecords_ofThisChainOrAMultiChainRun() public {
        _network("receipt-own", FREE, "");
        unit.deploy(network);
        address addr = _journalOf("toy", ".toy");
        string memory path = string.concat(dir, "/toy.json");
        bytes32 hash = keccak256("the payload's creation");
        unit.confirm(hash);
        string memory run = string.concat(
            '{"chain": ',
            vm.toString(block.chainid),
            ', "transactions": [], "receipts": [{"contractAddress": "',
            vm.toLowercase(vm.toString(addr)),
            '", "transactionHash": "',
            vm.toString(hash),
            '"}]}'
        );
        string[2] memory elsewhere = [
            string.concat("/broadcast/DeployOther.s.sol/", vm.toString(block.chainid)),
            string.concat("/broadcast/", SCRIPT, "/1")
        ];
        for (uint256 i; i < elsewhere.length; ++i) {
            vm.createDir(string.concat(dir, elsewhere[i]), true);
            vm.writeFile(string.concat(dir, elsewhere[i], "/deploy-latest.json"), run);
        }
        unit.check(network);
        assertFalse(vm.keyExistsJson(vm.readFile(path), ".toyTx"), "another script's or chain's record was read");

        string memory multi = string.concat(dir, "/broadcast/multi/", SCRIPT, "-latest");
        vm.createDir(multi, true);
        vm.writeFile(string.concat(multi, "/deploy.json"), string.concat('{"deployments": [', run, "]}"));
        unit.check(network);
        assertEq(vm.parseJsonBytes32(vm.readFile(path), ".toyTx"), hash, "the multi-chain run's receipt");
    }

    /// @dev With no record, only the chain can show a creation, and only of a role the project
    ///      created: one with a nonce. `forge test` has no RPC.
    function test_recordReceipt_withNoRecord_findsNothingWithoutAnRpcOrTheRolesNonce() public {
        _network("no-record", FREE, "");
        unit.deploy(network);
        string memory path = string.concat(dir, "/toy.json");

        unit.check(network);
        assertFalse(vm.keyExistsJson(vm.readFile(path), ".toyTx"));

        vm.writeFile(path, vm.replace(vm.readFile(path), '"toyNonce"', '"toyNonceX"'));
        unit.check(network);
        assertFalse(vm.keyExistsJson(vm.readFile(path), ".toyTx"));
    }

    /// @dev forge writes `null` for a run outside git, and a commit already journaled is not replaced.
    /// @dev An intent whose nonce another transaction used can never land: the step deploys afresh, and a
    ///      clean send over the dirty mark that intent left clears it.
    function test_deploy_aCleanSendOverASpentIntentClearsItsDirtyMark() public {
        _network("dirty", FREE, "");
        DirtyToyUnit dirty = new DirtyToyUnit();
        dirty.setTestSender(ops);
        string memory path = string.concat(dir, "/toy.json");
        uint256 nonce = vm.getNonce(ops);
        vm.setEnv(DIRTY, "1");
        uint256 before = vm.snapshotState();
        dirty.deploy(network);
        address first = _journalOf("toy", ".toy");
        assertTrue(vm.parseJsonBool(vm.readFile(path), ".toyDirty"));

        vm.revertToState(before);
        vm.setNonce(ops, uint64(nonce + 1));
        vm.setEnv(DIRTY, "");
        dirty.deploy(network);

        string memory m = vm.readFile(path);
        assertEq(vm.parseJsonAddress(m, ".toy"), vm.computeCreateAddress(ops, nonce + 1));
        assertTrue(vm.parseJsonAddress(m, ".toy") != first);
        assertFalse(vm.parseJsonBool(m, ".toyDirty"));
    }

    function test_deploy_theCommitStaysPendingOnNull_andOnlyPendingIsReplaced() public {
        bytes32 hash = keccak256("the payload's creation");
        unit.confirm(hash);
        string[2] memory commits = ["null", '"abc1234"'];
        string[2] memory kept = ["pending", "feedbee"];
        for (uint256 i; i < commits.length; ++i) {
            _network(string.concat("commit-", vm.toString(i)), FREE, "");
            unit.deploy(network);
            string memory path = string.concat(dir, "/toy.json");
            if (i == 1) vm.writeJson('"feedbee"', path, ".toyCommit");
            _writeReceipts("run-latest.json", commits[i], _journalOf("toy", ".toy"), hash, hash);

            unit.deploy(network);
            assertEq(vm.parseJsonBytes32(vm.readFile(path), ".toyTx"), hash);
            assertEq(vm.parseJsonString(vm.readFile(path), ".toyCommit"), kept[i]);
        }
    }

    // ==== Recovery ====

    function test_recover_rebuildsALostJournal_equalOnEveryKeyADeployWrites_thenEveryStepSendsNothing() public {
        string memory lost = _lose("recover");
        _writeRecord(_run(block.chainid, _sent(lost, ops)));
        vm.writeFile(
            string.concat(dir, "/broadcast/", SCRIPT, "/", vm.toString(block.chainid), "/0-latest.recovery.lock"), ""
        );

        unit.recover(network);

        string memory got = vm.readFile(string.concat(dir, "/toy.json"));
        string[] memory keys = vm.parseJsonKeys(lost, "$");
        for (uint256 i; i < keys.length; ++i) {
            string memory key = string.concat(".", keys[i]);
            assertTrue(vm.keyExistsJson(got, key), keys[i]);
            assertEq(vm.parseJson(got, key), vm.parseJson(lost, key), keys[i]);
        }
        assertEq(vm.parseJsonKeys(got, "$").length, keys.length, "recover wrote a key no deploy step wrote");

        uint256 nonce = vm.getNonce(ops);
        vm.recordLogs();
        unit.deploy(network);
        unit.check(network);
        assertEq(vm.getRecordedLogs().length, 0, "a step after recover sent a transaction");
        assertEq(vm.getNonce(ops), nonce);
    }

    /// @dev Each run of a multi-chain record carries its own commit.
    function test_recover_readsAMultiChainRunsRecord_andItsCommit() public {
        string memory lost = _lose("recover-multi");
        _writeRecord(
            string.concat(
                '{"deployments": [{"chain": 1, "commit": "1111111", "transactions": []}, {"chain": ',
                vm.toString(block.chainid),
                ', "commit": "abc1234", "transactions": [',
                _sent(lost, ops),
                "]}]}"
            )
        );

        unit.recover(network);

        assertEq(vm.parseJsonString(vm.readFile(string.concat(dir, "/toy.json")), ".toyCommit"), "abc1234");
    }

    function test_recover_refusesTwoLandedCandidates() public {
        string memory lost = _lose("recover-two");
        uint256 nonce = vm.getNonce(ops);
        address second = _stray(ops);
        _writeRecord(
            _run(
                block.chainid,
                string.concat(_sent(lost, ops), ", ", _create("ToyPayload", second, ops, nonce, _initcode(9)))
            )
        );

        vm.expectRevert(
            bytes(
                string.concat(
                    "toy.json lacks toy, and ",
                    vm.toString(ops),
                    " created ToyPayload at ",
                    vm.toString(_addressOf(lost)),
                    ", ",
                    vm.toString(second),
                    ": a person must choose"
                )
            )
        );
        unit.recover(network);
    }

    /// @dev A transaction replaced at the same nonce: which one landed is the chain's to say.
    function test_recover_refusesOneAddressRecordedWithDifferentInitcode() public {
        string memory lost = _lose("recover-replaced");
        string memory replaced =
            _create("ToyPayload", _addressOf(lost), ops, vm.parseJsonUint(lost, ".toyNonce"), _initcode(9));
        _writeRecord(_run(block.chainid, string.concat(_sent(lost, ops), ", ", replaced)));

        vm.expectRevert(
            bytes(
                string.concat(
                    "toy.json lacks toy, and the records create ToyPayload at ",
                    vm.toString(_addressOf(lost)),
                    " with different initcode: a person must choose"
                )
            )
        );
        unit.recover(network);
    }

    /// @dev Authentic, and an earlier deployment: a constructor argument the code does not show.
    function test_recover_refusesAnEarlierDeploymentFromOtherInputs() public {
        _network("recover-other-input", FREE, "");
        uint256 nonce = vm.getNonce(ops);
        address earlier = _stray(ops);
        _writeRecord(_run(block.chainid, _create("ToyPayload", earlier, ops, nonce, _initcode(9))));

        vm.expectRevert(bytes(_notCurrent(earlier)));
        unit.recover(network);
        assertFalse(vm.exists(string.concat(dir, "/toy.json")), "a refused recover wrote the journal");
    }

    function test_recover_refusesARecordNotAtItsSendersNonce_writingNothing() public {
        string memory lost = _lose("recover-wrong-nonce");
        _writeRecord(
            _run(
                block.chainid,
                _create("ToyPayload", _addressOf(lost), ops, vm.parseJsonUint(lost, ".toyNonce") + 1, _initcode(1))
            )
        );

        vm.expectRevert(bytes("a deployment is not at its sender's nonce"));
        unit.recover(network);
        assertFalse(vm.exists(string.concat(dir, "/toy.json")), "a refused recovery wrote the journal");
    }

    function test_recover_refusesARecordWithoutCodeThatMayStillLand() public {
        string memory lost = _lose("recover-pending");
        uint256 next = vm.getNonce(ops);
        address queued = vm.computeCreateAddress(ops, next);
        _writeRecord(
            _run(
                block.chainid,
                string.concat(_sent(lost, ops), ", ", _create("ToyPayload", queued, ops, next, _initcode(1)))
            )
        );

        vm.expectRevert(
            bytes(
                string.concat(
                    "toy.json lacks toy, yet ",
                    _recordPath(),
                    " holds a CREATE of ToyPayload at ",
                    vm.toString(queued),
                    " that may still land: wait, or spend the nonce"
                )
            )
        );
        unit.recover(network);
    }

    function test_recover_refusesARoleWhoseOtherKeysSurvive() public {
        string memory lost = _lose("recover-partial");
        vm.writeFile(string.concat(dir, "/toy.json"), '{"toyNonce": 1}');
        _writeRecord(_run(block.chainid, _sent(lost, ops)));

        vm.expectRevert(bytes("toy.json holds toyNonce but not toy: a person must resolve it"));
        unit.recover(network);

        vm.writeFile(string.concat(dir, "/toy.json"), '{"toyz": 1}');
        unit.recover(network);
        assertTrue(
            vm.keyExistsJson(vm.readFile(string.concat(dir, "/toy.json")), ".toy"),
            "only <role><Upper> keys belong to a role"
        );
    }

    function test_recover_skipsACandidateTheJournalRetired() public {
        string memory lost = _lose("recover-retired");
        vm.writeFile(
            string.concat(dir, "/toy.json"), string.concat('{"retired": ["', vm.toString(_addressOf(lost)), '"]}')
        );
        _writeRecord(_run(block.chainid, _sent(lost, ops)));

        unit.recover(network);

        assertFalse(
            vm.keyExistsJson(vm.readFile(string.concat(dir, "/toy.json")), ".toy"), "recover adopted a retired role"
        );
    }

    /// @dev Another sender's CREATE is not this project's to adopt, so the stray guard keeps refusing it and
    ///      names the unit's own recovery script.
    function test_recover_ignoresAnotherSendersRecords_andTheStrayGuardNamesTheCommand() public {
        string memory lost = _lose("recover-other-sender");
        address someone = makeAddr("someone else");
        _writeRecord(_run(block.chainid, _sent(lost, someone)));

        unit.recover(network);
        assertFalse(vm.exists(string.concat(dir, "/toy.json")), "recover adopted another sender's deployment");

        vm.expectRevert(
            bytes(
                string.concat(
                    "toy.json lacks toy, yet ",
                    _recordPath(),
                    " holds a CREATE of ToyPayload at ",
                    vm.toString(_addressOf(lost)),
                    " that landed or may land: restore the journal, or rebuild it: forge script ",
                    "test/ToyUnit.sol --sig 'recover(string)' ",
                    network,
                    " --rpc-url main --sender ",
                    vm.toString(someone)
                )
            )
        );
        unit.deploy(network);
        vm.stopBroadcast();
    }

    function test_done_onARehearsalNetworkPrintsThePlanWithItsOutputsPrefix() public {
        _network("rehearsal-core-next", FREE, "");
        assertEq(
            unit.deploy(network),
            string.concat(
                "FOUNDRY_BROADCAST=",
                dir,
                "/broadcast FOUNDRY_CACHE_PATH=",
                dir,
                "/cache forge script toy.s.sol --sig 'plan(string,string)' ",
                network,
                " <node> --rpc-url main"
            )
        );
    }

    /// @dev A rehearsal network's step refuses to run without its outputs prefix, so its command has it.
    function test_recover_commandOnARehearsalNetworkKeepsForgesOutputsThere() public {
        string memory lost = _lose("rehearsal-core-recover");
        address someone = makeAddr("someone else");
        _writeRecord(_run(block.chainid, _sent(lost, someone)));

        vm.expectRevert(
            bytes(
                string.concat(
                    "toy.json lacks toy, yet ",
                    _recordPath(),
                    " holds a CREATE of ToyPayload at ",
                    vm.toString(_addressOf(lost)),
                    " that landed or may land: restore the journal, or rebuild it: FOUNDRY_BROADCAST=",
                    dir,
                    "/broadcast FOUNDRY_CACHE_PATH=",
                    dir,
                    "/cache forge script test/ToyUnit.sol --sig 'recover(string)' ",
                    network,
                    " --rpc-url main --sender ",
                    vm.toString(someone)
                )
            )
        );
        unit.deploy(network);
        vm.stopBroadcast();
    }

    function test_recover_ignoresAnotherChainsRecords() public {
        string memory lost = _lose("recover-other-chain");
        _writeRecord(_run(1, _sent(lost, ops)));

        unit.recover(network);

        assertFalse(vm.exists(string.concat(dir, "/toy.json")), "recover read another chain's record");
    }

    /// @dev A factory call fixes no nonce: recovery leaves it, and the stray guard refuses a fresh
    ///      deployment over it without a recover command.
    function test_recover_excludesCreate2_andTheStrayGuardRefusesIt() public {
        string memory lost = _lose("recover-create2");
        address addr = _addressOf(lost);
        string memory create2 =
            vm.replace(_sent(lost, ops), '"transactionType": "CREATE"', '"transactionType": "CREATE2"');
        _writeRecord(_run(block.chainid, create2));

        unit.recover(network);
        assertFalse(vm.exists(string.concat(dir, "/toy.json")), "recover adopted a CREATE2");

        bytes memory stray = bytes(
            string.concat(
                "toy.json lacks toy, yet ",
                _recordPath(),
                " holds a CREATE2 of ToyPayload at ",
                vm.toString(addr),
                " that landed or may land: restore the journal"
            )
        );
        vm.expectRevert(stray);
        unit.deploy(network);
        vm.stopBroadcast();
        vm.expectRevert(stray);
        unit.deploy2(network, bytes32(0), address(0xC2));
    }

    /// @dev A second landed `ToyPayload` in the records would refuse any recovery of a role the
    ///      journal lacks.
    function test_recover_ofACompleteJournal_sendsAndWritesNothing() public {
        string memory journal = _lose("recover-complete");
        vm.writeFile(string.concat(dir, "/toy.json"), journal);
        uint256 nonce = vm.getNonce(ops);
        address second = _stray(ops);
        _writeRecord(
            _run(
                block.chainid,
                string.concat(_sent(journal, ops), ", ", _create("ToyPayload", second, ops, nonce, _initcode(9)))
            )
        );
        vm.recordLogs();

        unit.recover(network);

        assertEq(vm.readFile(string.concat(dir, "/toy.json")), journal, "recover changed a complete journal");
        assertEq(vm.getRecordedLogs().length, 0, "recover sent a transaction");
        assertEq(vm.getNonce(ops), nonce + 1);
    }

    /// @dev A CREATE2 at the address a step is about to adopt is that role itself, and nothing else is.
    function test_stray_aCreate2AtTheAdoptedAddress_isTheRoleItself() public {
        string memory lost = _lose("stray-adopted");
        address addr = _addressOf(lost);
        _writeRecord(
            _run(
                block.chainid,
                vm.replace(_sent(lost, ops), '"transactionType": "CREATE"', '"transactionType": "CREATE2"')
            )
        );

        unit.requireNoStray(network, addr);
        vm.expectRevert();
        unit.requireNoStray(network, makeAddr("another address"));
    }

    /// @dev A queued transaction may still land; a record whose nonce another transaction used cannot.
    function test_stray_aRecordWithoutCodeIsRefusedUntilItsNonceIsUsed() public {
        _network("stray-queued", FREE, "");
        uint256 next = vm.getNonce(ops);
        address queued = vm.computeCreateAddress(ops, next);
        _writeRecord(_run(block.chainid, _create("ToyPayload", queued, ops, next, _initcode(1))));

        vm.expectRevert();
        unit.requireNoStray(network, address(0));

        vm.setNonce(ops, uint64(next + 1));
        unit.requireNoStray(network, address(0));
    }

    // ==== Certificates ====

    function test_checked_refusesAMissingWrongChainCodelessOrChangedCertificate() public {
        _deployChecked("checked-refused");
        string memory path = string.concat(dir, "/toy.json");
        string memory checked = vm.readFile(path);

        // A wrong value on each side of the right one, so no ordering test passes for equality.
        vm.writeJson(vm.toString(bytes32(uint256(1))), path, ".checked.toyCodeHash");
        vm.expectRevert(bytes("toy's code differs from toy.json's check"));
        unit.checkedToy(network);
        vm.writeJson(vm.toString(bytes32(type(uint256).max)), path, ".checked.toyCodeHash");
        vm.expectRevert(bytes("toy's code differs from toy.json's check"));
        unit.checkedToy(network);

        vm.writeFile(path, checked);
        vm.writeJson("1", path, ".checked.mainChainId");
        vm.expectRevert(bytes("toy.json was checked on another chain"));
        unit.checkedToy(network);
        vm.writeJson(vm.toString(block.chainid + 1), path, ".checked.mainChainId");
        vm.expectRevert(bytes("toy.json was checked on another chain"));
        unit.checkedToy(network);

        vm.writeFile(path, checked);
        vm.writeJson(vm.toString(makeAddr("no code")), path, ".checked.toy");
        vm.expectRevert(bytes(_noCode("toy", makeAddr("no code"))));
        unit.checkedToy(network);

        vm.writeFile(path, string.concat('{"toy": "', vm.toString(_journalOf("toy", ".toy")), '"}'));
        vm.expectRevert(bytes("toy.json is unchecked: run its check step"));
        unit.checkedToy(network);

        vm.removeFile(path);
        vm.expectRevert(bytes("toy.json is unchecked: run its check step"));
        unit.checkedToy(network);
    }

    /// @dev A role's own chain key wins over the default chain's `mainChainId`: a two-chain unit's role is read there.
    function test_checked_readsARoleOnItsOwnChain() public {
        _deployChecked("checked-own-chain");
        string memory path = string.concat(dir, "/toy.json");
        vm.writeJson("1", path, ".checked.mainChainId");
        vm.writeJson(vm.toString(block.chainid), path, ".checked.toyChainId");
        assertEq(unit.checkedToy(network), _journalOf("toy", ".toy"));

        vm.writeJson("1", path, ".checked.toyChainId");
        vm.expectRevert(bytes("toy.json was checked on another chain"));
        unit.checkedToy(network);
    }

    function test_checkedOptional_readsACertifiedRoleAsPresent_andRefusesWhatCheckedRefuses() public {
        _deployChecked("optional-present");
        (bool present, address addr) = unit.checkedOptional(network, "toy");
        assertTrue(present);
        assertEq(addr, _journalOf("toy", ".toy"));

        string memory path = string.concat(dir, "/toy.json");
        vm.writeJson("false", path, ".checked.toyAbsent");
        (present,) = unit.checkedOptional(network, "toy");
        assertTrue(present, "a false absence is not one");

        vm.writeJson(vm.toString(bytes32(uint256(1))), path, ".checked.toyCodeHash");
        vm.expectRevert(bytes("toy's code differs from toy.json's check"));
        unit.checkedOptional(network, "toy");
    }

    /// @dev An absence holds only while its address stays empty: code there since the check is refused.
    function test_checkedOptional_readsARecordedAbsence_untilCodeAppearsAtItsAddress() public {
        _network("optional-absent", FREE, "");
        address at = makeAddr("absent toy");
        address spare = makeAddr("spare");
        unit.checkAbsent(network, at, spare);

        (bool present, address addr) = unit.checkedOptional(network, "toy");
        assertFalse(present);
        assertEq(addr, address(0));
        vm.etch(spare, hex"00");
        vm.expectRevert(bytes("spare has code since toy.json recorded it absent: a person must resolve it"));
        unit.checkedOptional(network, "spare");
        vm.expectRevert(bytes(_noCode("toy", at)));
        unit.checkedToy(network);

        vm.etch(at, hex"00");
        vm.expectRevert(bytes("toy has code since toy.json recorded it absent: a person must resolve it"));
        unit.checkedOptional(network, "toy");
        vm.expectRevert(bytes("toy has code: certify it instead"));
        unit.checkAbsent(network, at, spare);

        vm.etch(at, "");
        vm.writeJson("1", string.concat(dir, "/toy.json"), ".checked.mainChainId");
        vm.expectRevert(bytes("toy.json was checked on another chain"));
        unit.checkedOptional(network, "toy");
    }

    /// @dev Forge keeps serialized objects across one run: a certificate keeps no key of an earlier one.
    function test_certificate_keepsNoKeyOfAnEarlierCheckInTheSameRun() public {
        _network("certificate-fresh", FREE, "");
        unit.deploy(network);
        unit.checkAbsent(network, makeAddr("absent toy"), makeAddr("spare"));
        unit.check(network);
        (bool present,) = unit.checkedOptional(network, "toy");
        assertTrue(present, "the certificate kept toyAbsent");
    }

    /// @dev A reset chain shows no code where the journal records a landed role. The same nonce would
    ///      resend the pending intent, and a used one would deploy afresh: either would let the stale
    ///      `checked` vouch for an unchecked contract with the same code.
    function test_deploy_refusesARoleRecordedAsLanded_whoseAddressHasNoCode() public {
        _network("reset", FREE, "");
        unit.deploy(network);
        string memory path = string.concat(dir, "/toy.json");
        string memory journal = vm.readFile(path);
        address toy = vm.parseJsonAddress(journal, ".toy");
        uint64 nonce = uint64(vm.parseJsonUint(journal, ".toyNonce"));
        bytes memory refusal = bytes(
            "toy.json records toy as landed, but the RPC shows no code at its address: the RPC lags or the chain was reset; a person must resolve it"
        );
        vm.etch(toy, "");

        vm.writeJson(vm.toString(keccak256("the creation")), path, ".toyTx");
        vm.setNonceUnsafe(ops, nonce);
        vm.expectRevert(refusal);
        unit.deploy(network);
        vm.stopBroadcast();

        vm.writeFile(path, journal);
        vm.writeJson(string.concat('{"toy":"', vm.toString(toy), '"}'), path, ".checked");
        vm.setNonceUnsafe(ops, nonce + 1);
        vm.expectRevert(refusal);
        unit.deploy(network);
        vm.stopBroadcast();
    }

    function test_inputFile_namesTheUnitWhoseInputIsRead() public {
        _network("input-file", FREE, "");
        vm.writeFile(string.concat(dir, "/other.input.json"), '{"n":"3","big":"11","later":"<fill>"}');
        assertEq(unit.otherInputUint(network, "other", "n"), 3);
        vm.expectRevert(bytes("other.input.json's big is out of range"));
        unit.otherInputUint(network, "other", "big");
        vm.expectRevert(bytes("other.input.json's later is a placeholder: fill it in and commit it"));
        unit.otherInputUint(network, "other", "later");
    }

    function test_recorded_readsAnotherUnitsRoleOnlyWithItsChainAndCode() public {
        _network("recorded", FREE, "");
        unit.deploy(network);
        ToyUnit reader = new ToyUnit();
        assertEq(reader.recordedOf(network, "toy", "toy"), _journalOf("toy", ".toy"));
        vm.expectRevert(bytes("toy.json records no spare"));
        reader.recordedOf(network, "toy", "spare");
        string memory path = string.concat(dir, "/toy.json");
        vm.writeJson(vm.toString(bytes32(uint256(1))), path, ".toyCodeHash");
        vm.expectRevert(bytes("toy's code differs from toy.json"));
        reader.recordedOf(network, "toy", "toy");
        string memory other = string.concat(dir, "/other.json");
        vm.writeFile(other, vm.readFile(path));
        vm.writeJson("5", other, ".mainChainId");
        vm.expectRevert(bytes("other.json is not this chain's"));
        reader.recordedOf(network, "other", "toy");
    }

    /// @dev An equal identity leaves the journal byte for byte, so the builder writes what
    ///      `_certifyRole` wrote; its keys are the ones `_checked` reads.
    function test_certificate_certifiesAsCertifyRole_andAddsKeysThatCheckedReads() public {
        _deployChecked("certificate");
        string memory path = string.concat(dir, "/toy.json");
        string memory journal = vm.readFile(path);
        unit.checkBuilt(network, address(0));
        assertEq(vm.readFile(path), journal);
        // Without the receipt step: the certificate is the same.
        unit.checkBuilt(network, address(1));
        assertEq(vm.readFile(path), journal);

        address spare = address(new ToyPayload(7));
        unit.checkBuilt(network, spare);
        (bool present, address addr) = unit.checkedOptional(network, "spare");
        assertTrue(present);
        assertEq(addr, spare);
        assertEq(vm.parseJsonUint(vm.readFile(path), ".checked.tag"), 1);
    }

    function test_check_rerunAtALaterBlock_leavesTheJournalByteForByte_andRecertifiesAChangedIdentity() public {
        _deployChecked("check-rerun");
        string memory path = string.concat(dir, "/toy.json");
        string memory journal = vm.readFile(path);
        vm.roll(block.number + 1);

        unit.check(network);
        assertEq(vm.readFile(path), journal);

        vm.writeJson("1", path, ".checked.retired");
        unit.check(network);
        assertFalse(vm.keyExistsJson(vm.readFile(path), ".checked.retired"), "a shrunk identity kept its old key");
        assertEq(vm.parseJsonUint(vm.readFile(path), ".checked.evmBlock"), block.number);

        vm.writeJson(vm.toString(bytes32(uint256(1))), path, ".checked.toyCodeHash");
        unit.check(network);
        assertEq(
            vm.parseJsonBytes32(vm.readFile(path), ".checked.toyCodeHash"),
            _journalOf("toy", ".toy").codehash,
            "a changed value kept its old certificate"
        );
    }

    // ==== The default chain ====

    /// @notice The only chain of a map is the default: a unit requires the RPC to be its id.
    function test_use_aSoleChainNamedOtherThanL2_isTheDefault() public {
        _network("sole", FREE, "");
        vm.writeFile(
            string.concat(dir, "/network.json"),
            string.concat('{"chains":{"main":{"rpc":"main","id":', vm.toString(block.chainid), "}}}")
        );
        unit.useNetwork(network);

        vm.writeFile(string.concat(dir, "/network.json"), '{"chains":{"main":{"rpc":"main","id":1}}}');
        vm.expectRevert(bytes(string.concat("the RPC's chain is not ", network, "'s default chain")));
        unit.useNetwork(network);
    }

    function test_use_refusesAnUnnamedNetwork() public {
        vm.expectRevert(bytes("name the network: a directory under cache/core-test/deployments/"));
        unit.useNetwork("");
    }

    function test_inputs_refuseAPlaceholderAZeroAddressAndAnOutOfRangeNumber() public {
        assertEq(unit.decided('{"k":"v"}', "k"), "v");
        vm.expectRevert(bytes("toy.input.json's k is a placeholder: fill it in and commit it"));
        unit.decided('{"k":"<fill>"}', "k");

        assertEq(unit.inputUint('{"n":5}', "n", 5, 6), 5);
        assertEq(unit.inputUint('{"n":6}', "n", 5, 6), 6);
        vm.expectRevert(bytes("toy.input.json's n is out of range"));
        unit.inputUint('{"n":4}', "n", 5, 6);
        vm.expectRevert(bytes("toy.input.json's n is out of range"));
        unit.inputUint('{"n":7}', "n", 5, 6);

        assertEq(unit.requiredAddress(string.concat('{"a":"', vm.toString(ops), '"}'), "a"), ops);
        vm.expectRevert(bytes("toy.input.json's a is the zero placeholder: supply the required address"));
        unit.requiredAddress(string.concat('{"a":"', vm.toString(address(0)), '"}'), "a");
    }

    function test_requireTestChain_refusesALiveChain() public {
        UnitHarness harness = new UnitHarness();
        vm.chainId(1);
        vm.expectRevert(bytes("a test-only unit: name a test chain's network"));
        harness.requireTestChain();
    }

    // ==== Helpers ====

    function _network(string memory name, uint256 chainId, string memory pin) private {
        vm.chainId(chainId);
        network = vm.indexOf(name, "rehearsal-") == 0 ? name : string.concat("core-", name);
        dir = string.concat("cache/core-test/deployments/", network);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(dir, true);
        unit.setTestSender(ops);
        string memory json = string.concat('{"chains":{"main":{"rpc":"main","id":', vm.toString(chainId), "}}");
        if (bytes(pin).length != 0) json = string.concat(json, ',"deployer":"', pin, '"');
        vm.writeFile(string.concat(dir, "/network.json"), string.concat(json, "}"));
    }

    function _stray(address from) private returns (address) {
        vm.broadcast(from);
        return address(new ToyPayload(9));
    }

    /// @dev `<file>.json`, recording `at` as `role` of that name, deployed by `deployer` at `nonce`.
    function _record(string memory role, address addr, address deployer, uint256 nonce) private {
        vm.serializeAddress(role, role, addr);
        vm.serializeAddress(role, string.concat(role, "Deployer"), deployer);
        vm.serializeUint(role, string.concat(role, "Nonce"), nonce);
        vm.writeJson(
            vm.serializeBytes32(role, string.concat(role, "CodeHash"), addr.codehash),
            string.concat(dir, "/", role, ".json")
        );
    }

    function _noCode(string memory role, address at) private pure returns (string memory) {
        return string.concat(
            role,
            " at ",
            vm.toString(at),
            " has no code: if the RPC lags behind the chain, run again once it shows the deployment"
        );
    }

    function _journalOf(string memory file, string memory key) private view returns (address) {
        return vm.parseJsonAddress(vm.readFile(string.concat(dir, "/", file, ".json")), key);
    }

    function _addressOf(string memory journal) private pure returns (address) {
        return vm.parseJsonAddress(journal, ".toy");
    }

    function _deployChecked(string memory name) private {
        _network(name, FREE, "");
        unit.deploy(network);
        unit.check(network);
    }

    /// @dev The journal a deploy wrote, then deleted.
    function _lose(string memory name) private returns (string memory journal) {
        _network(name, FREE, "");
        unit.deploy(network);
        journal = vm.readFile(string.concat(dir, "/toy.json"));
        vm.removeFile(string.concat(dir, "/toy.json"));
    }

    function _refusal(address addr, address deployer, uint256 nonce) private view returns (string memory) {
        return string.concat(
            "toy.json lacks toy, yet ",
            vm.toString(addr),
            ", the CREATE of ",
            vm.toString(deployer),
            " at nonce ",
            vm.toString(nonce),
            ", has code no journal records: find its journal with git log --all -i -G ",
            vm.toString(addr),
            " -- ",
            dir,
            "; if it is none of toy's roles, list it in toy.json's retired; if it may be one and git has no journal, stop: a person must resolve it"
        );
    }

    function _pending(uint256 nonce, address sender) private pure returns (string memory) {
        return string.concat(
            "the deployment at nonce ",
            vm.toString(nonce),
            " of ",
            vm.toString(sender),
            " may still be pending: wait for it, or replace that nonce, then rerun; on a local chain, delete toy.json"
        );
    }

    function _notCurrent(address addr) private returns (string memory) {
        return string.concat(
            _recordPath(),
            " records ToyPayload at ",
            vm.toString(addr),
            " with initcode other than this build's with the current inputs: if it is the lost deployment,",
            " restore the commit and inputs that made it; if not, list it in toy.json's retired"
        );
    }

    /// @dev Under the network, where `_records` puts them under `forge test`.
    function _recordPath() private returns (string memory) {
        return string.concat(vm.projectRoot(), "/", _recordFile());
    }

    function _recordFile() private returns (string memory) {
        string memory records = string.concat(dir, "/broadcast/", SCRIPT, "/", vm.toString(block.chainid));
        vm.createDir(records, true);
        return string.concat(records, "/0-latest.json");
    }

    function _writeReceipts(string memory file, string memory commit, address addr, bytes32 first, bytes32 second)
        private
    {
        string memory records = string.concat(dir, "/broadcast/", SCRIPT, "/", vm.toString(block.chainid));
        vm.createDir(records, true);
        string memory receipt =
            string.concat('{"contractAddress": "', vm.toLowercase(vm.toString(addr)), '", "transactionHash": "');
        vm.writeFile(
            string.concat(records, "/", file),
            string.concat(
                '{"chain": ',
                vm.toString(block.chainid),
                ', "commit": ',
                commit,
                ', "transactions": [], "receipts": [',
                receipt,
                vm.toString(first),
                '"}, ',
                receipt,
                vm.toString(second),
                '"}]}'
            )
        );
    }

    function _writeRecord(string memory record) private {
        vm.writeFile(_recordFile(), record);
    }

    function _initcode(uint256 tag) private view returns (bytes memory) {
        return bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), abi.encode(tag));
    }

    function _run(uint256 chain, string memory transactions) private pure returns (string memory) {
        return string.concat('{"chain": ', vm.toString(chain), ', "transactions": [', transactions, "]}");
    }

    /// @dev The CREATE `journal` records, as sent by `from`.
    function _sent(string memory journal, address from) private view returns (string memory) {
        return _create(
            "ToyPayload",
            _addressOf(journal),
            from,
            vm.parseJsonUint(journal, ".toyNonce"),
            bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), vm.parseJsonBytes(journal, ".toyArgs"))
        );
    }

    function _create(string memory name, address addr, address from, uint256 nonce, bytes memory input)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '{"transactionType": "CREATE", "contractName": "',
            name,
            '", "contractAddress": "',
            vm.toLowercase(vm.toString(addr)),
            '", "transaction": {"from": "',
            vm.toLowercase(vm.toString(from)),
            '", "nonce": "',
            vm.toString(bytes32(nonce)),
            '", "input": "',
            vm.toString(input),
            '"}}'
        );
    }
}

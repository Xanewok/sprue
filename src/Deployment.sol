// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {chainId} from "./Chains.sol";
import {requireBuild, requireLost} from "./DeployChecks.sol";
import {ForgeBroadcasts} from "./ForgeBroadcasts.sol";
import {Certificate} from "./Journal.sol";
import {Ctx, ISprueEngine} from "./SprueEngine.sol";

/// @dev The deploy step for one role (a contract a unit deploys), and the guards that keep a rerun
///      from deploying it twice.
///
///      Maintains: the journal records a role's deployer, nonce, intent and address before the
///      transaction is known to have landed, so that a rerun can tell a lost broadcast from a
///      pending one.
///
///      Guarantees: a role the journal lacks is sent only when no broadcast record may hold it
///      (`_requireNoStray`) and, on a fenced chain, no earlier CREATE of a known deployer has code
///      that no journal records (`_requireNoUnjournaled`). A pending intent is only ever sent again
///      as the same transaction.
///
///      Relies on: forge's `broadcast/` records, and the chain's nonces and code. It reads them and
///      cannot prove that they are complete.
abstract contract Deployment is ForgeBroadcasts {
    address private _testSender;
    bool private _testCreationsTrusted;
    /// @dev The broadcaster of the step's first broadcast, and its nonce then. `_done` clears it.
    address private _stepSender;
    uint256 private _stepNonce;
    /// @dev The initcode and argument hashes of each contract this unit's `_deployRole` created in this
    ///      run, by chain and address. A role that a simulation created has no transaction for
    ///      `_requireCreatedFrom` or `_requireCreatedWith` to read.
    mapping(bytes32 deployment => Created) private _createdThisRun;

    struct Created {
        bytes32 initcodeHash;
        bytes32 argsHash;
    }

    /// @dev Lets a test pass the creation proofs of roles whose creation no transaction shows, as forge's
    ///      test commands keep none. Without it, a test refuses them as a script does, so a test that
    ///      tampers with a role's creation proves something. Reverts outside forge's test commands.
    function trustTestCreations() external {
        require(vm.isContext(VmSafe.ForgeContext.TestGroup), "only a test trusts creations");
        _testCreationsTrusted = true;
    }

    /// @dev `trustTestCreations` for one role only: the creation proofs take `journal`'s intent for
    ///      `role` as its creation in this run, so a test still refuses a tampered intent and every other
    ///      role. Reverts outside forge's test commands.
    function trustTestCreationOf(string calldata journal, string calldata role) external {
        require(vm.isContext(VmSafe.ForgeContext.TestGroup), "only a test trusts creations");
        string memory key = string.concat(".", role);
        _createdThisRun[_deployment(_addr(journal, key))] = Created(
            vm.parseJsonBytes32(journal, string.concat(key, "InitcodeHash")),
            keccak256(vm.parseJsonBytes(journal, string.concat(key, "Args")))
        );
    }

    /// @dev Lets a test send each step as that step's sender. Reverts outside forge's test commands,
    ///      so a script's broadcast sends as forge's own sender (`--sender`, `--account`).
    function setTestSender(address sender) external {
        require(vm.isContext(VmSafe.ForgeContext.TestGroup), "only a test chooses the sender");
        _testSender = sender;
    }

    /// @dev Opens the step's broadcast unless it is open. `_done()` closes it. A broadcast the step did not
    ///      open here, its caller's or a direct `vm.startBroadcast`, is not reused: forge refuses to open
    ///      a second one.
    function _startBroadcast() internal {
        if (_inProbe()) revert StepDue();
        if (_ownBroadcastOpen()) return;
        if (_testSender == address(0)) vm.startBroadcast();
        else vm.startBroadcast(_testSender);
        if (_stepSender != address(0)) return;
        (, _stepSender,) = vm.readCallers();
        _stepNonce = vm.getNonce(_stepSender);
    }

    /// @dev `_done(_sentThisStep())`, after it closes the step's broadcast.
    function _done() internal returns (string memory) {
        if (_ownBroadcastOpen()) vm.stopBroadcast();
        return _done(_sentThisStep());
    }

    function _ownBroadcastOpen() private returns (bool) {
        (VmSafe.CallerMode mode,,) = vm.readCallers();
        return _stepSender != address(0) && mode == VmSafe.CallerMode.RecurrentBroadcast;
    }

    /// @dev Whether this step created a transaction: forge counts each one, simulated or sent, in the
    ///      broadcaster's nonce. Only on the chain where the step first opened its broadcast, which is
    ///      enough for `_done`'s log.
    function _sentThisStep() internal view returns (bool) {
        return _stepSender != address(0) && vm.getNonce(_stepSender) != _stepNonce;
    }

    function _stepEnded() internal virtual override {
        _stepSender = address(0);
    }

    /// @dev Sends `call` to `target` unless `holds`, in the step's broadcast. Wants run in order, so a
    ///      later one sees the earlier ones' effects. Only a revert fails it: a contract that reports
    ///      failure by its return value needs the step's own check.
    function _want(bool holds, address target, bytes memory call) internal {
        _want(holds, target, 0, call);
    }

    /// @dev `_want` that sends `value` wei with `call`; with an empty `call`, a plain transfer.
    function _want(bool holds, address target, uint256 value, bytes memory call) internal {
        if (holds) return;
        // As a typed call would: a call to an address without code succeeds and does nothing. Only a
        // plain transfer of value means something there.
        require(
            target.code.length != 0 || (call.length == 0 && value != 0),
            string.concat(vm.toString(target), " has no code")
        );
        _startBroadcast();
        (bool ok, bytes memory ret) = target.call{value: value}(call);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @dev Sends `call` to `target` in the step's broadcast, for a step that decided itself that it must. Guard
    ///      it with the step's own condition: a probe reads a step that always sends as due, and `run` would
    ///      send it each time.
    function _send(address target, bytes memory call) internal {
        _want(false, target, 0, call);
    }

    function _send(address target, uint256 value, bytes memory call) internal {
        _want(false, target, value, call);
    }

    // ==== The engine ====

    /// @dev Where `SprueEngine` is placed. A static call to it is not a transaction of a broadcast.
    address internal constant ENGINE = address(uint160(uint256(keccak256("sprue.engine.v1"))));

    /// @dev Places the engine on first use, outside a view too: forge allows `vm.etch` in a static frame, which
    ///      only the compiler forbids. The engine's code is a cache of the build, so a probe that places it and
    ///      reverts leaves nothing a rerun reads.
    function _engine() private view returns (ISprueEngine) {
        if (ENGINE.code.length == 0) _asView(_place)();
        return ISprueEngine(ENGINE);
    }

    function _place() private {
        vm.etch(ENGINE, vm.getDeployedCode("SprueEngine.sol:SprueEngine"));
        vm.allowCheatcodes(ENGINE);
        vm.makePersistent(ENGINE);
    }

    function _asView(function() internal f) private pure returns (function() internal view g) {
        assembly ("memory-safe") {
            g := f
        }
    }

    /// @dev A test unit that answers the engine's hooks returns itself; a script must never name its own address.
    function _testHost() internal view virtual returns (address) {
        return address(0);
    }

    function _ctx(bool script, bool chains) private view returns (Ctx memory c) {
        c.host = _testHost();
        c.unit = _unit();
        c.deployments = _deployments();
        c.network = _networkName();
        if (script) c.script = _deployScript();
        if (chains) {
            c.defaultChain = _defaultChain(_networkJson());
            c.selected = _selectedChain();
        }
        c.fenced = _fenced();
        c.rehearsal = _rehearsal();
        c.probing = _inProbe();
    }

    function _requireNoStray(string memory journal, string memory role, string memory artifact) internal view {
        _requireNoStray(journal, role, artifact, address(0));
    }

    /// @dev `adopted`, a CREATE2 address the step is about to deploy or adopt, is that role itself.
    function _requireNoStray(string memory journal, string memory role, string memory artifact, address adopted)
        internal
        view
    {
        _engine().requireNoStray(_ctx(true, false), journal, role, artifact, adopted);
    }

    function _hasRecoverStep() internal view returns (bool) {
        return _engine().hasRecoverStep(_ctx(true, false));
    }

    function _requireNoUnjournaled(string memory journal, string memory role, address sender) internal view {
        if (_fenced()) _engine().requireNoUnjournaled(_ctx(false, false), journal, role, sender);
    }

    function _recordReceipt(string memory journal, string memory role, address deployed) internal {
        _recordReceipt(journal, role, deployed, false);
    }

    function _recordCreate2Receipt(string memory journal, string memory role, address deployed) internal {
        _recordReceipt(journal, role, deployed, true);
    }

    function _recordReceipt(string memory journal, string memory role, address deployed, bool create2) private {
        if (_inProbe()) return;
        _engine().recordReceipt(_ctx(true, false), journal, role, deployed, create2);
    }

    function _findReceipt(string memory journal, string memory role, address deployed, bool create2)
        internal
        returns (bytes32, uint256, string memory)
    {
        return _engine().findReceipt(_ctx(true, false), journal, role, deployed, create2);
    }

    function _createToRecover(string memory journal, string memory role, string memory artifact, address sender)
        internal
        returns (Create memory)
    {
        return _createToRecover(journal, role, artifact, sender, 0);
    }

    function _createToRecover(
        string memory journal,
        string memory role,
        string memory artifact,
        address sender,
        bytes32 initcodeHash
    ) internal returns (Create memory) {
        return _engine().createToRecover(_ctx(false, false), journal, role, artifact, sender, initcodeHash);
    }

    function _requireCurrent(Create memory found, string memory artifact, bytes memory args) internal {
        if (found.addr == address(0)) return;
        Create memory landed = _engine().requireCurrent(_ctx(false, false), found, artifact, args);
        (found.path, found.record, found.run, found.key, found.args) =
            (landed.path, landed.record, landed.run, landed.key, landed.args);
    }

    function _journalRecovered(string memory journal, string[2][] memory roles, Create[] memory found) internal {
        _engine().journalRecovered(_ctx(false, true), journal, roles, found);
    }

    // ==== The build record ====

    /// @dev The role's recorded address if it has code. Zero if the journal lacks the role, or if its
    ///      recorded deployment can never land: it has no code and `requireLost` shows the deployer's
    ///      nonce is used. A recorded address without code and with an unused nonce is refused,
    ///      because the step cannot tell a lost broadcast from a pending one.
    function _reusableAddress(string memory journal, string memory role) internal returns (address existing) {
        string memory key = string.concat(".", role);
        if (!_has(journal, key)) return address(0);
        existing = _addr(journal, key);
        require(existing != address(0), string.concat("journal ", role, " is the zero address"));
        if (existing.code.length != 0) return existing;
        _requireNoLandedRecord(journal, role);

        require(
            _has(journal, string.concat(key, "Deployer")),
            string.concat("journal ", role, " has no code and no recorded deployer")
        );
        requireLost(
            existing,
            _addr(journal, string.concat(key, "Deployer")),
            _uint(journal, string.concat(key, "Nonce")),
            _unit()
        );
        _requireNoUnjournaled(journal, role, address(0));
        console.log("journal", role, "was never deployed and never can be: its nonce is used; deploying afresh");
        // The old intent stays in the journal until the deploy step overwrites it.
        return address(0);
    }

    /// @dev Reverts unless the code at the role's recorded address has the code hash the journal
    ///      recorded. It compares with the journal, not with the current build, so that a later
    ///      source change does not orphan a deployment. A record without a hash is refused, with no
    ///      fallback.
    function _requireRecordedCode(string memory journal, string memory role) internal view returns (address addr) {
        string memory hashKey = string.concat(".", role, "CodeHash");
        require(_has(journal, hashKey), string.concat(_unit(), ".json records no ", role, "CodeHash"));
        addr = _addr(journal, string.concat(".", role));
        _requireCode(addr, role);
        require(
            addr.codehash == vm.parseJsonBytes32(journal, hashKey),
            string.concat(role, "'s code differs from ", _unit(), ".json")
        );
    }

    /// @dev The initcode that created `role`, as the chain shows it: the input of the transaction that
    ///      created the recorded address, after the salt for a CREATE2 through the factory. The hash
    ///      is the journal's `<role>Tx`, else a broadcast record's, else the chain's (`_findReceipt`),
    ///      and the chain must show that it created the address; else this reverts. Comparing the
    ///      result whole with the initcode a unit expects proves the constructor's arguments.
    function _findCreationInput(string memory journal, string memory role) internal returns (bytes memory) {
        return _inputOf(journal, role, _creationTx(journal, role));
    }

    /// @dev `role` was created from this build's `artifact` with `args`: by this unit's `_deployRole`
    ///      in this run, whose record decides, or by the transaction `_findCreationInput` reads. A role
    ///      with neither passes only in a test that called `trustTestCreations`. For a role created
    ///      otherwise, compare `_findCreationInput` with what it was created from.
    function _requireCreatedFrom(string memory journal, string memory role, string memory artifact, bytes memory args)
        internal
    {
        bytes32 expected = _initcodeHash(artifact, args);
        bytes32 created = _createdThisRun[_deployment(_addr(journal, string.concat(".", role)))].initcodeHash;
        if (created == 0) {
            bytes32 hash = _creationTx(journal, role);
            if (hash == 0 && _testCreationsTrusted) return;
            created = keccak256(_inputOf(journal, role, hash));
        }
        require(
            created == expected,
            string.concat(
                role,
                " was not created from this build's ",
                artifact,
                " with the step's arguments: if they changed after its creation, or its source after its deployment, compare _findCreationInput with what it was created from"
            )
        );
    }

    /// @dev `role` was created with `args` from the code its journal records: by this unit's
    ///      `_deployRole` in this run, or by the transaction `_findCreationInput` reads, whose input must
    ///      be code that hashes to `<role>CreationCodeHash` followed by `args`. Unlike
    ///      `_requireCreatedFrom`, a role whose source changed after its deployment passes; the code's
    ///      identity rests on the journal. A journal without that key, written by an older sprue, has the
    ///      whole input proven against `<role>InitcodeHash` and `args` against `<role>Args`, which the
    ///      same write recorded. A role with neither passes only in a test that called
    ///      `trustTestCreations`.
    function _requireCreatedWith(string memory journal, string memory role, bytes memory args) internal {
        string memory key = string.concat(".", role);
        Created memory run = _createdThisRun[_deployment(_addr(journal, key))];
        bool created;
        if (run.initcodeHash != 0) {
            created = run.argsHash == keccak256(args);
        } else {
            bytes32 hash = _creationTx(journal, role);
            if (hash == 0 && _testCreationsTrusted) return;
            bytes memory input = _inputOf(journal, role, hash);
            if (input.length >= args.length) {
                (bytes32 code, bytes32 tail) = _hashSplit(input, args.length);
                created = tail == keccak256(args)
                    && (_has(journal, string.concat(key, "CreationCodeHash"))
                            ? code == vm.parseJsonBytes32(journal, string.concat(key, "CreationCodeHash"))
                            : keccak256(input) == vm.parseJsonBytes32(journal, string.concat(key, "InitcodeHash"))
                            && keccak256(vm.parseJsonBytes(journal, string.concat(key, "Args"))) == keccak256(args));
            }
        }
        require(
            created,
            string.concat(role, " was not created with the step's arguments from the code ", _unit(), ".json records")
        );
    }

    /// @dev The journal's record of `role` is consistent with a CREATE of `args` by the deployer that
    ///      `network.json` pins: the recorded arguments are `args`, and the recorded deployer and nonce give
    ///      the address the journal records, which is the one a step reuses. Refused on a network that pins
    ///      no deployer, where any key's record would pass. It proves what the journal says, not what the
    ///      chain shows: `_requireCreatedWith` reads the creation itself, where the input is the code
    ///      followed by `args` alone.
    function _requireJournaledCreate(string memory journal, string memory role, bytes memory args) internal view {
        _requireJournaledCreate(_unit(), journal, role, args);
    }

    /// @dev `_requireJournaledCreate` of `unit`'s journal `record`, as `_journalOf(unit)` reads it.
    function _requireJournaledCreate(string memory unit, string memory record, string memory role, bytes memory args)
        internal
        view
    {
        address pinned = _pinnedDeployer();
        require(
            pinned != address(0),
            string.concat("network.json pins no deployer, so ", unit, ".json alone cannot prove ", role, "'s creation")
        );
        string memory key = string.concat(".", role);
        require(
            keccak256(vm.parseJsonBytes(record, string.concat(key, "Args"))) == keccak256(args),
            string.concat(role, "'s constructor arguments differ from ", unit, ".json")
        );
        require(
            _addr(record, string.concat(key, "Deployer")) == pinned,
            string.concat(role, "'s recorded deployer is not network.json's deployer")
        );
        require(
            vm.computeCreateAddress(pinned, _uint(record, string.concat(key, "Nonce"))) == _addr(record, key),
            string.concat(role, "'s address is not its recorded deployer's CREATE at its recorded nonce")
        );
    }

    /// @dev The role's recorded address, for a step after the role's deploy step: its code must be the
    ///      journal's (`_requireRecordedCode`) and its creation must have taken `args`
    ///      (`_requireCreatedWith`).
    function _reuse(string memory journal, string memory role, bytes memory args) internal returns (address addr) {
        addr = _requireRecordedCode(journal, role);
        _requireCreatedWith(journal, role, args);
    }

    /// @dev `_reuse` proven by the journal's own record (`_requireJournaledCreate`) instead of the
    ///      chain's creation.
    function _reuseJournaled(string memory journal, string memory role, bytes memory args)
        internal
        view
        returns (address addr)
    {
        addr = _requireRecordedCode(journal, role);
        _requireJournaledCreate(journal, role, args);
    }

    function _creationTx(string memory journal, string memory role) internal returns (bytes32 hash) {
        string memory key = string.concat(".", role);
        if (_has(journal, string.concat(key, "Tx"))) return vm.parseJsonBytes32(journal, string.concat(key, "Tx"));
        address addr = _addr(journal, key);
        (hash,,) = _findReceipt(journal, role, addr, false);
        if (hash == 0) (hash,,) = _findReceipt(journal, role, addr, true);
    }

    /// @dev `_creationTx` of a CREATE role, which no CREATE2 factory call made.
    function _createTx(string memory journal, string memory role) private returns (bytes32 hash) {
        string memory key = string.concat(".", role, "Tx");
        if (_has(journal, key)) return vm.parseJsonBytes32(journal, key);
        (hash,,) = _findReceipt(journal, role, _addr(journal, string.concat(".", role)), false);
    }

    function _inputOf(string memory journal, string memory role, bytes32 hash) private returns (bytes memory input) {
        string memory key = string.concat(".", role);
        require(
            hash != 0,
            string.concat(
                "neither ",
                _unit(),
                ".json, a broadcast record nor the chain shows the transaction that created ",
                role,
                ": journal it as ",
                role,
                "Tx"
            )
        );
        address addr = _addr(journal, key);
        bool create2 = _createdIn(hash, addr, false) == 0;
        require(
            !create2 || _createdIn(hash, addr, true) != 0,
            string.concat(
                vm.toString(hash),
                ", the transaction of ",
                role,
                ", did not create ",
                vm.toString(addr),
                " as this RPC shows the chain: if it lags behind the chain or no longer serves old transactions, use one that does"
            )
        );
        input = _sentInput(hash);
        if (create2) {
            require(input.length >= 32, "a CREATE2 factory call's input is shorter than its salt");
            // SAFETY: the length is at least 32, checked above. The new head overwrites the salt.
            assembly ("memory-safe") {
                let length := sub(mload(input), 0x20)
                input := add(input, 0x20)
                mstore(input, length)
            }
        }
    }

    /// @dev Returns zero when this run must send the role: the journal lacks it, an intent in it has
    ///      not landed, or its deployment is lost for good (see `_reusableAddress`). A pending intent
    ///      is sent again only as the same transaction, `sender` at nonce `next` with this initcode,
    ///      which can land at most once. Otherwise returns the recorded address, checked against the
    ///      recorded code. A role the journal lacks is refused while a broadcast record may hold its
    ///      deployment.
    function _reuseForSend(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        address sender,
        uint256 next
    ) internal returns (address addr) {
        string memory key = string.concat(".", role);
        if (
            _samePendingIntent(journal, role, artifact, args)
                && _addr(journal, string.concat(key, "Deployer")) == sender
                && _uint(journal, string.concat(key, "Nonce")) == next
        ) {
            _requireNoLandedRecord(journal, role);
            return address(0);
        }
        if (!_has(journal, key)) {
            _requireNoStray(journal, role, artifact);
            _requireNoUnjournaled(journal, role, sender);
        }
        addr = _reusableAddress(journal, role);
        if (addr != address(0)) _requireRecordedCode(journal, role);
    }

    /// @dev `_reuseForSend` for a `Due` view. A view shares the step's decision but knows neither the
    ///      sender nor the nonce. So any pending intent with the same hash yields zero here, and the
    ///      fence lacks the current sender (the pin or a deployer in a journal may still cover it).
    ///      A zero from this function therefore does not authorize a resend: only the step decides
    ///      that. A unit authenticates a nonzero result.
    function _reuseForDue(string memory journal, string memory role, string memory artifact, bytes memory args)
        internal
        returns (address addr)
    {
        if (!_has(journal, string.concat(".", role))) {
            _requireNoStray(journal, role, artifact);
            _requireNoUnjournaled(journal, role, address(0));
            return address(0);
        }
        addr = _addr(journal, string.concat(".", role));
        if (addr != address(0) && addr.code.length == 0 && _samePendingIntent(journal, role, artifact, args)) {
            _requireNoLandedRecord(journal, role);
            return address(0);
        }
        addr = _reusableAddress(journal, role);
        if (addr != address(0)) _requireRecordedCode(journal, role);
    }

    /// @dev A receipt or a check of `role` says it landed. With no code at its address, the RPC lags or the
    ///      chain was reset, and a resend or a replacement would let the stale `checked` vouch for an
    ///      unchecked contract with the same code.
    function _requireNoLandedRecord(string memory journal, string memory role) internal view {
        require(
            !_has(journal, string.concat(".", role, "Tx")) && !_has(journal, string.concat(".checked.", role)),
            string.concat(
                _unit(),
                ".json records ",
                role,
                " as landed, but the RPC shows no code at its address: the RPC lags or the chain was reset; a person must resolve it"
            )
        );
    }

    /// @dev Whether the journal records `role` at an address with no code, and its recorded
    ///      initcode hash equals this build's `artifact` with `args`.
    function _samePendingIntent(string memory journal, string memory role, string memory artifact, bytes memory args)
        private
        view
        returns (bool)
    {
        string memory key = string.concat(".", role);
        string memory hashKey = string.concat(key, "InitcodeHash");
        return _has(journal, key) && _has(journal, hashKey) && _addr(journal, key) != address(0)
            && _addr(journal, key).code.length == 0
            && vm.parseJsonBytes32(journal, hashKey) == _initcodeHash(artifact, args);
    }

    /// @notice Starts a unit's `recover` step. Returns the unit's journal and the sender whose lost
    ///         deployments the step journals.
    function _recovering(string memory network) internal returns (string memory journal, address sender) {
        journal = _use(network);
        // The broadcast is opened only so that `readCallers` names the broadcaster. Nothing is sent.
        vm.startBroadcast();
        (sender,) = _broadcaster();
        vm.stopBroadcast();
        require(sender != DEFAULT_SENDER, "pass --sender <deployer>: the sender of the lost deployments");
    }

    /// @notice The `recover` step of a unit with one role. If the journal lacks `role`, it journals
    ///         the one landed CREATE of `artifact` by the sender, provided it was made from this
    ///         build with `args` (the current inputs). Returns the journal.
    function _recover(string memory network, string memory role, string memory artifact, bytes memory args)
        internal
        returns (string memory)
    {
        (string memory journal, address sender) = _recovering(network);
        string[2][] memory roles = new string[2][](1);
        roles[0] = [role, artifact];
        Create[] memory found = new Create[](1);
        found[0] = _createToRecover(journal, role, artifact, sender);
        _requireCurrent(found[0], artifact, args);
        _journalRecovered(journal, roles, found);
        return _journal();
    }

    /// @dev `_put`, unless `journal` holds `key`.
    function _putNew(string memory journal, string memory key, string memory value) internal {
        if (!_has(journal, key)) _put(key, value);
    }

    function _recordIntent(string memory role, string memory name, bytes memory args) internal {
        _put(string.concat(".", role, "Args"), vm.toString(args));
        _put(string.concat(".", role, "InitcodeHash"), vm.toString(_initcodeHash(name, args)));
        _put(
            string.concat(".", role, "CreationCodeHash"),
            vm.toString(keccak256(vm.getCode(string.concat(name, ".sol:", name))))
        );
    }

    // ==== CREATE2, a unit's opt-in ====

    /// @dev The code hash of forge-std's `CREATE2_FACTORY`, the keyless deployment proxy. A unit that
    ///      opts into CREATE2 requires this code at that address on its chain, so that the factory
    ///      is the implementation whose behaviour the address computation assumes.
    bytes32 internal constant CREATE2_FACTORY_CODEHASH =
        0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;

    /// @dev Reverts unless `at` is where the factory puts this build's `artifact` with `args` under
    ///      `salt`. The unit's input file names `at`, so a reviewer sees the address before any send.
    ///      A change of the initcode, through the build or the arguments, moves the address, and the
    ///      refusal gives the initcode hash to mine a new salt for.
    function _requireCreate2Address(bytes32 salt, string memory artifact, bytes memory args, address addr)
        internal
        view
    {
        require(
            CREATE2_FACTORY.codehash == CREATE2_FACTORY_CODEHASH,
            string.concat("this chain has no CREATE2 factory at ", vm.toString(CREATE2_FACTORY), ": opt out of create2")
        );
        bytes32 initcodeHash = _initcodeHash(artifact, args);
        require(
            vm.computeCreate2Address(salt, initcodeHash, CREATE2_FACTORY) == addr,
            string.concat(
                "this build of ",
                artifact,
                " does not land at the input's create2.address under its salt: mine a salt for init code hash ",
                vm.toString(initcodeHash)
            )
        );
    }

    /// @dev A unit's deploy step for a role that the factory creates at `at`, the input's address for
    ///      `salt`. A role that landed and is journaled is proven by its recorded salt and code, then
    ///      `authenticate`, so a later source edit does not orphan it. Otherwise this build's
    ///      `artifact` with `args` must land at `at`: an unjournaled role with code there is adopted, and
    ///      a pending send is resent, since it cannot land anywhere else. `_onDeployment` runs when the
    ///      role is first journaled. `sent` is whether this run calls the factory.
    function _deployRoleCreate2(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        bytes32 salt,
        address at,
        function(address, bytes memory) internal authenticate
    ) internal returns (bool sent) {
        string memory key = string.concat(".", role);
        bool journaled = _has(journal, key);
        bool landed = at.code.length != 0;
        if (journaled) {
            require(
                _addr(journal, key) == at,
                string.concat(
                    _unit(), ".json's ", role, " is not the input's create2.address: a person must resolve it"
                )
            );
            require(
                _has(journal, string.concat(key, "Salt"))
                    && vm.parseJsonBytes32(journal, string.concat(key, "Salt")) == salt,
                string.concat("the input's create2.salt differs from ", _unit(), ".json's")
            );
            if (!landed) _requireNoLandedRecord(journal, role);
        } else {
            _requireNoStray(journal, role, artifact, at);
        }
        if (journaled && landed) {
            _requireRecordedCode(journal, role);
            _requireCreate2Record(journal, role, args, true);
        } else {
            // A new salt for a landed role would deploy a second one.
            require(
                !landed || vm.computeCreate2Address(salt, _initcodeHash(artifact, args), CREATE2_FACTORY) == at,
                string.concat(
                    "the input's create2.address holds a ",
                    role,
                    " that another build or input made: restore the journal, and never mine a new salt"
                )
            );
            _requireCreate2Address(salt, artifact, args, at);
        }
        // An adopted role is proven as a reused one: its initcode does not fix its runtime code or state.
        if (landed) authenticate(at, args);

        sent = !landed;
        if (sent) {
            _startBroadcast();
            _requireDeployable(false);
            (bool ok,) = CREATE2_FACTORY.call(bytes.concat(salt, _initcode(artifact, args)));
            require(ok, "the CREATE2 factory call reverted");
            vm.stopBroadcast();
        }
        if (!(journaled && landed)) _requireBuild(at, artifact);

        if (!_writing()) return sent;
        if (!journaled) {
            _onDeployment(journal, role, args);
            _put(string.concat(key, "Salt"), vm.toString(salt));
            _recordIntent(role, artifact, args);
            _recordBuild(role, at, artifact);
            _put(key, vm.toString(at));
        }
        if (sent) _recordDirty(role);
        else _recordCreate2Receipt(_journal(), role, at);
    }

    /// @dev Journals a deployment. If `recorded` is non-zero the role was reused, and only its
    ///      receipt is recorded. Returns the deployer's next unused nonce.
    function _recordDeployment(
        string memory journal,
        string memory role,
        string memory name,
        address addr,
        address recorded,
        address deployer,
        uint256 nonce
    ) internal returns (uint256) {
        if (recorded != address(0)) {
            _recordReceipt(journal, role, addr);
            return nonce;
        }
        // The address goes last. `_reusableAddress` takes it as the sign that a record exists, and
        // needs the deployer and nonce to be there already.
        _recordBuild(role, addr, name);
        _recordDirty(role);
        _recordSender(role, addr, deployer, nonce);
        _put(string.concat(".", role), vm.toString(addr));
        return nonce + 1;
    }

    /// @dev Writes `<role>Dirty` beside the `pending` commit, so that it describes the working tree
    ///      at the send and not at a later recovery. `sprue run` sets the variable only for an
    ///      attended step, and only when its tree had a change at the step's dry run. So a role of a
    ///      clean run, or of a plain `forge script` without that variable in the environment, has no
    ///      such key. A clean send over a key that a replaced intent left sets it to `false`.
    ///      Call it only where a transaction is created.
    function _recordDirty(string memory role) internal {
        string memory key = string.concat(".", role, "Dirty");
        if (keccak256(bytes(vm.envOr(_dirtyVariable(), string("")))) == keccak256("1")) {
            _put(key, "true");
        } else if (_has(_journal(), key)) {
            _put(key, "false");
        }
    }

    /// @dev Virtual so that a test reads a variable of its own, not the one other suites share.
    function _dirtyVariable() internal pure virtual returns (string memory) {
        return "DEPLOY_TREE_DIRTY";
    }

    /// @dev A unit's deploy step for one role. It reuses the journaled deployment, resends its
    ///      pending intent as the same transaction, or sends a new one. `create` must create
    ///      `artifact` and pass it `args`: the journaled intent, and the creation proofs within this
    ///      run, take them as the constructor's. forge names the broadcast's contract by its bytecode,
    ///      a typed `new` or not.
    ///      `authenticate` runs on a reused address before anything is journaled. `journal` is the
    ///      journal that `_use` returned. `sent` is whether this run creates a transaction, which a
    ///      simulation counts.
    function _deployRole(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        function(bytes memory) internal returns (address) create,
        function(address, bytes memory) internal view authenticate
    ) internal returns (address addr, bool sent) {
        return _deployRole(journal, role, artifact, args, create, authenticate, Proof.Authenticate, false);
    }

    /// @dev How `_deployRole` proves a reused role, before anything is journaled: by the unit's
    ///      `authenticate`, by `_requireCreatedFrom` (this build's code), by `_requireCreatedWith` (the
    ///      code the journal records, so a later source edit does not orphan the role), by
    ///      `_requireJournaledCreate` (the journal's own record, with no read of the creation), or by
    ///      `_requireCreateIdentity` (a role that `Roles._deploy` declares).
    enum Proof {
        Authenticate,
        FromBuild,
        WithArgs,
        Journaled,
        Identity
    }

    /// @dev `_deployRole` for a role whose creation proves what a reuse needs, as when its state is the
    ///      constructor's or `check` proves the rest: a reused role must pass `_requireCreatedFrom`.
    function _deployRole(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        function(bytes memory) internal returns (address) create
    ) internal returns (address addr, bool sent) {
        return _deployRole(journal, role, artifact, args, create, _noState, Proof.FromBuild, false);
    }

    /// @dev `_deployRole` with the creation proof named.
    function _deployRole(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        function(bytes memory) internal returns (address) create,
        Proof proof
    ) internal returns (address addr, bool sent) {
        require(proof != Proof.Authenticate, "pass the authenticate function instead");
        return _deployRole(journal, role, artifact, args, create, _noState, proof, false);
    }

    /// @dev `_deployRole` that creates `artifact` from its initcode with `args`, with no `create`
    ///      callback, and proves a reuse by `proof`. The unit's script then holds no copy of the
    ///      contract's bytecode.
    function _deployRole(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        Proof proof
    ) internal returns (address addr, bool sent) {
        require(proof != Proof.Authenticate, "pass the authenticate function instead");
        return _deployRole(journal, role, artifact, args, _noCreate, _noState, proof, true);
    }

    /// @dev `_deployRole` from the initcode, whose reuse must also pass `check` after `proof`, for state
    ///      that later transactions change. `Proof.Authenticate` leaves `check` the only proof.
    function _deployRole(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        Proof proof,
        function(address, bytes memory) internal view check
    ) internal returns (address addr, bool sent) {
        return _deployRole(journal, role, artifact, args, _noCreate, check, proof, true);
    }

    function _noState(address, bytes memory) private view {}

    function _noCreate(bytes memory) private pure returns (address) {}

    /// @dev CREATE of `initcode` in the caller's broadcast. Bubbles the constructor's revert.
    function _createFrom(bytes memory initcode) private returns (address at) {
        assembly ("memory-safe") {
            at := create(0, add(initcode, 0x20), mload(initcode))
            if iszero(at) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
    }

    function _deployment(address addr) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, addr));
    }

    function _deployRole(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        function(bytes memory) internal returns (address) create,
        function(address, bytes memory) internal authenticate,
        Proof proof,
        bool fromInitcode
    ) private returns (address addr, bool sent) {
        if (_inProbe()) {
            return (_reuseInProbe(journal, role, artifact, args, authenticate, proof), false);
        }
        _startBroadcast();
        (address deployer, uint256 nonce) = _broadcaster();
        address recorded = _reuseForSend(journal, role, artifact, args, deployer, nonce);
        sent = recorded == address(0);
        if (sent) {
            _requireDeployable(proof == Proof.Identity);
            addr = fromInitcode ? _createFrom(_initcode(artifact, args)) : create(args);
            _requireBuild(addr, artifact);
            _createdThisRun[_deployment(addr)] = Created(_initcodeHash(artifact, args), keccak256(args));
        } else {
            addr = recorded;
            _proveReuse(journal, role, artifact, args, addr, authenticate, proof);
        }
        vm.stopBroadcast();

        if (_writing()) {
            if (sent) {
                _onDeployment(journal, role, args);
                _recordIntent(role, artifact, args);
            }
            _recordDeployment(journal, role, artifact, addr, recorded, deployer, nonce);
        }
    }

    /// @dev A probe has no broadcaster, so it decides as a `Due` view does: a role that
    ///      `_reuseForDue` cannot reuse is due, whether the step would resend its pending intent or
    ///      send anew, and the step decides which.
    function _reuseInProbe(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        function(address, bytes memory) internal authenticate,
        Proof proof
    ) private returns (address addr) {
        addr = _reuseForDue(journal, role, artifact, args);
        if (addr == address(0)) revert StepDue();
        _proveReuse(journal, role, artifact, args, addr, authenticate, proof);
    }

    function _proveReuse(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        address addr,
        function(address, bytes memory) internal authenticate,
        Proof proof
    ) private {
        if (proof == Proof.FromBuild) _requireCreatedFrom(journal, role, artifact, args);
        else if (proof == Proof.WithArgs) _requireCreatedWith(journal, role, args);
        else if (proof == Proof.Journaled) _requireJournaledCreate(journal, role, args);
        else if (proof == Proof.Identity) _requireCreateIdentity(journal, role, args);
        authenticate(addr, args);
    }

    /// @dev `role`'s address is the CREATE of its recorded deployer at its recorded nonce, that deployer is
    ///      the one `network.json` pins or one of its `formerDeployers`, its recorded arguments are `args`, and some transaction is known to
    ///      have created it: the journal's `<role>Tx`, a broadcast record's, the chain's at the recorded
    ///      nonce, or this run's. On a network that pins no deployer, the recorded deployer stands, with a
    ///      warning: nothing then says whose CREATE the role must be.
    function _requireCreateIdentity(string memory journal, string memory role, bytes memory args) internal {
        string memory key = string.concat(".", role);
        address addr = _addr(journal, key);
        _requireCreateRecord(_unit(), journal, role, addr);
        _requireKey(_unit(), journal, role, "Args");
        require(
            keccak256(vm.parseJsonBytes(journal, string.concat(key, "Args"))) == keccak256(args),
            string.concat(role, "'s constructor arguments differ from ", _unit(), ".json")
        );
        if (_createdThisRun[_deployment(addr)].initcodeHash != 0) return;
        require(
            _createTx(journal, role) != 0 || _testCreationsTrusted,
            string.concat(
                "neither ",
                _unit(),
                ".json, a broadcast record nor the chain shows the transaction that created ",
                role,
                ": journal it as ",
                role,
                "Tx"
            )
        );
    }

    /// @dev `unit`'s `journal` puts `role` at `addr` by a CREATE of its recorded deployer at its
    ///      recorded nonce, and that deployer is the pin or a former one, if `network.json` has a pin.
    function _requireCreateRecord(string memory unit, string memory journal, string memory role, address addr)
        internal
        view
    {
        string memory key = string.concat(".", role);
        _requireKey(unit, journal, role, "Deployer");
        _requireKey(unit, journal, role, "Nonce");
        address deployer = _addr(journal, string.concat(key, "Deployer"));
        address pinned = _pinnedDeployer();
        if (pinned == address(0)) {
            console.log(
                string.concat(
                    "WARNING: network.json pins no deployer, so ", role, " is proven against ", unit, ".json's deployer"
                )
            );
        } else {
            require(
                deployer == pinned || _isFormerDeployer(deployer),
                string.concat(
                    role, "'s recorded deployer is neither network.json's deployer nor one of its formerDeployers"
                )
            );
        }
        require(
            vm.computeCreateAddress(deployer, _uint(journal, string.concat(key, "Nonce"))) == addr,
            string.concat(role, "'s address is not its recorded deployer's CREATE at its recorded nonce")
        );
    }

    /// @dev Whether `network.json`'s `formerDeployers`, the keys a pin replaced, lists `deployer`: a role one
    ///      of them created stays proven, though only the pin sends.
    function _isFormerDeployer(address deployer) internal view returns (bool) {
        string memory network = _networkJson();
        if (!_has(network, ".formerDeployers")) return false;
        address[] memory former = vm.parseJsonAddressArray(network, ".formerDeployers");
        for (uint256 i; i < former.length; ++i) {
            if (former[i] == deployer && deployer != address(0)) return true;
        }
        return false;
    }

    function _requireKey(string memory unit, string memory journal, string memory role, string memory suffix)
        internal
        view
    {
        require(_has(journal, string.concat(".", role, suffix)), string.concat(unit, ".json records no ", role, suffix));
    }

    /// @dev The factory puts `role`, under the salt and initcode hash `journal` records, at the address it
    ///      records, and, with `withArgs`, the recorded arguments are `args`. Against the recorded initcode
    ///      hash, not this build's, so that a later source edit does not orphan the role.
    function _requireCreate2Record(string memory journal, string memory role, bytes memory args, bool withArgs)
        internal
        view
    {
        string memory key = string.concat(".", role);
        require(
            _has(journal, string.concat(key, "Salt")) && _has(journal, string.concat(key, "InitcodeHash"))
                && vm.computeCreate2Address(
                    vm.parseJsonBytes32(journal, string.concat(key, "Salt")),
                    vm.parseJsonBytes32(journal, string.concat(key, "InitcodeHash")),
                    CREATE2_FACTORY
                ) == _addr(journal, key),
            string.concat(role, "'s address is not the CREATE2 factory's for its recorded salt and initcode")
        );
        if (!withArgs) return;
        _requireKey(_unit(), journal, role, "Args");
        require(
            keccak256(vm.parseJsonBytes(journal, string.concat(key, "Args"))) == keccak256(args),
            string.concat(role, "'s constructor arguments differ from ", _unit(), ".json")
        );
    }

    /// @dev `_deployRole` for a role that `Roles` declares: from the initcode, proven on a reuse by
    ///      `Proof.Identity` then `ensure`. On a network that pins a deployer, only the pin sends it, whatever
    ///      the opt-in to another key: another key's CREATE could never pass `Proof.Identity`.
    function _deployIdentified(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        function(address, bytes memory) internal ensure
    ) internal returns (address addr, bool sent) {
        return _deployRole(journal, role, artifact, args, _noCreate, ensure, Proof.Identity, true);
    }

    /// @dev Starts the certificate of `role` at `addr`, after it journals the role's receipt.
    function _certificate(string memory journal, string memory role, address addr)
        internal
        returns (Certificate memory)
    {
        _recordReceipt(journal, role, addr);
        return Certificate(_beginChecked(role, addr), role, addr);
    }

    /// @dev `_certificate` without a receipt: for a contract the unit did not deploy, or a role whose
    ///      receipt the unit journals itself (`_recordCreate2Receipt`).
    function _certificate(string memory role, address addr) internal returns (Certificate memory) {
        return Certificate(_beginChecked(role, addr), role, addr);
    }

    /// @dev Writes `c` on its role's code hash, prints it, and ends the step.
    function _certify(Certificate memory c) internal returns (string memory) {
        string memory checked = vm.serializeBytes32(c.obj, string.concat(c.role, "CodeHash"), c.addr.codehash);
        console.log(string.concat("checked ", checked));
        _certify(checked);
        return _done(false);
    }

    /// @dev The new contract's code must be the artifact's, with immutables read back from it. Override
    ///      only for a contract whose constructor returns its runtime code, which the artifact cannot
    ///      show, and have the unit's `check` step prove the code another way.
    function _requireBuild(address addr, string memory artifact) internal view virtual {
        requireBuild(addr, artifact);
    }

    /// @dev Called only when this run creates a new deployment transaction, simulated or broadcast, or
    ///      `_deployRoleCreate2` first journals a role, before the intent and the address are journaled. The default records the selected chain's
    ///      id stamp. An override owns the unit's other writes and their order, and calls `super`
    ///      where the unit should record the chain. It should also drop whatever the replaced
    ///      deployment vouched for.
    function _onDeployment(string memory, string memory, bytes memory) internal virtual {
        _putChainStamp();
    }

    /// @dev Records what a later verification needs besides the constructor arguments: the commit,
    ///      and the compiler's own metadata (version, settings, remappings, each source file's
    ///      keccak), so that a rebuild at that commit can be checked file by file. The commit is
    ///      `pending` until `_recordReceipt` reads the commit forge sent from. The metadata is copied
    ///      beside the journal because `out/` is usually git-ignored.
    /// @dev True when the person opted in to deploy with a key other than the pin, by setting the
    ///      variable to exactly `1`.
    function _unexpectedDeployerAllowed() internal view virtual returns (bool) {
        return keccak256(bytes(vm.envOr(_optInVariable(), string("")))) == keccak256("1");
    }

    /// @dev Virtual so that a test reads a variable of its own, not the one other suites share.
    function _optInVariable() internal pure virtual returns (string memory) {
        return "UNSAFE_UNEXPECTED_DEPLOYER";
    }

    /// @dev Called just before a step sends a CREATE, after the step's broadcast started, because it
    ///      reads the broadcaster. A run that creates no transaction never reaches it. Reverts when the
    ///      broadcaster is forge's default sender, except under `forge test`. With a pin, the
    ///      broadcaster must be the pinned deployer unless `UNSAFE_UNEXPECTED_DEPLOYER` is exactly
    ///      `1`, which logs a warning instead.
    /// @dev `_requireDeployable`, which with `strict` refuses a key other than the pin whatever the opt-in.
    function _requireDeployable(bool strict) internal {
        (address sender,) = _broadcaster();
        require(
            vm.isContext(VmSafe.ForgeContext.Test) || sender != DEFAULT_SENDER,
            "pass --sender <deployer> to the dry run, or --account"
        );
        address pinned = _pinnedDeployer();
        if (pinned == address(0) || sender == pinned) return;
        require(
            !strict,
            string.concat(
                vm.toString(sender),
                " is not ",
                _dir(),
                "/network.json's deployer ",
                vm.toString(pinned),
                ": only the pin sends a declared CREATE role, whose address follows from its sender; to change keys, pin the new one in a reviewed commit and list the old one in network.json's formerDeployers"
            )
        );
        require(
            _unexpectedDeployerAllowed(),
            string.concat(
                vm.toString(sender),
                " is not ",
                _dir(),
                "/network.json's deployer ",
                vm.toString(pinned),
                ": run with that key, or pass --unsafe-unexpected-deployer to sprue (UNSAFE_UNEXPECTED_DEPLOYER=1 for forge) to deploy with another"
            )
        );
        console.log(
            string.concat(
                "WARNING: deploying as ",
                vm.toString(sender),
                ", not ",
                _dir(),
                "/network.json's deployer ",
                vm.toString(pinned)
            )
        );
    }
}

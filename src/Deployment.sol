// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {chainId, checkedProject} from "./Chains.sol";
import {ForgeBroadcasts} from "./ForgeBroadcasts.sol";
import {Certificate} from "./Journal.sol";
import {Created, Ctx, Deployed, ISprueEngine, engine} from "./SprueEngine.sol";

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

    function _engine() private view returns (ISprueEngine) {
        return engine();
    }

    /// @dev A test unit that answers the engine's hooks returns itself; a script must never name its own address.
    function _testHost() internal view virtual returns (address) {
        return address(0);
    }

    function _ctx(bool script, bool chains) internal view returns (Ctx memory c) {
        c.host = _testHost();
        c.unit = _unit();
        c.deployments = _deployments();
        c.network = _networkName();
        c.graph = _graphScript();
        c.projectHash = checkedProject();
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
        _engine().journalRecovered(_ctx(true, true), journal, roles, found);
    }

    function _use(string memory network) internal returns (string memory) {
        _adopt(network);
        return _engine().use(_ctx(false, true));
    }

    function _checkOutputs() internal override {
        _engine().checkOutputs(_ctx(false, false));
    }

    /// @dev Empty: the engine reads `paths.graph` of `sprue.json`.
    function _graphScript() internal view virtual override returns (string memory) {
        return "";
    }

    /// @dev Empty: the engine finds the one `Deploy*.s.sol` in the unit's directory. A unit whose script lives
    ///      elsewhere, as a test's, names it.
    function _deployScript() internal view virtual override returns (string memory) {
        return "";
    }

    /// @dev Empty: the engine applies the project's rule, `chains.default` else the network's only chain.
    function _defaultChain(string memory) internal view virtual override returns (string memory) {
        return "";
    }

    function _done(bool sends) internal returns (string memory) {
        _stepOpen = false;
        _stepEnded();
        if (_inProbe()) return "";
        return _engine().leave(_ctx(false, false), sends);
    }

    function _putChainStamp() internal {
        _engine().putChainStamp(_ctx(false, true));
    }

    function _checked(string memory unit, string memory role) internal view returns (address) {
        return _engine().checkedAddress(_ctx(false, true), unit, role);
    }

    function _recorded(string memory unit, string memory role) internal view returns (address) {
        return _engine().recorded(_ctx(false, true), unit, role);
    }

    function _journalOf(string memory unit) internal view returns (string memory) {
        return _engine().journalOf(_ctx(false, true), unit);
    }

    function _checkedOptional(string memory unit, string memory role) internal view returns (bool, address) {
        return _engine().checkedOptional(_ctx(false, true), unit, role);
    }

    function _certify(string memory checked) internal {
        _engine().certifyChecked(_ctx(false, true), checked);
    }

    function _beginChecked(string memory role, address addr) internal returns (string memory) {
        return _engine().beginChecked(_ctx(false, true), role, addr);
    }

    function _certifyRole(string memory obj, string memory role, address addr) internal returns (string memory) {
        _certify(vm.serializeBytes32(obj, string.concat(role, "CodeHash"), addr.codehash));
        return _done(false);
    }

    function _ctxCreated(string memory journal, string memory role) private view returns (Ctx memory c) {
        c = _ctx(true, false);
        c.created = _createdThisRun[_deployment(_addr(journal, string.concat(".", role)))];
        c.trusted = _testCreationsTrusted;
    }

    function _reuseForSend(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        address sender,
        uint256 next
    ) internal returns (address) {
        return _engine().reuseForSend(_ctx(true, false), journal, role, artifact, args, sender, next);
    }

    function _reuseForDue(string memory journal, string memory role, string memory artifact, bytes memory args)
        internal
        returns (address)
    {
        return _engine().reuseForDue(_ctx(true, false), journal, role, artifact, args);
    }

    function _requireRecordedCode(string memory journal, string memory role) internal view returns (address) {
        return _engine().requireRecordedCode(_ctx(false, false), journal, role);
    }

    function _findCreationInput(string memory journal, string memory role) internal returns (bytes memory) {
        return _engine().findCreationInput(_ctx(true, false), journal, role);
    }

    function _requireCreatedFrom(string memory journal, string memory role, string memory artifact, bytes memory args)
        internal
    {
        _engine().requireCreatedFrom(_ctxCreated(journal, role), journal, role, artifact, args);
    }

    function _requireCreatedWith(string memory journal, string memory role, bytes memory args) internal {
        _engine().requireCreatedWith(_ctxCreated(journal, role), journal, role, args);
    }

    function _requireJournaledCreate(string memory journal, string memory role, bytes memory args) internal view {
        _requireJournaledCreate(_unit(), journal, role, args);
    }

    function _requireJournaledCreate(string memory unit, string memory record, string memory role, bytes memory args)
        internal
        view
    {
        _engine().requireJournaledCreate(_ctx(false, false), unit, record, role, args);
    }

    function _requireCreateIdentity(string memory journal, string memory role, bytes memory args) internal {
        _engine().requireCreateIdentity(_ctxCreated(journal, role), journal, role, args);
    }

    function _requireCreateRecord(string memory unit, string memory journal, string memory role, address addr)
        internal
        view
    {
        _engine().requireCreateRecord(_ctx(false, false), unit, journal, role, addr);
    }

    function _requireCreate2Record(string memory journal, string memory role, bytes memory args, bool withArgs)
        internal
        view
    {
        _engine().requireCreate2Record(_ctx(false, false), journal, role, args, withArgs);
    }

    function _requireCreate2Address(bytes32 salt, string memory artifact, bytes memory args, address addr)
        internal
        view
    {
        _engine().requireCreate2Address(_ctx(false, false), salt, artifact, args, addr);
    }

    function _requireDeployable(bool strict) internal {
        (address sender,) = _broadcaster();
        _engine().requireDeployable(_ctx(false, false), sender, strict, _unexpectedDeployerAllowed());
    }

    function _recordIntent(string memory role, string memory name, bytes memory args) internal {
        _engine().recordIntent(_ctx(false, false), role, name, args);
    }

    // ==== The build record ====

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

    // ==== CREATE2, a unit's opt-in ====

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
        (bool journaled, bool landed) =
            _engine().create2Pre(_ctx(true, false), journal, role, artifact, args, salt, at);
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
        if (!journaled) _onDeployment(journal, role, args);
        _engine().create2Record(
            _ctx(true, false), Deployed(role, artifact, args, at, address(0), address(0), 0, salt, journaled, sent, _dirty())
        );
    }

    /// @dev `sprue run` sets the variable only for an attended step, and only when its tree had a change at the
    ///      step's dry run.
    function _dirty() private view returns (bool) {
        return keccak256(bytes(vm.envOr(_dirtyVariable(), string("")))) == keccak256("1");
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
        Deployed memory d;
        (d.role, d.artifact, d.args) = (role, artifact, args);
        (address deployer, uint256 nonce) = _broadcaster();
        (d.deployer, d.nonce) = (deployer, nonce);
        d.recorded = _reuseForSend(journal, role, artifact, args, deployer, nonce);
        d.sent = d.recorded == address(0);
        if (d.sent) {
            _requireDeployable(proof == Proof.Identity);
            d.addr = fromInitcode ? _createFrom(_initcode(artifact, args)) : create(args);
            _requireBuild(d.addr, artifact);
            _createdThisRun[_deployment(d.addr)] = Created(_initcodeHash(artifact, args), keccak256(args));
        } else {
            d.addr = d.recorded;
            _proveReuse(journal, role, artifact, args, d.addr, authenticate, proof);
        }
        vm.stopBroadcast();

        (addr, sent) = (d.addr, d.sent);
        if (_writing()) {
            if (sent) _onDeployment(journal, role, args);
            d.dirty = _dirty();
            _engine().recordDeployment(_ctx(true, false), journal, d);
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
        _engine().certifyRole(_ctx(false, true), c.obj, c.role, c.addr);
        return _done(false);
    }

    /// @dev The new contract's code must be the artifact's, with immutables read back from it. Override
    ///      only for a contract whose constructor returns its runtime code, which the artifact cannot
    ///      show, and have the unit's `check` step prove the code another way.
    function _requireBuild(address addr, string memory artifact) internal view virtual {
        _engine().requireBuild(addr, artifact);
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

}

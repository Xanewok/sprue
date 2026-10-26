// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {chainId, planRpc} from "./Chains.sol";
import {requireBuild, requireLost} from "./DeployChecks.sol";
import {ForgeBroadcasts} from "./ForgeBroadcasts.sol";
import {isRehearsalNetwork, outputsEnv} from "./Journal.sol";

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
    /// @dev Whether `_requireNoUnjournaled` applies. True on a chain where every CREATE from a
    ///      deployer key belongs to this project, so unjournaled code at such an address is a lost
    ///      deployment.
    function _fenced() internal view virtual returns (bool);

    address private _testSender;
    bool private _testCreationsTrusted;
    /// @dev The broadcaster of the step's first broadcast, and its nonce then. `_done` clears it.
    address private _stepSender;
    uint256 private _stepNonce;
    /// @dev Each contract this unit created in this run, by chain and address. A role that a simulation
    ///      created has no transaction for the identity proof to find.
    mapping(bytes32 deployment => bool) private _createdThisRun;

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
        _createdThisRun[_deployment(_addr(journal, string.concat(".", role)))] = true;
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

    /// @dev The deployer that `network.json` pins with `deployer`, or zero when it pins none. Reverts
    ///      if the field is the zero address or forge's default sender.
    function _pinnedDeployer() internal view returns (address) {
        string memory network = _networkJson();
        // A pin's rotation is unsupported: a role a former key made would be proven, but no fence scans that key.
        require(
            !_has(network, ".formerDeployers"),
            "network.json lists formerDeployers, which sprue no longer reads: a change of the pin is not supported; remove the field, and a role an earlier key created is refused"
        );
        if (!_has(network, ".deployer")) return address(0);
        address pinned = _addr(network, ".deployer");
        require(
            pinned != address(0) && pinned != address(uint160(uint256(keccak256("foundry default caller")))),
            "network.json's deployer is the zero or forge's default address: fix it, or remove the field"
        );
        return pinned;
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

    /// @dev `_requireRecordedCode` that also takes the code a role's creation left. forge journals the code hash
    ///      of a simulation, which runs the constructor in an earlier block than the send lands in, so a
    ///      constructor that reads the block leaves other code. Only exactly the journaled initcode vouches for
    ///      that code: a CREATE2 address commits to it, and a CREATE's creation transaction must have sent it.
    ///      Outside a probe the landed hash replaces the journal's.
    function _requireLandedCode(string memory journal, string memory role, bool create2)
        internal
        returns (address addr)
    {
        string memory key = string.concat(".", role);
        string memory hashKey = string.concat(key, "CodeHash");
        // Read the address only where `_requireRecordedCode` would: it names a journal that lacks the role.
        if (_has(journal, hashKey) && _has(journal, string.concat(key, "InitcodeHash"))) {
            addr = _addr(journal, key);
            if (
                addr.code.length != 0 && addr.codehash != vm.parseJsonBytes32(journal, hashKey)
                    && _madeByInitcode(journal, role, addr, create2)
            ) {
                if (!_inProbe()) _put(hashKey, vm.toString(addr.codehash));
                return addr;
            }
        }
        return _requireRecordedCode(journal, role);
    }

    function _madeByInitcode(string memory journal, string memory role, address addr, bool create2)
        private
        returns (bool)
    {
        string memory key = string.concat(".", role);
        bytes32 initcodeHash = vm.parseJsonBytes32(journal, string.concat(key, "InitcodeHash"));
        if (create2) {
            return _has(journal, string.concat(key, "Salt"))
                && vm.computeCreate2Address(
                    vm.parseJsonBytes32(journal, string.concat(key, "Salt")), initcodeHash, CREATE2_FACTORY
                ) == addr;
        }
        bytes32 hash = _createTx(journal, role);
        return hash != 0 && _createdIn(hash, addr, false) != 0 && keccak256(_sentInput(hash)) == initcodeHash;
    }

    /// @dev The hashes of `input` without its last `tail` bytes, and of those bytes.
    function _hashSplit(bytes memory input, uint256 tail) private pure returns (bytes32 code, bytes32 rest) {
        // SAFETY: the caller checks `tail <= input.length`, so `cut` does not underflow and both ranges lie
        // within `input`.
        assembly ("memory-safe") {
            let start := add(input, 32)
            let cut := sub(mload(input), tail)
            code := keccak256(start, cut)
            rest := keccak256(add(start, cut), tail)
        }
    }

    /// @dev The transaction that created a CREATE role: its journaled `<role>Tx`, else one the unit's records
    ///      show; zero when neither does.
    function _createTx(string memory journal, string memory role) private returns (bytes32 hash) {
        string memory key = string.concat(".", role, "Tx");
        if (_has(journal, key)) return vm.parseJsonBytes32(journal, key);
        (hash,,) = _findReceipt(journal, role, _addr(journal, string.concat(".", role)), false);
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
        if (addr != address(0)) _requireLandedCode(journal, role, false);
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
        if (addr != address(0)) _requireLandedCode(journal, role, false);
    }

    /// @dev A receipt of `role` says it landed. With no code at its address, the RPC lags or the chain was
    ///      reset, and a resend or a replacement would double the deployment.
    function _requireNoLandedRecord(string memory journal, string memory role) internal view {
        require(
            !_has(journal, string.concat(".", role, "Tx")),
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

    /// @dev For a role that `journal` lacks. A CREATE, or a CREATE2 factory call, of `artifact` in
    ///      this chain's broadcast records, by any sender, may be the role's lost record, and a fresh
    ///      deployment would then be a second one. Such a record is refused while it has code, or
    ///      while its nonce may still land, with or without a receipt. Only two kinds are ignored: a
    ///      record without code whose nonce is used elsewhere, and an address in the journal's
    ///      `retired` list. Another journal naming the address does not exempt it, because that
    ///      journal can outlive the lost one.
    function _requireNoStray(string memory journal, string memory role, string memory artifact) internal view {
        _requireNoStray(journal, role, artifact, address(0));
    }

    /// @dev `adopted`, a CREATE2 address the step is about to deploy or adopt, is that role itself.
    function _requireNoStray(string memory journal, string memory role, string memory artifact, address adopted)
        internal
        view
    {
        Create[] memory creates = _creates(artifact);
        for (uint256 i; i < creates.length; ++i) {
            Create memory c = creates[i];
            if (c.addr.code.length == 0 && vm.getNonce(c.from) > c.nonce) continue;
            if (c.create2 && c.addr == adopted) continue;
            require(
                _isRetired(journal, c.addr),
                string.concat(
                    _unit(),
                    ".json lacks ",
                    role,
                    ", yet ",
                    c.path,
                    c.create2 ? " holds a CREATE2 of " : " holds a CREATE of ",
                    artifact,
                    " at ",
                    vm.toString(c.addr),
                    " that landed or may land: restore the journal",
                    c.create2 || !_hasRecoverStep() ? "" : _recoverCommand(c)
                )
            );
        }
    }

    /// @dev Whether the unit's script compiled a `recover(string)` function, read from the ABIs under
    ///      `out/<script file>/`. False when that directory is absent, so a refusal never names a
    ///      command that cannot run.
    function _hasRecoverStep() internal view returns (bool) {
        string[] memory path = vm.split(_deployScript(), "/");
        string memory dir = string.concat("out/", path[path.length - 1]);
        if (!vm.exists(dir)) return false;
        VmSafe.DirEntry[] memory files = vm.readDir(dir);
        for (uint256 i; i < files.length; ++i) {
            if (!vm.exists(files[i].path) || files[i].isDir) continue;
            string memory abi_ = vm.readFile(files[i].path);
            if (!vm.keyExistsJson(abi_, ".abi")) continue;
            for (uint256 k; vm.keyExistsJson(abi_, string.concat(".abi[", vm.toString(k), "]")); ++k) {
                string memory entry = string.concat(".abi[", vm.toString(k), "]");
                if (
                    vm.keyExistsJson(abi_, string.concat(entry, ".name"))
                        && keccak256(bytes(vm.parseJsonString(abi_, string.concat(entry, ".name"))))
                            == keccak256("recover") && vm.keyExistsJson(abi_, string.concat(entry, ".inputs[0].type"))
                        && !vm.keyExistsJson(abi_, string.concat(entry, ".inputs[1]"))
                        && keccak256(bytes(vm.parseJsonString(abi_, string.concat(entry, ".inputs[0].type"))))
                            == keccak256("string")
                ) return true;
            }
        }
        return false;
    }

    function _recoverCommand(Create memory c) private view returns (string memory) {
        return string.concat(
            ", or rebuild it: ",
            isRehearsalNetwork(_networkName()) ? outputsEnv(_dir()) : "",
            "forge script ",
            _deployScript(),
            " --sig 'recover(string)' ",
            _networkName(),
            " --rpc-url ",
            planRpc(_networkJson()),
            " --sender ",
            vm.toString(c.from)
        );
    }

    /// @dev The most nonces of one deployer that `_requireNoUnjournaled` will scan for code. A
    ///      deployer past it is refused, not partly checked.
    uint256 internal constant FENCED_NONCES = 256;

    /// @dev For a role that `journal` lacks, on a `_fenced()` chain. Code at a CREATE address of
    ///      `sender`, of the pinned deployer, or of any deployer that a journal of this network
    ///      records may be this role's deployment whose journal and broadcast records are both lost,
    ///      and a fresh deployment would then be a second one. The code passes only if a journal has
    ///      a `<role>Deployer` key and records the address as `<role>` with `<role>CodeHash` equal to
    ///      the live code hash (`_journaled`), or if the journal's `retired` list names the address.
    ///      The deployer and nonce are not compared here: that relies on the journal having been
    ///      written by `_recordSender`. Another journal merely naming the address, as a dependency,
    ///      does not count. The code itself is not compared: no build can say what a lost
    ///      deployment's code was. On a chain where `_fenced()` is false this does nothing.
    function _requireNoUnjournaled(string memory journal, string memory role, address sender) internal view {
        if (!_fenced()) return;
        string[] memory journals = _journals();
        address pinned = _pinnedDeployer();
        if (sender != DEFAULT_SENDER) _requireNoUnjournaled(journal, role, sender, journals);
        if (pinned != address(0)) _requireNoUnjournaled(journal, role, pinned, journals);
        for (uint256 j; j < journals.length; ++j) {
            string[] memory keys = vm.parseJsonKeys(journals[j], "$");
            for (uint256 k; k < keys.length; ++k) {
                if (!_endsWith(keys[k], "Deployer")) continue;
                _requireNoUnjournaled(journal, role, _addr(journals[j], string.concat(".", keys[k])), journals);
            }
        }
    }

    function _requireNoUnjournaled(
        string memory journal,
        string memory role,
        address deployer,
        string[] memory journals
    ) private view {
        uint256 used = vm.getNonce(deployer);
        require(
            used <= FENCED_NONCES,
            string.concat(
                vm.toString(deployer),
                " has used more nonces than the fence reads: a person must account for its deployments, or use a fresh deploy key, or list the chain in chains.unrecordedDeploys[<id>]"
            )
        );
        for (uint256 n; n < used; ++n) {
            address addr = vm.computeCreateAddress(deployer, n);
            if (addr.code.length == 0 || _isRetired(journal, addr) || _journaled(journals, addr)) continue;
            revert(
                string.concat(
                    _unit(),
                    ".json lacks ",
                    role,
                    ", yet ",
                    vm.toString(addr),
                    ", the CREATE of ",
                    vm.toString(deployer),
                    " at nonce ",
                    vm.toString(n),
                    ", has code no journal records: find its journal with git log --all -i -G ",
                    vm.toString(addr),
                    " -- ",
                    _dir(),
                    "; if it is none of ",
                    _unit(),
                    "'s roles, list it in ",
                    _unit(),
                    ".json's retired; if it may be one and git has no journal, stop: a person must resolve it"
                )
            );
        }
    }

    /// @dev The contents of every `.json` file in the network directory except `*.input.json`. Any
    ///      other entry reads as `{}`. Inputs are skipped because a malformed input must not abort an
    ///      unrelated step. Files that are not journals hold no `*Deployer` key, so they match
    ///      nothing.
    function _journals() private view returns (string[] memory journals) {
        VmSafe.DirEntry[] memory files = vm.readDir(_dir());
        journals = new string[](files.length);
        for (uint256 i; i < files.length; ++i) {
            string memory path = files[i].path;
            journals[i] = !files[i].isDir && _endsWith(path, ".json") && !_endsWith(path, ".input.json")
                ? vm.readFile(path)
                : "{}";
        }
    }

    /// @dev Whether some journal records `at` as a role with `at`'s current code hash. The address
    ///      fixes the deployer and nonce, which `_recordSender` keeps consistent with it. The hash
    ///      also tells a multi-chain unit's record on one chain from a CREATE on another chain by
    ///      the same key at the same nonce.
    function _journaled(string[] memory journals, address addr) private view returns (bool) {
        for (uint256 j; j < journals.length; ++j) {
            string memory journal = journals[j];
            string[] memory keys = vm.parseJsonKeys(journal, "$");
            for (uint256 k; k < keys.length; ++k) {
                if (!_endsWith(keys[k], "Deployer")) continue;
                string memory role = string.concat(".", vm.replace(keys[k], "Deployer", ""));
                if (
                    _has(journal, role) && _addr(journal, role) == addr
                        && _has(journal, string.concat(role, "CodeHash"))
                        && vm.parseJsonBytes32(journal, string.concat(role, "CodeHash")) == addr.codehash
                ) return true;
            }
        }
        return false;
    }

    /// @dev `_createToRecover` where several CREATEs of `artifact` landed, as for two roles of one
    ///      artifact: the one whose input is `initcodeHash`'s, if exactly one is.
    function _createToRecover(
        string memory journal,
        string memory role,
        string memory artifact,
        address sender,
        bytes32 initcodeHash
    ) internal returns (Create memory found) {
        if (_has(journal, string.concat(".", role))) return found;
        bool landed;
        (landed, found) = _landedCreate(journal, role, artifact, sender, initcodeHash);
        if (landed) _requireNoKeysOf(journal, role);
    }

    /// @dev Reverts unless `found`, if set, was made from this build's `artifact` with `args`, as the
    ///      chain shows. A genuine deployment from other inputs is an earlier one, not the one the
    ///      journal lost.
    function _requireCurrent(Create memory found, string memory artifact, bytes memory args) internal {
        if (found.addr == address(0)) return;
        bytes memory input = _txInput(found);
        require(
            keccak256(input) == _initcodeHash(artifact, args),
            string.concat(
                found.path,
                " records ",
                artifact,
                " at ",
                vm.toString(found.addr),
                " with initcode other than this build's with the current inputs: if it is the lost deployment,",
                " restore the commit and inputs that made it; if not, list it in ",
                _unit(),
                ".json's retired"
            )
        );
        require(
            vm.computeCreateAddress(found.from, found.nonce) == found.addr, "a deployment is not at its sender's nonce"
        );
        Create memory landed = _landedAsRecorded(artifact, found, input);
        (found.path, found.record, found.run, found.key, found.args) =
        (landed.path, landed.record, landed.run, landed.key, args);
    }

    /// @dev Writes each role of `roles` (role, artifact) whose `found` is set. Call it only after
    ///      every check passed, so that a refusal leaves no key behind.
    function _journalRecovered(string memory journal, string[2][] memory roles, Create[] memory found) internal {
        bool recovered;
        for (uint256 i; i < roles.length; ++i) {
            if (found[i].addr == address(0)) continue;
            _recoverRole(roles[i][0], roles[i][1], found[i]);
            recovered = true;
        }
        if (recovered && !_has(journal, _selectedStampKey())) _putChainStamp();
    }

    /// @dev Reverts if the journal holds any extension key of `role`, so that recovery never writes
    ///      over part of a role. A key counts if it is `<role>` followed by an uppercase letter, so a
    ///      unit's own extensions (`<role>Salt`) count without being listed here.
    function _requireNoKeysOf(string memory journal, string memory role) private view {
        string[] memory keys = vm.parseJsonKeys(journal, "$");
        uint256 n = bytes(role).length;
        for (uint256 i; i < keys.length; ++i) {
            bytes memory k = bytes(keys[i]);
            if (k.length <= n || vm.indexOf(keys[i], role) != 0 || k[n] < "A" || k[n] > "Z") continue;
            revert(string.concat(_unit(), ".json holds ", keys[i], " but not ", role, ": a person must resolve it"));
        }
    }

    /// @dev `_put`, unless `journal` holds `key`.
    function _putNew(string memory journal, string memory key, string memory value) internal {
        if (!_has(journal, key)) _put(key, value);
    }

    /// @dev Journals a recovered role. The original code hash is lost, so it records the live code's
    ///      hash, which proves nothing about the code. What vouches for it is the initcode check in
    ///      `_requireCurrent`.
    function _recoverRole(string memory role, string memory artifact, Create memory found) private {
        bytes memory input = _txInput(found);
        _recordSender(role, found.addr, found.from, found.nonce);
        _put(string.concat(".", role, "Args"), vm.toString(found.args));
        _put(string.concat(".", role, "InitcodeHash"), vm.toString(keccak256(input)));
        require(
            input.length >= found.args.length, string.concat("the recovered ", role, "'s arguments exceed its input")
        );
        (bytes32 code,) = _hashSplit(input, found.args.length);
        _put(string.concat(".", role, "CreationCodeHash"), vm.toString(code));
        _recordBuild(role, found.addr, artifact);
        (bool hasCommit, string memory commit) = _commit(found);
        if (hasCommit) _put(string.concat(".", role, "Commit"), string.concat('"', commit, '"'));
        _put(string.concat(".", role), vm.toString(found.addr));
        _recordReceipt(_journal(), role, found.addr);
        console.log("recovered", role, found.addr);
    }

    /// @dev `sender`'s one CREATE of `artifact` on this chain that has code, ignoring addresses the
    ///      journal's `retired` list names. Only `sender`'s count: an address another sender created
    ///      is not this project's to adopt, so the stray guard keeps refusing it until a person
    ///      resolves it. Reverts if a CREATE has no code but its nonce is unused, or if two
    ///      different ones landed and not exactly one of them with input `initcodeHash`.
    function _landedCreate(
        string memory journal,
        string memory role,
        string memory artifact,
        address sender,
        bytes32 initcodeHash
    ) private returns (bool, Create memory found) {
        Create[] memory creates = _creates(artifact);
        string memory landed;
        uint256 count;
        uint256 matching;
        Create memory match_;
        for (uint256 i; i < creates.length; ++i) {
            Create memory c = creates[i];
            if (c.from != sender || c.create2 || _isRetired(journal, c.addr)) continue;
            if (c.addr.code.length == 0) {
                require(
                    vm.getNonce(sender) > c.nonce,
                    string.concat(
                        _unit(),
                        ".json lacks ",
                        role,
                        ", yet ",
                        c.path,
                        " holds a CREATE of ",
                        artifact,
                        " at ",
                        vm.toString(c.addr),
                        " that may still land: wait, or spend the nonce"
                    )
                );
                continue;
            }
            // forge writes each run twice, as `-latest` and timestamped, so an address can repeat.
            // The same address with other initcode is a transaction replaced at that nonce, and only
            // the chain knows which one landed.
            if (vm.contains(landed, vm.toString(c.addr))) {
                require(
                    c.addr != found.addr || keccak256(_txInput(c)) == keccak256(_txInput(found)),
                    string.concat(
                        _unit(),
                        ".json lacks ",
                        role,
                        ", and the records create ",
                        artifact,
                        " at ",
                        vm.toString(c.addr),
                        " with different initcode: a person must choose"
                    )
                );
                continue;
            }
            landed = count == 0 ? vm.toString(c.addr) : string.concat(landed, ", ", vm.toString(c.addr));
            found = c;
            ++count;
            if (initcodeHash != 0 && keccak256(_txInput(c)) == initcodeHash) {
                match_ = c;
                ++matching;
            }
        }
        if (count > 1 && matching == 1) return (true, match_);
        require(
            count < 2,
            string.concat(
                _unit(),
                ".json lacks ",
                role,
                ", and ",
                vm.toString(sender),
                " created ",
                artifact,
                " at ",
                landed,
                ": a person must choose"
            )
        );
        return (count == 1, found);
    }

    /// @dev A CREATE replaced at the same nonce outside forge lands other initcode at the same
    ///      address with no record, so the recorded initcode proves nothing about the live code. The
    ///      chain must therefore show that a transaction of a run recording `found`'s CREATE, with
    ///      `input`, created it. A resend with a higher fee leaves the landed hash in another run.
    ///      `forge test` keeps no transaction history, so under test this takes `found` as the
    ///      record that landed. Only a run against a live node proves it.
    function _landedAsRecorded(string memory artifact, Create memory found, bytes memory input)
        private
        returns (Create memory)
    {
        if (vm.isContext(VmSafe.ForgeContext.Test)) return found;
        Create[] memory creates = _creates(artifact);
        for (uint256 i; i < creates.length; ++i) {
            Create memory c = creates[i];
            if (
                !c.create2 && c.addr == found.addr && keccak256(_txInput(c)) == keccak256(input)
                    && _isLandedIn(c, input)
            ) {
                return c;
            }
        }
        revert(
            string.concat(
                "no transaction of ",
                found.path,
                " that the chain shows created ",
                vm.toString(found.addr),
                " sent the recorded initcode: a person must resolve it"
            )
        );
    }

    /// @dev Any of the run's hashes may be `c`'s: see `_recordReceipt`.
    function _isLandedIn(Create memory c, bytes memory input) private returns (bool) {
        for (uint256 j; _hasTransaction(c, j); ++j) {
            (bool ok, bytes32 hash) = _candidateHash(c, j);
            if (!ok || _createdIn(hash, c.addr, false) == 0) continue;
            if (keccak256(_sentInput(hash)) == keccak256(input)) return true;
        }
        return false;
    }

    /// @dev Whether the journal's `retired` list names `at`.
    function _isRetired(string memory journal, address addr) private view returns (bool) {
        if (!_has(journal, ".retired")) return false;
        address[] memory retired = vm.parseJsonAddressArray(journal, ".retired");
        for (uint256 i; i < retired.length; ++i) {
            if (retired[i] == addr) return true;
        }
        return false;
    }

    /// @dev The broadcaster and its next nonce, read inside the broadcast that will use them.
    function _broadcaster() internal returns (address deployer, uint256 nonce) {
        (, deployer,) = vm.readCallers();
        nonce = vm.getNonce(deployer);
    }

    /// @dev Records the deployer and nonce, which fix the CREATE address, so that a rerun can tell a
    ///      lost broadcast from a pending one. Reverts if `deployed` is not that address.
    function _recordSender(string memory role, address deployed, address deployer, uint256 nonce) internal {
        require(vm.computeCreateAddress(deployer, nonce) == deployed, "a deployment is not at its sender's nonce");
        _put(string.concat(".", role, "Deployer"), vm.toString(deployer));
        _put(string.concat(".", role, "Nonce"), vm.toString(nonce));
    }

    function _recordIntent(string memory role, string memory name, bytes memory args) internal {
        _put(string.concat(".", role, "Args"), vm.toString(args));
        _put(string.concat(".", role, "InitcodeHash"), vm.toString(_initcodeHash(name, args)));
        _put(
            string.concat(".", role, "CreationCodeHash"),
            vm.toString(keccak256(vm.getCode(string.concat(name, ".sol:", name))))
        );
    }

    function _initcodeHash(string memory name, bytes memory args) internal view returns (bytes32) {
        return keccak256(_initcode(name, args));
    }

    function _initcode(string memory name, bytes memory args) internal view returns (bytes memory) {
        return bytes.concat(vm.getCode(string.concat(name, ".sol:", name)), args);
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
            _requireLandedCode(journal, role, true);
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

    /// @dev Deploys `role` from `artifact`'s initcode with `args`, or proves its reuse by its journaled
    ///      identity and then `ensure`. It reuses the journaled deployment, resends its pending intent as the
    ///      same transaction, or sends a new one. On a network that pins a deployer, only the pin sends it,
    ///      whatever the opt-in to another key: another key's CREATE could never pass the identity proof.
    ///      `sent` is whether this run creates a transaction, which a simulation counts.
    function _deployIdentified(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        function(address, bytes memory) internal ensure
    ) internal returns (address addr, bool sent) {
        if (_inProbe()) {
            addr = _reuseForDue(journal, role, artifact, args);
            // A probe has no broadcaster, so it decides as a `Due` view does, and the step decides whether it
            // resends its pending intent or sends anew.
            if (addr == address(0)) revert StepDue();
            _requireCreateIdentity(journal, role, args);
            ensure(addr, args);
            return (addr, false);
        }
        _startBroadcast();
        (address deployer, uint256 nonce) = _broadcaster();
        address recorded = _reuseForSend(journal, role, artifact, args, deployer, nonce);
        sent = recorded == address(0);
        if (sent) {
            _requireDeployable(true);
            addr = _createFrom(_initcode(artifact, args));
            _requireBuild(addr, artifact);
            _createdThisRun[_deployment(addr)] = true;
        } else {
            addr = recorded;
            _requireCreateIdentity(journal, role, args);
            ensure(addr, args);
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

    /// @dev `role`'s address is the CREATE of its recorded deployer at its recorded nonce, that deployer is
    ///      the one `network.json` pins, its recorded arguments are `args`, and the transaction that created
    ///      it sent `args`: the journal's `<role>Tx`, a broadcast record's, the
    ///      chain's at the recorded nonce, or this run's. On a network that pins no deployer, the recorded
    ///      deployer stands, with a warning: nothing then says whose CREATE the role must be.
    function _requireCreateIdentity(string memory journal, string memory role, bytes memory args) internal {
        string memory key = string.concat(".", role);
        address addr = _addr(journal, key);
        _requireCreateRecord(_unit(), journal, role, addr);
        _requireKey(_unit(), journal, role, "Args");
        require(
            keccak256(vm.parseJsonBytes(journal, string.concat(key, "Args"))) == keccak256(args),
            string.concat(role, "'s constructor arguments differ from ", _unit(), ".json")
        );
        if (_createdThisRun[_deployment(addr)]) return;
        bytes32 hash = _createTx(journal, role);
        if (hash == 0) {
            require(
                _testCreationsTrusted,
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
            return;
        }
        // The journal's arguments vouch for nothing: an edit can match them to the input while the contract
        // holds what its creation sent.
        require(
            _createdIn(hash, addr, false) != 0,
            string.concat(role, "Tx in ", _unit(), ".json did not create ", role, ": a person must resolve it")
        );
        bytes memory input = _sentInput(hash);
        require(
            input.length >= args.length && _sentArgs(input, args.length) == keccak256(args),
            string.concat(role, "'s creation sent other constructor arguments than its input: a person must resolve it")
        );
    }

    function _sentArgs(bytes memory input, uint256 length) private pure returns (bytes32 rest) {
        (, rest) = _hashSplit(input, length);
    }

    /// @dev `unit`'s `journal` puts `role` at `addr` by a CREATE of its recorded deployer at its
    ///      recorded nonce, and that deployer is the pin, if `network.json` has a pin.
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
            require(deployer == pinned, string.concat(role, "'s recorded deployer is not network.json's deployer"));
        }
        require(
            vm.computeCreateAddress(deployer, _uint(journal, string.concat(key, "Nonce"))) == addr,
            string.concat(role, "'s address is not its recorded deployer's CREATE at its recorded nonce")
        );
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
    function _recordBuild(string memory role, address deployed, string memory name) internal {
        if (_inProbe()) revert StepDue();
        string memory metadataPath = string.concat(_dir(), "/", name, ".metadata.json");
        vm.writeFile(
            metadataPath,
            vm.parseJsonString(vm.readFile(string.concat("out/", name, ".sol/", name, ".json")), ".rawMetadata")
        );
        _put(string.concat(".", role, "Commit"), '"pending"');
        _put(string.concat(".", role, "CodeHash"), vm.toString(deployed.codehash));
        _put(string.concat(".", role, "Metadata"), string.concat('"', metadataPath, '"'));
    }

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
                ": only the pin sends a declared CREATE role, whose address follows from its sender: sign as the pin"
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

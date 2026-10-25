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
    /// @dev The script that a refusal's recovery command names. It must hold the unit's
    ///      `recover(string)` step. Called only when `_hasRecoverStep()`.
    function _deployScript() internal view virtual returns (string memory);

    /// @dev Whether `_requireNoUnjournaled` applies. True on a chain where every CREATE from a
    ///      deployer key belongs to this project, so unjournaled code at such an address is a lost
    ///      deployment.
    function _fenced() internal view virtual returns (bool);

    address private _testSender;
    /// @dev The initcode hash of each contract this unit's `_deployRole` created in this run, by chain
    ///      and address. A role that a simulation created has no transaction for `_requireCreatedFrom`
    ///      to read.
    mapping(bytes32 deployment => bytes32) private _createdThisRun;

    /// @dev Lets a test send each step as that step's sender. Reverts outside forge's test commands,
    ///      so a script's broadcast sends as forge's own sender (`--sender`, `--account`).
    function setTestSender(address sender) external {
        require(vm.isContext(VmSafe.ForgeContext.TestGroup), "only a test chooses the sender");
        _testSender = sender;
    }

    function _startBroadcast() internal {
        if (_testSender == address(0)) vm.startBroadcast();
        else vm.startBroadcast(_testSender);
    }

    /// @dev The deployer that `network.json` pins with `deployer`, or zero when it pins none. Reverts
    ///      if the field is the zero address or forge's default sender.
    function _pinnedDeployer() internal view returns (address) {
        string memory network = _networkJson();
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
    ///      with neither passes under forge's test commands, which keep no transaction history. For a
    ///      role created otherwise, compare `_findCreationInput` with what it was created from.
    function _requireCreatedFrom(string memory journal, string memory role, string memory artifact, bytes memory args)
        internal
    {
        bytes32 expected = _initcodeHash(artifact, args);
        bytes32 created = _createdThisRun[_deployment(_addr(journal, string.concat(".", role)))];
        if (created == 0) {
            bytes32 hash = _creationTx(journal, role);
            if (hash == 0 && vm.isContext(VmSafe.ForgeContext.TestGroup)) return;
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

    function _creationTx(string memory journal, string memory role) private returns (bytes32 hash) {
        string memory key = string.concat(".", role);
        if (_has(journal, string.concat(key, "Tx"))) return vm.parseJsonBytes32(journal, string.concat(key, "Tx"));
        address addr = _addr(journal, key);
        (hash,,) = _findReceipt(journal, role, addr, false);
        if (hash == 0) (hash,,) = _findReceipt(journal, role, addr, true);
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
        ) return address(0);
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
            return address(0);
        }
        addr = _reusableAddress(journal, role);
        if (addr != address(0)) _requireRecordedCode(journal, role);
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

    /// @dev The one landed CREATE of `artifact` by `sender` on this chain, for a `recover` step to
    ///      journal as `role` once `_requireCurrent` holds. Returns a `Create` with a zero `at` when
    ///      the journal already has the role or no such CREATE landed.
    function _createToRecover(string memory journal, string memory role, string memory artifact, address sender)
        internal
        returns (Create memory found)
    {
        if (_has(journal, string.concat(".", role))) return found;
        bool landed;
        (landed, found) = _landedCreate(journal, role, artifact, sender);
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
    ///      different ones landed.
    function _landedCreate(string memory journal, string memory role, string memory artifact, address sender)
        private
        returns (bool, Create memory found)
    {
        Create[] memory creates = _creates(artifact);
        string memory landed;
        uint256 count;
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
        }
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
    ///      pending intent as the same transaction, or sends a new one. `create` must contain the
    ///      typed `new` expression, which is how forge names the broadcast's contract, and pass it
    ///      `args`: the journaled intent, and `_requireCreatedFrom` within this run, take them as the
    ///      constructor's.
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
        return _deployRole(journal, role, artifact, args, create, authenticate, false);
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
        return _deployRole(journal, role, artifact, args, create, _noState, true);
    }

    function _noState(address, bytes memory) private view {}

    function _deployment(address addr) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, addr));
    }

    function _deployRole(
        string memory journal,
        string memory role,
        string memory artifact,
        bytes memory args,
        function(bytes memory) internal returns (address) create,
        function(address, bytes memory) internal view authenticate,
        bool byCreation
    ) private returns (address addr, bool sent) {
        _startBroadcast();
        (address deployer, uint256 nonce) = _broadcaster();
        address recorded = _reuseForSend(journal, role, artifact, args, deployer, nonce);
        sent = recorded == address(0);
        if (sent) {
            _requireDeployable();
            addr = create(args);
            _requireBuild(addr, artifact);
            _createdThisRun[_deployment(addr)] = _initcodeHash(artifact, args);
        } else {
            addr = recorded;
            if (byCreation) _requireCreatedFrom(journal, role, artifact, args);
            else authenticate(addr, args);
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

    /// @dev The new contract's code must be the artifact's, with immutables read back from it. Override
    ///      only for a contract whose constructor returns its runtime code, which the artifact cannot
    ///      show, and have the unit's `check` step prove the code another way.
    function _requireBuild(address addr, string memory artifact) internal view virtual {
        requireBuild(addr, artifact);
    }

    /// @dev Called only when this run creates a new deployment transaction, simulated or broadcast,
    ///      before the intent and the address are journaled. The default records the selected chain's
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
    function _requireDeployable() internal {
        (address sender,) = _broadcaster();
        require(
            vm.isContext(VmSafe.ForgeContext.Test) || sender != DEFAULT_SENDER,
            "pass --sender <deployer> to the dry run, or --account"
        );
        address pinned = _pinnedDeployer();
        if (pinned == address(0) || sender == pinned) return;
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

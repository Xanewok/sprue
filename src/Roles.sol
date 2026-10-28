// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {requireBuild} from "./DeployChecks.sol";
import {Deployment} from "./Deployment.sol";
import {Input} from "./Journal.sol";

/// @dev How a role's address is made, which fixes how its reuse is proven.
enum Kind {
    Create,
    Create2,
    Extern,
    Child
}

/// @dev A contract a unit deploys or reads, declared once. Fields are named apart from the builders:
///      solc rejects a member named like a function attached to the struct.
struct Role {
    /// @dev The unit whose journal records the role; empty for the unit that uses it.
    string declaredBy;
    string name;
    string artifact;
    Kind kind;
    /// @dev `create2`: the input key that holds `salt` and `address`. `extern`: the input key of the address.
    string key;
    /// @dev `child` and `runtime` only: the role whose creation made this one.
    string parent;
    /// @dev `child` only: the selector of the parent's getter; zero for a `runtime`.
    bytes4 getter;
    /// @dev `extern` only.
    bytes32 codeHash;
    bool computed;
    bytes fixedArgs;
    function() internal returns (bytes memory) argsFn;
    function(address, bytes memory) internal ensureFn;
}

using RoleLib for Role global;

/// @dev A role the unit's deployer creates with CREATE. Its address follows from the deployer and the nonce
///      the journal records.
function create(string memory name, string memory artifact) pure returns (Role memory r) {
    r.name = name;
    r.artifact = artifact;
    r.argsFn = _noArgs;
    r.ensureFn = _ensureNothing;
}

/// @dev A role the CREATE2 factory creates. The unit's input holds `<key>.salt` and `<key>.address`, so a
///      reviewer sees the address before any send.
function create2(string memory name, string memory artifact, string memory key) pure returns (Role memory r) {
    r = create(name, artifact);
    r.kind = Kind.Create2;
    r.key = key;
}

/// @dev A contract the unit did not deploy: the unit's input holds its address at `key`, and its code must
///      hash to `codeHash`.
function extern(string memory name, string memory key, bytes32 codeHash) pure returns (Role memory r) {
    r.name = name;
    r.kind = Kind.Extern;
    r.key = key;
    r.codeHash = codeHash;
    r.argsFn = _noArgs;
    r.ensureFn = _ensureNothing;
}

/// @dev A contract that `parent`'s constructor creates, at the address that the parent's getter returns, such
///      as `Launcher.HOOK.selector`, which the compiler checks. The parent's code must hold that address, as an
///      immutable does. It takes no `.args`, and its `.ensure` gets empty arguments: the parent passed them.
function child(string memory name, string memory artifact, Role memory parent, bytes4 getter)
    pure
    returns (Role memory r)
{
    r = create(name, artifact);
    r.kind = Kind.Child;
    r.getter = getter;
    r.parent = parent.name;
}

/// @dev The code `parent`'s constructor returned in place of its own: `artifact`'s runtime, perhaps with data
///      after it, at `parent`'s address. `parent` keeps the build that created it, and this role names the
///      program the address runs.
function runtime(string memory name, string memory artifact, Role memory parent) pure returns (Role memory r) {
    r = child(name, artifact, parent, bytes4(0));
}

/// @dev Each builder edits the memory struct it is given and returns that same struct.
library RoleLib {
    /// @dev Constructor arguments fixed in the source.
    function args(Role memory r, bytes memory value) internal pure returns (Role memory) {
        _requireNotChild(r);
        if (r.computed) revert(_twice(r));
        r.fixedArgs = value;
        return r;
    }

    /// @dev Constructor arguments built when used, from the inputs and the roles already deployed.
    function args(Role memory r, function() internal returns (bytes memory) fn) internal pure returns (Role memory) {
        _requireNotChild(r);
        if (r.fixedArgs.length != 0) revert(_twice(r));
        r.argsFn = fn;
        r.computed = true;
        return r;
    }

    /// @dev `fn(addr, args)` runs each time the role is proven, with its address and its constructor arguments
    ///      (empty for an extern role), and reverts on state that later transactions changed. It may read other
    ///      roles with `_at`, but not this one.
    function ensure(Role memory r, function(address, bytes memory) internal fn) internal pure returns (Role memory) {
        r.ensureFn = fn;
        return r;
    }

    /// @dev The role as another unit reads it: `unitName`'s journal records it.
    function unit(Role memory r, string memory unitName) internal pure returns (Role memory) {
        r.declaredBy = unitName;
        return r;
    }
}

function _noArgs() pure returns (bytes memory) {}

/// @dev Neither form may win silently: an author who wrote both meant one.
function _twice(Role memory r) pure returns (string memory) {
    return string.concat(r.name, "'s .args is given both as bytes and as a function: keep one");
}

function _ensureNothing(address, bytes memory) pure {}

function _requireNotChild(Role memory r) pure {
    if (r.kind == Kind.Child) revert(string.concat(r.name, "'s constructor arguments are its parent's: drop .args"));
}

/// @dev Guarantees: `_deploy` and `_at` return a role only once its journaled identity gives its address, its
///      code hash is the journaled one, and, for the unit's own role, its journaled arguments are the declared
///      ones and its `.ensure` passes. Relies on: the journaled arguments, which no step re-reads from the
///      creation transaction.
abstract contract Roles is Deployment {
    struct Proved {
        string name;
        address addr;
        Kind kind;
        /// @dev A step may select several forks: a proof holds on its own chain only.
        uint256 chainId;
        /// @dev `_declarationOf` the role proven, which a later `_at` of the name must match.
        bytes32 declaration;
    }

    /// @dev This unit's roles that `_deploy` or `_at` proved in the open step, or that `recover` found. A dry
    ///      run journals nothing, so a later role's `.args` read an earlier role of the same step from here.
    Proved[] private _proved;
    mapping(bytes32 => bool) private _checking;

    /// @dev The unit's roles, in the order its `recover` journals them.
    function _roles() internal view virtual returns (Role[] memory) {}

    function _list(Role memory a) internal pure returns (Role[] memory r) {
        r = new Role[](1);
        r[0] = a;
    }

    function _list(Role memory a, Role memory b) internal pure returns (Role[] memory r) {
        r = new Role[](2);
        (r[0], r[1]) = (a, b);
    }

    function _list(Role memory a, Role memory b, Role memory c) internal pure returns (Role[] memory r) {
        r = new Role[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function _list(Role memory a, Role memory b, Role memory c, Role memory d) internal pure returns (Role[] memory r) {
        r = new Role[](4);
        (r[0], r[1], r[2], r[3]) = (a, b, c, d);
    }

    /// @dev Ends the step with `_done()` unless the body did, as `_endCheck` does. An early `return` still
    ///      reaches it.
    modifier step(string calldata network) {
        _use(network);
        _;
        if (_stepOpen) _done();
    }

    function _stepEnded() internal virtual override {
        super._stepEnded();
        delete _proved;
    }

    /// @dev Deploys `r`, or proves its reuse, and returns its address. A step that deploys several roles
    ///      calls it once for each, in order; in a probe the first role due ends the step.
    function _deploy(Role memory r) internal returns (address addr) {
        require(_own(r), string.concat(r.name, " is ", r.declaredBy, "'s role: read it with _at"));
        require(r.kind != Kind.Extern, string.concat(r.name, " is extern: read it with _at"));
        require(r.kind != Kind.Child, string.concat(r.name, " is ", r.parent, "'s: deploy ", r.parent));
        _requireDeclared(r);
        string memory journal = _journal();
        bool journaled = _has(journal, string.concat(".", r.name));
        bytes memory a = _argsOf(r);
        _enterCheck(r);
        if (r.kind == Kind.Create) {
            (addr,) = _deployIdentified(journal, r.name, r.artifact, a, r.ensureFn);
        } else {
            (bytes32 salt, address at) = _create2Input(r);
            _deployRoleCreate2(journal, r.name, r.artifact, a, salt, at, r.ensureFn);
            addr = at;
        }
        _checking[keccak256(bytes(r.name))] = false;
        _proven(r, addr);
        // So that a reader finds the children with a new parent. Those of an older parent are `check`'s, so that
        // a probe of this step, which journals nothing for a reused role, still says what its run does.
        if (!journaled && _writing() && !_inProbe()) _recordChildren(r.name);
    }

    /// @dev `r`'s address, proven, without a send. For another unit's role (`.unit(unitName)`), its arguments
    ///      and `.ensure` are its unit's to prove, so only its identity and code are.
    function _at(Role memory r) internal returns (address addr) {
        if (!_own(r)) return _atOther(r);
        uint256 proved = _provedIndex(r.name);
        if (proved != type(uint256).max) {
            require(_proved[proved].declaration == _declarationOf(r), _undeclared(r));
            return _proved[proved].addr;
        }
        _requireDeclared(r);
        if (r.kind == Kind.Extern) {
            addr = _requiredAddress(_inputFile(_unit()), r.key);
            _requireCode(addr, r.name);
            require(addr.codehash == r.codeHash, string.concat(r.name, "'s code is not the code its role pins"));
            _enterCheck(r);
            r.ensureFn(addr, "");
        } else if (r.kind == Kind.Child) {
            return _proveChild(r, _journal());
        } else {
            string memory journal = _journal();
            bytes memory a = _argsOf(r);
            addr = _requireLandedCode(journal, r.name, r.kind == Kind.Create2);
            if (r.kind == Kind.Create) _requireCreateIdentity(journal, r.name, a);
            else _requireCreate2Record(journal, r.name, a, true);
            _enterCheck(r);
            r.ensureFn(addr, a);
        }
        _checking[keccak256(bytes(r.name))] = false;
        _proven(r, addr);
    }

    /// @dev Another unit's role, proven as `_at` proves it, and readable in a view: what the role's code fixes
    ///      is proven here, and what its unit configured after the deploy is for the step to read.
    function _atOther(Role memory r) internal view returns (address addr) {
        if (r.kind == Kind.Extern) {
            addr = _requiredAddress(_inputFile(r.declaredBy), r.key);
            _requireCode(addr, r.name);
            require(addr.codehash == r.codeHash, string.concat(r.name, "'s code is not the code its role pins"));
            return addr;
        }
        string memory journal = _journalOf(r.declaredBy);
        string memory key = string.concat(".", r.name);
        require(_has(journal, key), string.concat(r.declaredBy, ".json records no ", r.name));
        if (r.kind == Kind.Child) {
            // The parent's code fixes the child's address, so a proven parent proves where the child is.
            Role memory parent = create(r.parent, "").unit(r.declaredBy);
            if (_has(journal, string.concat(".", r.parent, "Salt"))) parent.kind = Kind.Create2;
            require(
                parent.kind == Kind.Create2 || _has(journal, string.concat(".", r.parent, "Deployer")),
                string.concat("another unit reads only a child of a CREATE or CREATE2 role, and ", r.parent, " is not")
            );
            address at = _atOther(parent);
            addr = _childOf(r, at);
            if (!_describes(journal, r, addr)) _requireChildCode(r, at, addr);
            return addr;
        }
        addr = _addr(journal, key);
        _requireCode(addr, r.name);
        require(
            _has(journal, string.concat(key, "CodeHash"))
                && addr.codehash == vm.parseJsonBytes32(journal, string.concat(key, "CodeHash")),
            string.concat(r.name, "'s code differs from ", r.declaredBy, ".json")
        );
        if (r.kind == Kind.Create) _requireCreateRecord(r.declaredBy, journal, r.name, addr);
        else _requireCreate2Record(journal, r.name, "", false);
    }

    function _enterCheck(Role memory r) private {
        bytes32 key = keccak256(bytes(r.name));
        require(
            !_checking[key],
            string.concat(r.name, "'s .ensure reads ", r.name, " itself: use the address and arguments it is given")
        );
        _checking[key] = true;
    }

    /// @dev `recover` and `_endCheck` take the roles from `_roles()`, so a role the unit uses must be there.
    function _requireDeclared(Role memory r) private view {
        require(_declarationOf(_declared(r.name)) == _declarationOf(r), _undeclared(r));
    }

    /// @dev What fixes how a role is proven; its arguments and `.ensure` are the unit's code, and are not compared.
    function _declarationOf(Role memory r) private pure returns (bytes32) {
        return keccak256(abi.encode(r.kind, r.artifact, r.key, r.parent, r.getter, r.codeHash));
    }

    function _undeclared(Role memory r) private pure returns (string memory) {
        return string.concat(r.name, " differs from its declaration in ", _unit(), "'s _roles()");
    }

    function _declared(string memory name) private view returns (Role memory) {
        Role[] memory declared = _roles();
        for (uint256 i; i < declared.length; ++i) {
            if (keccak256(bytes(declared[i].name)) == keccak256(bytes(name))) return declared[i];
        }
        revert(string.concat(name, " is not in ", _unit(), "'s _roles(): declare it there"));
    }

    /// @dev `r`'s address given its parent's.
    function _childOf(Role memory r, address parent) private view returns (address) {
        if (r.getter == 0) return parent;
        (bool ok, bytes memory ret) = parent.staticcall(abi.encodeWithSelector(r.getter));
        require(
            ok && ret.length == 32,
            string.concat(r.parent, "'s getter ", vm.toString(abi.encodePacked(r.getter)), " returns no address")
        );
        return abi.decode(ret, (address));
    }

    /// @dev Whether the journal's record of `r` names `addr` with its current code: the code hash then stands for
    ///      the artifact check the record was written after. A record that does not, as when the code landed
    ///      other than the simulation that wrote it, is a stale copy that the next `check` writes again.
    function _describes(string memory journal, Role memory r, address addr) private view returns (bool) {
        string memory key = string.concat(".", r.name);
        return _has(journal, key) && _addr(journal, key) == addr
            && addr.codehash == vm.parseJsonBytes32(journal, string.concat(key, "CodeHash"));
    }

    function _requireChildCode(Role memory r, address parent, address addr) private view {
        _requireCode(addr, r.name);
        // An artifact is large, and a step that proves a parent has read the parent's already.
        uint256 mark = _freeMemory();
        if (r.getter != 0) {
            // In the parent's code, the address is fixed by the parent's proven code hash. A getter that reads
            // storage could name another contract tomorrow, which no record of a creation may follow.
            require(
                vm.indexOf(vm.toString(parent.code), _word(addr)) != type(uint256).max,
                string.concat(
                    r.parent, "'s getter for ", r.name, " does not return an immutable: read it with _at as an extern"
                )
            );
            _requireBuild(addr, r.artifact);
        } else {
            _requireProgram(addr, r.artifact);
        }
        _releaseMemory(mark);
    }

    /// @dev `addr` as the 64 hex digits of the word an immutable holds.
    function _word(address addr) private pure returns (string memory) {
        return string.concat("000000000000000000000000", vm.split(vm.toLowercase(vm.toString(addr)), "0x")[1]);
    }

    function _requireProgram(address addr, string memory artifact) private view {
        bytes memory program = vm.getDeployedCode(string.concat(artifact, ".sol:", artifact));
        bytes memory live = addr.code;
        require(
            live.length >= program.length && keccak256(program) == _prefixHash(live, program.length),
            string.concat(vm.toString(addr), "'s code does not start with ", artifact, "'s program")
        );
    }

    function _prefixHash(bytes memory b, uint256 length) private pure returns (bytes32 h) {
        assembly ("memory-safe") {
            h := keccak256(add(b, 0x20), length)
        }
    }

    /// @dev An artifact whose constructor returns a `runtime`'s program runs that program, not its own, in every
    ///      role of it; what follows the program is for the unit's `check` to prove.
    function _requireBuild(address addr, string memory artifact) internal view virtual override {
        Role[] memory declared = _roles();
        for (uint256 i; i < declared.length; ++i) {
            Role memory r = declared[i];
            if (r.kind != Kind.Child || r.getter != 0 || !_own(r)) continue;
            if (keccak256(bytes(_declared(r.parent).artifact)) == keccak256(bytes(artifact))) {
                return _requireProgram(addr, r.artifact);
            }
        }
        super._requireBuild(addr, artifact);
    }

    function _requireCreatedDeclared(string memory role, address deployed, address[] memory created)
        internal
        view
        override
    {
        Role[] memory declared = _roles();
        for (uint256 i; i < created.length; ++i) {
            // An address with no code holds nothing to journal: a helper that self-destructed, or a simulated
            // address that the landed transaction did not use.
            if (created[i] == deployed || created[i].code.length == 0) continue;
            if (_covers(declared, role, deployed, created[i])) continue;
            revert(
                string.concat(
                    role,
                    "'s creation also created ",
                    vm.toString(created[i]),
                    ": declare it in _roles() as child(name, artifact, <the ",
                    role,
                    " role>, <its getter>.selector)"
                )
            );
        }
    }

    /// @dev Whether a child of `parent` (at `parentAddr`), or a child of one, is at `addr`.
    function _covers(Role[] memory declared, string memory parent, address parentAddr, address addr)
        private
        view
        returns (bool)
    {
        for (uint256 i; i < declared.length; ++i) {
            Role memory r = declared[i];
            if (r.kind != Kind.Child || !_own(r)) continue;
            if (keccak256(bytes(r.parent)) != keccak256(bytes(parent))) continue;
            address at = _childOf(r, parentAddr);
            if (at == addr || _covers(declared, r.name, at, addr)) return true;
        }
        return false;
    }

    function _proveChild(Role memory r, string memory journal) private returns (address addr) {
        address parent = _at(_declared(r.parent));
        addr = _childOf(r, parent);
        if (!_describes(journal, r, addr)) _requireChildCode(r, parent, addr);
        _enterCheck(r);
        r.ensureFn(addr, "");
        _checking[keccak256(bytes(r.name))] = false;
        _proven(r, addr);
    }

    /// @dev Proves each child of `parent` and its children (each child, if empty), and journals each one the
    ///      journal does not describe. One read of the journal for all: a step may hold much memory by now, so a
    ///      large journal costs much gas with each read.
    function _recordChildren(string memory parent) private {
        uint256 mark = _freeMemory();
        string memory journal = _journal();
        Role[] memory declared = _roles();
        for (uint256 i; i < declared.length; ++i) {
            Role memory r = declared[i];
            if (!_own(r) || r.kind != Kind.Child) continue;
            if (bytes(parent).length != 0 && keccak256(bytes(r.parent)) != keccak256(bytes(parent))) continue;
            uint256 proved = _provedIndex(r.name);
            address addr = proved != type(uint256).max ? _proved[proved].addr : _childOf(r, _at(_declared(r.parent)));
            if (!_describes(journal, r, addr)) {
                // A probe only needs to know the record is due; the run that writes it checks the code.
                if (_inProbe()) revert StepDue();
                _proveChild(r, journal);
                _recordChild(r, addr);
            } else if (proved == type(uint256).max) {
                _proveChild(r, journal);
            }
            if (bytes(parent).length != 0) _recordChildren(r.name);
        }
        _releaseMemory(mark);
    }

    /// @dev No commit of its own: the parent's build made it.
    function _recordChild(Role memory r, address addr) private {
        _recordCode(r.name, addr, r.artifact);
        _put(string.concat(".", r.name), vm.toString(addr));
    }

    /// @dev `r`'s address, from the address this recovery found for the role it descends from.
    function _foundAddress(Role memory r) private view returns (address) {
        if (r.kind != Kind.Child) return _proved[_provedIndex(r.name)].addr;
        return _childOf(r, _foundAddress(_declared(r.parent)));
    }

    /// @dev Whether this recovery found the role that `r` descends from. The children of a role journaled before
    ///      are `check`'s: proving that role here can write its journal before every check has passed.
    function _foundBy(Role memory r) private view returns (bool) {
        Role memory root = r;
        while (root.kind == Kind.Child) root = _declared(root.parent);
        return _provedIndex(root.name) != type(uint256).max;
    }

    function _own(Role memory r) private pure returns (bool) {
        return bytes(r.declaredBy).length == 0 || keccak256(bytes(r.declaredBy)) == keccak256(bytes(_unit()));
    }

    function _argsOf(Role memory r) private returns (bytes memory) {
        return r.computed ? r.argsFn() : r.fixedArgs;
    }

    function _create2Input(Role memory r) private view returns (bytes32 salt, address at) {
        Input memory input = _inputFile(_unit());
        salt = vm.parseBytes32(_decided(input, string.concat(r.key, ".salt")));
        at = _requiredAddress(input, string.concat(r.key, ".address"));
    }

    function _proven(Role memory r, address addr) private {
        if (!_own(r) || !_stepOpen) return;
        if (_provedIndex(r.name) == type(uint256).max) {
            _proved.push(Proved(r.name, addr, r.kind, block.chainid, _declarationOf(r)));
        }
    }

    function _provedIndex(string memory name) private view returns (uint256) {
        for (uint256 i; i < _proved.length; ++i) {
            if (keccak256(bytes(_proved[i].name)) == keccak256(bytes(name)) && _proved[i].chainId == block.chainid) {
                return i;
            }
        }
        return type(uint256).max;
    }

    /// @dev Ends a `check`: every role of `_roles()` must be one the step proved with `_deploy` or `_at`. Journals
    ///      each deployed role's receipt; a probe judges the step due while one is unrecorded, so the step runs
    ///      once to record it and is done by what it reads after.
    function _endCheck() internal returns (string memory) {
        require(_proved.length != 0, "the step proved no role: prove each role it ends with _at");
        string memory journal = _journal();
        Role[] memory declared = _roles();
        for (uint256 i; i < declared.length; ++i) {
            if (!_own(declared[i]) || declared[i].kind == Kind.Child) continue;
            require(
                _provedIndex(declared[i].name) != type(uint256).max,
                string.concat("the step did not prove ", declared[i].name)
            );
        }
        for (uint256 i; i < declared.length; ++i) {
            if (!_own(declared[i]) || declared[i].kind == Kind.Child) continue;
            Proved memory p = _proved[_provedIndex(declared[i].name)];
            if (p.kind == Kind.Extern) continue;
            _requireReceipt(journal, p.name, p.addr, p.kind == Kind.Create2);
        }
        _recordChildren("");
        return _done(false);
    }

    /// @dev Rebuilds a lost journal from forge's broadcast records: each CREATE role of `_roles()`, in order,
    ///      that the journal lacks and that the sender created from this build with its declared arguments.
    ///      A later role's `.args` read an earlier role's found address. A CREATE2 role needs no recovery: its
    ///      deploy step adopts it. Read-only: run it with `--sender` the deployer.
    function _recoverRoles(string calldata network) internal returns (string memory) {
        Role[] memory rs = _roles();
        require(
            rs.length != 0, string.concat(_unit(), " declares no roles in _roles(): a person must rebuild its journal")
        );
        string memory journal = _use(network);
        // Opened only so that `readCallers` names the sender. Nothing is sent.
        _startBroadcast();
        (address sender,) = _broadcaster();
        vm.stopBroadcast();
        require(sender != DEFAULT_SENDER, "pass --sender <deployer>: the sender of the lost deployments");
        string[2][] memory names = new string[2][](rs.length);
        Create[] memory found = new Create[](rs.length);
        for (uint256 i; i < rs.length; ++i) {
            Role memory r = rs[i];
            if (r.kind != Kind.Create || !_own(r)) continue;
            names[i] = [r.name, r.artifact];
            if (_has(journal, string.concat(".", r.name))) continue;
            // Before the search: several roles of one artifact are told apart by their arguments.
            bytes memory a = _argsOf(r);
            found[i] = _createToRecover(journal, r.name, r.artifact, sender, _initcodeHash(r.artifact, a));
            if (found[i].addr == address(0)) continue;
            _proved.push(Proved(r.name, found[i].addr, Kind.Create, block.chainid, _declarationOf(r)));
            _requireCurrent(found[i], r.artifact, a);
            _requireCreatedDeclared(r.name, found[i].addr, _alsoCreated(found[i].record, found[i].addr));
        }
        // Children's code is checked before anything is journaled, so that a refusal leaves no key behind. As for
        // the roles found, no `.ensure` runs: one may read a role whose proof writes.
        address[] memory children = new address[](rs.length);
        for (uint256 i; i < rs.length; ++i) {
            Role memory r = rs[i];
            if (r.kind != Kind.Child || !_own(r) || !_foundBy(r)) continue;
            address parent = _foundAddress(_declared(r.parent));
            children[i] = _childOf(r, parent);
            _requireChildCode(r, parent, children[i]);
        }
        _journalRecovered(journal, names, found);
        journal = _journal();
        for (uint256 i; i < rs.length; ++i) {
            if (children[i] != address(0) && !_describes(journal, rs[i], children[i])) {
                _recordChild(rs[i], children[i]);
            }
        }
        _onRecover(journal);
        return _done(false);
    }

    /// @dev Writes a unit's own journal keys after `_recoverRoles` journaled its roles.
    function _onRecover(string memory journal) internal virtual {}
}

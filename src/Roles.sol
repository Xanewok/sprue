// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Deployment} from "./Deployment.sol";
import {Input} from "./Journal.sol";

/// @dev How a role's address is made, which fixes how its reuse is proven.
enum Kind {
    Create,
    Create2,
    Extern
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

/// @dev Each builder edits the memory struct it is given and returns that same struct.
library RoleLib {
    /// @dev Constructor arguments fixed in the source.
    function args(Role memory r, bytes memory value) internal pure returns (Role memory) {
        if (r.computed) revert(_twice(r));
        r.fixedArgs = value;
        return r;
    }

    /// @dev Constructor arguments built when used, from the inputs and the roles already deployed.
    function args(Role memory r, function() internal returns (bytes memory) fn) internal pure returns (Role memory) {
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

/// @dev Guarantees: `_deploy` and `_at` return a role only once its journaled identity gives its address, its
///      code hash is the journaled one, its journaled arguments are the declared ones (another unit's role: those
///      its builder gives, else its journaled ones) and the creation sent them, and, for the unit's own role,
///      its `.ensure` passes.
abstract contract Roles is Deployment {
    struct Proved {
        string name;
        address addr;
        Kind kind;
        /// @dev A step may select several forks: a proof holds on its own chain only.
        uint256 chainId;
    }

    /// @dev Another unit's roles that `_at` proved in the open step, with the arguments proved.
    struct ProvedOther {
        string unitName;
        string name;
        bytes32 argsHash;
        uint256 chainId;
    }

    ProvedOther[] private _provedOther;

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
        delete _provedOther;
    }

    /// @dev Deploys `r`, or proves its reuse, and returns its address. A step that deploys several roles
    ///      calls it once for each, in order; in a probe the first role due ends the step.
    function _deploy(Role memory r) internal returns (address addr) {
        require(_own(r), string.concat(r.name, " is ", r.declaredBy, "'s role: read it with _at"));
        require(r.kind != Kind.Extern, string.concat(r.name, " is extern: read it with _at"));
        _requireDeclared(r);
        string memory journal = _journal();
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
    }

    /// @dev `r`'s address, proven, without a send. Another unit's role (`.unit(unitName)`) is proven as that
    ///      unit proves it, but for its `.ensure`, which is its unit's to run: see `_atOtherProved`.
    function _at(Role memory r) internal returns (address addr) {
        if (!_own(r)) return _atOtherProved(r);
        uint256 proved = _provedIndex(r.name);
        if (proved != type(uint256).max) return _proved[proved].addr;
        _requireDeclared(r);
        if (r.kind == Kind.Extern) {
            addr = _requiredAddress(_inputFile(_unit()), r.key);
            _requireCode(addr, r.name);
            require(addr.codehash == r.codeHash, string.concat(r.name, "'s code is not the code its role pins"));
            _enterCheck(r);
            r.ensureFn(addr, "");
        } else {
            string memory journal = _journal();
            bytes memory a = _argsOf(r);
            addr = _requireLandedCode(journal, r.name, r.kind == Kind.Create2);
            if (r.kind == Kind.Create) {
                _requireCreateIdentity(journal, r.name, a);
            } else {
                _requireCreate2Record(journal, r.name);
                _requireCreate2Args(_unit(), journal, r.name, r.artifact, a);
            }
            _enterCheck(r);
            r.ensureFn(addr, a);
        }
        _checking[keccak256(bytes(r.name))] = false;
        _proven(r, addr);
    }

    /// @dev Another unit's role by its journaled identity and code, readable in a view. It proves no
    ///      arguments: `_at` does, and so should a step that reads what the role's constructor fixed.
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
        addr = _addr(journal, key);
        _requireCode(addr, r.name);
        require(
            _has(journal, string.concat(key, "CodeHash"))
                && addr.codehash == vm.parseJsonBytes32(journal, string.concat(key, "CodeHash")),
            string.concat(r.name, "'s code differs from ", r.declaredBy, ".json")
        );
        if (r.kind == Kind.Create) _requireCreateRecord(r.declaredBy, journal, r.name, addr);
        else _requireCreate2Record(journal, r.name);
    }

    /// @dev `_atOther`, and for a CREATE or CREATE2 role its arguments: `r`'s builder gives them, run as its
    ///      unit (`_journal` and `_unitInput` read that unit's files), or, with none, the journaled ones. They
    ///      must be the journal's and what the creation sent (a CREATE role's transaction, a CREATE2 role's
    ///      initcode hash). What its unit configured after the deploy, its `.ensure` and its constructor's
    ///      children are for the step to read. A proof costs two RPC calls, once per step and chain.
    function _atOtherProved(Role memory r) private returns (address addr) {
        addr = _atOther(r);
        if (r.kind == Kind.Extern) return addr;
        string memory journal = _journalOf(r.declaredBy);
        bytes memory a;
        if (r.computed || r.fixedArgs.length != 0) {
            _asUnit = r.declaredBy;
            a = _argsOf(r);
            delete _asUnit;
        } else {
            _requireKey(r.declaredBy, journal, r.name, "Args");
            a = vm.parseJsonBytes(journal, string.concat(".", r.name, "Args"));
        }
        uint256 proved = _provedOtherIndex(r, keccak256(a));
        if (proved != type(uint256).max) return addr;
        if (r.kind == Kind.Create) _requireCreatedWith(r.declaredBy, journal, r.name, a);
        else _requireCreate2Args(r.declaredBy, journal, r.name, r.artifact, a);
        if (_stepOpen) _provedOther.push(ProvedOther(r.declaredBy, r.name, keccak256(a), block.chainid));
    }

    function _provedOtherIndex(Role memory r, bytes32 argsHash) private view returns (uint256) {
        for (uint256 i; i < _provedOther.length; ++i) {
            ProvedOther memory p = _provedOther[i];
            if (
                keccak256(bytes(p.unitName)) == keccak256(bytes(r.declaredBy))
                    && keccak256(bytes(p.name)) == keccak256(bytes(r.name)) && p.argsHash == argsHash
                    && p.chainId == block.chainid
            ) return i;
        }
        return type(uint256).max;
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
        Role[] memory declared = _roles();
        for (uint256 i; i < declared.length; ++i) {
            if (keccak256(bytes(declared[i].name)) == keccak256(bytes(r.name))) return;
        }
        revert(string.concat(r.name, " is not in ", _unit(), "'s _roles(): declare it there"));
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
        if (_provedIndex(r.name) == type(uint256).max) _proved.push(Proved(r.name, addr, r.kind, block.chainid));
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
            if (!_own(declared[i])) continue;
            require(
                _provedIndex(declared[i].name) != type(uint256).max,
                string.concat("the step did not prove ", declared[i].name)
            );
        }
        for (uint256 i; i < declared.length; ++i) {
            if (!_own(declared[i])) continue;
            Proved memory p = _proved[_provedIndex(declared[i].name)];
            if (p.kind == Kind.Extern) continue;
            _requireReceipt(journal, p.name, p.addr, p.kind == Kind.Create2);
        }
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
            _proved.push(Proved(r.name, found[i].addr, Kind.Create, block.chainid));
            _requireCurrent(found[i], r.artifact, a);
        }
        _journalRecovered(journal, names, found);
        _onRecover(journal);
        return _done(false);
    }

    /// @dev Writes a unit's own journal keys after `_recoverRoles` journaled its roles.
    function _onRecover(string memory journal) internal virtual {}
}

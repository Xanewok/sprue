// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {console} from "forge-std/Script.sol";

import {Deployment} from "./Deployment.sol";
import {Certificate, Input} from "./Journal.sol";

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
    string owner;
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
    function(address, bytes memory) internal auth;
}

using RoleLib for Role global;

/// @dev A role the unit's deployer creates with CREATE. Its address follows from the deployer and the nonce
///      the journal records.
function create(string memory name, string memory artifact) pure returns (Role memory r) {
    r.name = name;
    r.artifact = artifact;
    r.argsFn = _noArgs;
    r.auth = _noCheck;
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
    r.auth = _noCheck;
}

/// @dev Each builder edits the memory struct it is given and returns that same struct.
library RoleLib {
    /// @dev Constructor arguments fixed in the source.
    function args(Role memory r, bytes memory value) internal pure returns (Role memory) {
        r.fixedArgs = value;
        r.computed = false;
        return r;
    }

    /// @dev Constructor arguments built when used, from the inputs and the roles already deployed.
    function args(Role memory r, function() internal returns (bytes memory) fn) internal pure returns (Role memory) {
        r.argsFn = fn;
        r.computed = true;
        return r;
    }

    /// @dev Runs on the role each time it is proven, for state that later transactions change. It may read
    ///      other roles with `_at`.
    function check(Role memory r, function(address, bytes memory) internal fn) internal pure returns (Role memory) {
        r.auth = fn;
        return r;
    }

    /// @dev The role as another unit reads it: `owner`'s journal records it.
    function unit(Role memory r, string memory owner) internal pure returns (Role memory) {
        r.owner = owner;
        return r;
    }
}

function _noArgs() pure returns (bytes memory) {}

function _noCheck(address, bytes memory) pure {}

/// @dev The steps of a unit whose contracts are declared as roles.
///
///      Guarantees: `_deploy` and `_at` return a role only once its address follows from the identity its
///      journal records, its code hash is the recorded one, and, for the unit's own role, its recorded
///      constructor arguments are the declared ones and its `.check` passes.
///
///      Relies on: the journal's recorded arguments, which a hash ties to the chain but no step re-reads from
///      the creation transaction.
abstract contract Roles is Deployment {
    struct Proved {
        string name;
        address addr;
        Kind kind;
    }

    /// @dev This unit's roles that the step proved, for `_certificate()`. Cleared when the step ends.
    Proved[] private _proved;
    bool private _stepOpen;
    /// @dev Counts ended steps, so that `_thisRun` holds one step's addresses only.
    uint256 private _stepCount;
    /// @dev The address of each of this unit's roles that `_deploy` or `_at` proved in this step, or that
    ///      `recover` found. A dry run journals nothing, so a later role's `.args` read an earlier role of the
    ///      same step from here.
    mapping(bytes32 => address) private _thisRun;
    /// @dev Set while a role's `.check` runs, so that a `.check` that reads its own role refuses by name.
    mapping(bytes32 => bool) private _checking;

    /// @dev The unit's roles, in the order its certificate lists them and its `recover` journals them.
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

    function _list(Role memory a, Role memory b, Role memory c, Role memory d, Role memory e)
        internal
        pure
        returns (Role[] memory r)
    {
        r = new Role[](5);
        (r[0], r[1], r[2], r[3], r[4]) = (a, b, c, d, e);
    }

    function _list(Role memory a, Role memory b, Role memory c, Role memory d, Role memory e, Role memory f)
        internal
        pure
        returns (Role[] memory r)
    {
        r = new Role[](6);
        (r[0], r[1], r[2], r[3], r[4], r[5]) = (a, b, c, d, e, f);
    }

    /// @dev `_use(network)` before the step's body, and `_done()` after it unless the body ended the step
    ///      itself (`_certify(c)` does). An early `return` still reaches the tail.
    modifier step(string calldata network) {
        _use(network);
        _stepOpen = true;
        _;
        if (_stepOpen) _done();
    }

    function _stepEnded() internal virtual override {
        super._stepEnded();
        _stepOpen = false;
        ++_stepCount;
        delete _proved;
    }

    /// @dev Deploys `r`, or proves its reuse, and returns its address. A step that deploys several roles
    ///      calls it once for each, in order; in a probe the first role due ends the step.
    function _deploy(Role memory r) internal returns (address addr) {
        require(_own(r), string.concat(r.name, " is ", r.owner, "'s role: read it with _at"));
        require(r.kind != Kind.Extern, string.concat(r.name, " is extern: read it with _at"));
        _requireDeclared(r);
        string memory journal = _journal();
        bytes memory a = _argsOf(r);
        _warnIfOlder(journal, r);
        _enterCheck(r);
        if (r.kind == Kind.Create) {
            (addr,) = _deployIdentified(journal, r.name, r.artifact, a, r.auth);
        } else {
            (bytes32 salt, address at) = _create2Input(r);
            _deployRoleCreate2(journal, r.name, r.artifact, a, salt, at, r.auth);
            addr = at;
        }
        _checking[_runKey(r.name)] = false;
        _proven(r, addr);
    }

    /// @dev `r`'s address, proven, without a send. For another unit's role (`.unit(owner)`), its arguments
    ///      and `.check` are its owner's to prove, so only its identity and code are.
    function _at(Role memory r) internal returns (address addr) {
        bool own = _own(r);
        if (own) {
            addr = _thisRun[_runKey(r.name)];
            if (addr != address(0)) return addr;
        }
        if (own) _requireDeclared(r);
        if (r.kind == Kind.Extern) {
            addr = _requiredAddress(_inputFile(own ? _unit() : r.owner), r.key);
            _requireCode(addr, r.name);
            require(addr.codehash == r.codeHash, string.concat(r.name, "'s code is not the code its role pins"));
            if (!own) return addr;
            _enterCheck(r);
            r.auth(addr, "");
        } else if (!own) {
            return _atOther(r);
        } else {
            string memory journal = _journal();
            bytes memory a = _argsOf(r);
            addr = _requireRecordedCode(journal, r.name);
            _warnIfOlder(journal, r);
            if (r.kind == Kind.Create) _requireCreateIdentity(journal, r.name, a);
            else _requireCreate2Record(journal, r.name, a, true);
            _enterCheck(r);
            r.auth(addr, a);
        }
        _checking[_runKey(r.name)] = false;
        _proven(r, addr);
    }

    /// @dev Another unit's role as that unit's `check` certified it, for a role whose configuration after its
    ///      deploy matters: its certified address must be the one its journal's identity proves. The step
    ///      needs `.needs("<owner>.check")`. `_at` is the default, for what the role's code fixes.
    function _checked(Role memory r) internal view returns (address addr) {
        require(!_own(r), string.concat(r.name, " is this unit's role: prove it with _at"));
        addr = _checked(r.owner, r.name);
        if (r.kind == Kind.Extern) return addr;
        require(
            _atOther(r) == addr, string.concat(r.owner, ".json's check certified another ", r.name, " than it records")
        );
    }

    function _atOther(Role memory r) private view returns (address addr) {
        string memory record = _journalOf(r.owner);
        string memory key = string.concat(".", r.name);
        require(_has(record, key), string.concat(r.owner, ".json records no ", r.name));
        addr = _addr(record, key);
        _requireCode(addr, r.name);
        require(
            _has(record, string.concat(key, "CodeHash"))
                && addr.codehash == vm.parseJsonBytes32(record, string.concat(key, "CodeHash")),
            string.concat(r.name, "'s code differs from ", r.owner, ".json")
        );
        if (r.kind == Kind.Create) _requireCreateRecord(r.owner, record, r.name, addr);
        else _requireCreate2Record(record, r.name, "", false);
    }

    function _enterCheck(Role memory r) private {
        bytes32 key = _runKey(r.name);
        require(
            !_checking[key],
            string.concat(r.name, "'s .check reads ", r.name, " itself: use the address and arguments it is given")
        );
        _checking[key] = true;
    }

    /// @dev `recover` and the certificate take the roles from `_roles()`, so a role the unit uses must be there.
    function _requireDeclared(Role memory r) private view {
        Role[] memory declared = _roles();
        for (uint256 i; i < declared.length; ++i) {
            if (keccak256(bytes(declared[i].name)) == keccak256(bytes(r.name))) return;
        }
        revert(string.concat(r.name, " is not in ", _unit(), "'s _roles(): declare it there"));
    }

    function _own(Role memory r) private pure returns (bool) {
        return bytes(r.owner).length == 0 || keccak256(bytes(r.owner)) == keccak256(bytes(_unit()));
    }

    function _argsOf(Role memory r) private returns (bytes memory) {
        return r.computed ? r.argsFn() : r.fixedArgs;
    }

    function _runKey(string memory name) private view returns (bytes32) {
        return keccak256(abi.encode(_stepCount, block.chainid, name));
    }

    function _create2Input(Role memory r) private view returns (bytes32 salt, address at) {
        Input memory input = _inputFile(_unit());
        salt = vm.parseBytes32(_decided(input, string.concat(r.key, ".salt")));
        at = _requiredAddress(input, string.concat(r.key, ".address"));
    }

    /// @dev A warning, not a refusal: a source edit after a deployment must not orphan the role.
    function _warnIfOlder(string memory journal, Role memory r) private view {
        string memory key = string.concat(".", r.name, "CreationCodeHash");
        if (!_has(journal, key)) return;
        if (vm.parseJsonBytes32(journal, key) == keccak256(vm.getCode(string.concat(r.artifact, ".sol:", r.artifact))))
        {
            return;
        }
        console.log(string.concat("WARNING: ", r.name, "'s deployed code is older than this build of ", r.artifact));
    }

    function _proven(Role memory r, address addr) private {
        if (!_own(r)) return;
        _thisRun[_runKey(r.name)] = addr;
        if (_provedIndex(r.name) == type(uint256).max) _proved.push(Proved(r.name, addr, r.kind));
    }

    function _provedIndex(string memory name) private view returns (uint256) {
        for (uint256 i; i < _proved.length; ++i) {
            if (keccak256(bytes(_proved[i].name)) == keccak256(bytes(name))) return i;
        }
        return type(uint256).max;
    }

    /// @dev Certifies every role of `_roles()`, which the step must have proven, with `_certificate()`, and ends
    ///      the step.
    function _certify() internal returns (string memory) {
        return _certify(_certificate());
    }

    /// @dev The certificate of every role of `_roles()`, in that order, each with its code hash; a `with...`
    ///      adds facts before `_certify`. Refuses a declared role the step did not prove with `_deploy` or
    ///      `_at`. Journals each deployed role's receipt.
    function _certificate() internal returns (Certificate memory c) {
        require(_proved.length != 0, "the step proved no role: prove each role it certifies with _at");
        Proved[] memory order = new Proved[](_proved.length);
        uint256 n;
        Role[] memory declared = _roles();
        for (uint256 i; i < declared.length; ++i) {
            if (!_own(declared[i])) continue;
            uint256 at = _provedIndex(declared[i].name);
            require(at != type(uint256).max, string.concat("the step did not prove ", declared[i].name));
            order[n++] = _proved[at];
        }
        for (uint256 i; i < _proved.length; ++i) {
            bool listed;
            for (uint256 j; j < n && !listed; ++j) {
                listed = keccak256(bytes(order[j].name)) == keccak256(bytes(_proved[i].name));
            }
            if (!listed) order[n++] = _proved[i];
        }
        string memory journal = _journal();
        c = _certificate(order[0].name, order[0].addr);
        for (uint256 i; i < order.length; ++i) {
            if (order[i].kind == Kind.Create) _recordReceipt(journal, order[i].name, order[i].addr);
            else if (order[i].kind == Kind.Create2) _recordCreate2Receipt(journal, order[i].name, order[i].addr);
            if (i != 0) c.withCode(order[i].name, order[i].addr);
        }
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
            _thisRun[_runKey(r.name)] = found[i].addr;
            _requireCurrent(found[i], r.artifact, a);
        }
        _journalRecovered(journal, names, found);
        _onRecover(journal);
        return _done(false);
    }

    /// @dev Writes a unit's own journal keys after `_recoverRoles` journaled its roles.
    function _onRecover(string memory journal) internal virtual {}
}

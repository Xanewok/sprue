// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

struct Registration {
    address target;
    string script;
}

/// @dev What a unit exposes so that a graph can register it.
interface IUnitSteps {
    function steps() external view returns (Step[] memory);
}

/// @dev How a graph judges a step that has no `Due` view.
interface IProbe {
    /// @dev The step would send a transaction or change its unit's journal.
    error StepDue();
    /// @dev `probe`'s only outcome: whether the step returned, and its return or revert data.
    error Probed(bool returned, bytes result);

    /// @dev Runs `step`, a call of one of the unit's steps, as `sender` would send it, and reverts with
    ///      `Probed`, so that no EVM state the step changed remains. Cheatcode state, such as the clock,
    ///      the selected fork or a file written directly, does remain.
    function probe(bytes calldata step, address sender) external;

    /// @dev `IProbe.probe.selector`: read with a static call, so that asking runs nothing.
    function probes() external pure returns (bytes4);
}

enum StepKind {
    Empty,
    Call,
    Until
}

/// @dev A step as a unit declares it. A step with `fn` `check` and no `.due` is the certifier (see
///      `Graph._validateGraph`), so use that name for nothing else. A step with neither `.due` nor
///      `.doneByCheck`, of a unit that answers `IProbe.probe`, is judged by a probe. `onChain`, `readChains`, `isSlow`
///      and `dueSelector` stand for `on`, `reads`, `slow`, `prepared` and `due`: solc rejects a member that shares
///      a name with a library function attached to the struct.
struct Step {
    StepKind kind;
    string id;
    string fn;
    bytes4 selector;
    string[] deps;
    string sender;
    string gate;
    bytes4 gateSelector;
    bytes4 dueSelector;
    bool isSlow;
    bool testOnly;
    bool hasArg;
    uint8 arg;
    string onChain;
    string[] readChains;
    bool ownForks;
    bool byCheck;
    string preparedBy;
}

using StepLib for Step global;

/// @dev Each builder edits the memory struct it is given and returns that same struct. None copies.
library StepLib {
    function needs(Step memory s, string memory id) internal pure returns (Step memory) {
        string[] memory deps = new string[](s.deps.length + 1);
        for (uint256 i; i < s.deps.length; ++i) {
            deps[i] = s.deps[i];
        }
        deps[s.deps.length] = id;
        s.deps = deps;
        return s;
    }

    /// @dev The account that must send the step, as an `<input file>.<key>` reference.
    function by(Step memory s, string memory inputRef) internal pure returns (Step memory) {
        s.sender = inputRef;
        return s;
    }

    /// @dev The step's `.by` sender is an account no run signs as, such as a multisig: an attended run that
    ///      cannot sign as it writes the step's transactions to `<network>/prepared/<id>.json`, for the
    ///      sender to execute, and exits 4. `reason` is shown with the file. A run that can sign as the
    ///      sender sends as for any step. Done is still the step's own rule, so a rerun sees the effect.
    function prepared(Step memory s, string memory reason) internal pure returns (Step memory) {
        s.preparedBy = reason;
        return s;
    }

    /// @dev Adds forge's `--slow` to the step's command.
    function slow(Step memory s) internal pure returns (Step memory) {
        s.isSlow = true;
        return s;
    }

    /// @dev Marks the step test-only: it can be a target only on a test or local chain, and no
    ///      production node may depend on it.
    function forTests(Step memory s) internal pure returns (Step memory) {
        s.testOnly = true;
        return s;
    }

    /// @dev `sel` is the selector of the unit's function `<fn>Due`; `Graph._add` checks it.
    function due(Step memory s, bytes4 sel) internal pure returns (Step memory) {
        s.dueSelector = sel;
        return s;
    }

    /// @dev The step is not before the timestamp that the unit's view `fn` returns. `sel` is the
    ///      view's selector; `Graph._add` checks it. The date is judged on the clock of the chain
    ///      selected when the view returns, so on a step with `.on(chain)` the view must leave that
    ///      chain selected.
    function gateView(Step memory s, string memory fn, bytes4 sel) internal pure returns (Step memory) {
        s.gate = fn;
        s.gateSelector = sel;
        return s;
    }

    /// @dev The step is not before the timestamp at `inputRef`, an "<input file>.<key>". It is judged
    ///      on the default chain's clock, so `plan` refuses it on a step that sends on another chain;
    ///      use `gateView` there.
    function notBefore(Step memory s, string memory inputRef) internal pure returns (Step memory) {
        s.gate = inputRef;
        return s;
    }

    /// @dev The chain the step sends on, which is also the clock of its date. A chain is a name the
    ///      project resolves; empty is the project's default chain.
    function on(Step memory s, string memory chain) internal pure returns (Step memory) {
        s.onChain = chain;
        return s;
    }

    /// @dev The step's script reads `chain`. With `ownsForks`, `plan` refuses a network that lacks it.
    ///      May be called more than once. An empty name is the default chain.
    function reads(Step memory s, string memory chain) internal pure returns (Step memory) {
        string[] memory chains = new string[](s.readChains.length + 1);
        for (uint256 i; i < s.readChains.length; ++i) {
            chains[i] = s.readChains[i];
        }
        chains[s.readChains.length] = chain;
        s.readChains = chains;
        return s;
    }

    /// @dev Gives the step a second argument, so it is called as `fn(string,uint8)`.
    function withArg(Step memory s, uint8 n) internal pure returns (Step memory) {
        s.hasArg = true;
        s.arg = n;
        return s;
    }

    /// @dev The step's script creates its own forks, so its command passes no `--rpc-url`.
    function ownsForks(Step memory s) internal pure returns (Step memory) {
        s.ownForks = true;
        return s;
    }

    /// @dev The certificate of a later `check` of the step's unit marks it done, and no probe judges
    ///      it: for a step that cannot tell its own work is done. The step must stay safe to run again:
    ///      a change of the unit's input makes the certificate stale, and the step then runs again.
    function doneByCheck(Step memory s) internal pure returns (Step memory) {
        s.byCheck = true;
        return s;
    }
}

abstract contract Declares {
    /// @dev `fn` is the part of `id` after the last dot.
    function _step(string memory id, bytes4 sel) internal pure returns (Step memory) {
        bytes memory name = bytes(id);
        uint256 start;
        for (uint256 i; i < name.length; ++i) {
            if (name[i] == ".") start = i + 1;
        }
        bytes memory fn = new bytes(name.length - start);
        for (uint256 i; i < fn.length; ++i) {
            fn[i] = name[start + i];
        }
        return _step(id, string(fn), sel);
    }

    function _step(string memory id, string memory fn, bytes4 sel) internal pure returns (Step memory s) {
        s.kind = StepKind.Call;
        s.id = id;
        s.fn = fn;
        s.selector = sel;
    }

    /// @dev Typed forms: the compiler checks that `fn` and `due` exist and take the step's arguments,
    ///      and that `due` returns a bool. Pass `this.<fn>`; `steps()` is then `view`.
    function _step(string memory id, function(string memory) external returns (string memory) fn)
        internal
        pure
        returns (Step memory)
    {
        return _step(id, fn.selector);
    }

    /// @dev A step written with `Roles`' `step(network)` modifier returns nothing.
    function _step(string memory id, function(string memory) external fn) internal pure returns (Step memory) {
        return _step(id, fn.selector);
    }

    function _step(string memory id, string memory name, function(string memory, uint8) external fn, uint8 arg)
        internal
        pure
        returns (Step memory)
    {
        return _step(id, name, fn.selector).withArg(arg);
    }

    function _step(
        string memory id,
        function(string memory) external returns (string memory) fn,
        function(string memory) external returns (bool) due
    ) internal pure returns (Step memory) {
        return _step(id, fn.selector).due(due.selector);
    }

    /// @dev An indexed step: `fn` is named, as `id` need not end in it.
    function _step(
        string memory id,
        string memory name,
        function(string memory, uint8) external returns (string memory) fn,
        uint8 arg
    ) internal pure returns (Step memory) {
        return _step(id, name, fn.selector).withArg(arg);
    }

    function _step(
        string memory id,
        string memory name,
        function(string memory, uint8) external returns (string memory) fn,
        function(string memory, uint8) external returns (bool) due,
        uint8 arg
    ) internal pure returns (Step memory) {
        return _step(id, name, fn, arg).due(due.selector);
    }

    /// @dev A predicate node: it sends nothing, and `fn` is a view that returns whether the condition
    ///      holds.
    function _until(string memory id, string memory fn, bytes4 sel) internal pure returns (Step memory s) {
        s.kind = StepKind.Until;
        s.id = id;
        s.fn = fn;
        s.selector = sel;
    }

    function _until(string memory id, string memory fn, function(string memory) external returns (bool) predicate)
        internal
        pure
        returns (Step memory)
    {
        return _until(id, fn, predicate.selector);
    }
}

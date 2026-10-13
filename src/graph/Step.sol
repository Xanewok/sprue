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

enum StepKind {
    Empty,
    Call,
    Until
}

/// @dev A step as a unit declares it. `fn` is the name of the function the step calls. A step with
///      `fn` `check` and no `.due` is the certifier (see `Graph._validateGraph`), so do not use that
///      name for anything else.
///
///      `Graph._add` copies a step into a `Graph.Node` under the builders' names, with two
///      exceptions: `deps` (builder `needs`), and `step`/`until` (`fn` and `kind` here). A struct
///      member cannot share a name with a library function attached to the struct (solc: member not
///      unique), so `onChain`, `readChains`, `isSlow` and `dueSelector` stand for `on`, `reads`,
///      `slow` and `due`.
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

    /// @dev `sel` is the selector of the unit's view `<fn>Due`; `Graph._add` checks it.
    function due(Step memory s, bytes4 sel) internal pure returns (Step memory) {
        s.dueSelector = sel;
        return s;
    }

    /// @dev The step is not before the timestamp that the unit's view `fn` returns. `sel` is the
    ///      view's selector; `Graph._add` checks it.
    function gateView(Step memory s, string memory fn, bytes4 sel) internal pure returns (Step memory) {
        s.gate = fn;
        s.gateSelector = sel;
        return s;
    }

    /// @dev The step is not before the timestamp at `inputRef`, an "<input file>.<key>".
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

    /// @dev The step's script reads `chain`, through its `rpc` alias or its `<CHAIN>_RPC` variable.
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

    /// @dev A predicate node: it sends nothing, and `fn` is a view that returns whether the condition
    ///      holds.
    function _until(string memory id, string memory fn, bytes4 sel) internal pure returns (Step memory s) {
        s.kind = StepKind.Until;
        s.id = id;
        s.fn = fn;
        s.selector = sel;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Deployment} from "./Deployment.sol";

/// @dev The recovery engine of `Roles._recoverRoles`: the broadcast-record scan, the match by arguments,
///      the chain confirmation and the journal write. A unit creates it with `vm.deployCode` outside any
///      broadcast, so that no unit carries this code. It takes from the unit what the unit's hooks give,
///      and writes the unit's journal itself.
contract RecoverHelper is Deployment {
    struct Ctx {
        string unit;
        string deployments;
        string deployScript;
        string defaultChain;
        string selectedChain;
        bool fenced;
        bool rehearsal;
    }

    Ctx private _ctx;
    address private _sender;
    string[2][] private _roles;
    bytes[] private _found;

    function begin(string calldata network, Ctx calldata ctx, address sender, uint256 roles) external {
        _usedNetwork = network;
        _ctx = ctx;
        _sender = sender;
        for (uint256 i; i < roles; ++i) {
            _roles.push();
            _found.push();
        }
    }

    /// @dev The role `i`'s landed CREATE, as the chain shows it was made from this build with `args`.
    ///      Zero if the journal has none to recover. Revert data is the refusal itself.
    function find(uint256 i, string calldata name, string calldata artifact, bytes calldata args)
        external
        returns (address)
    {
        string memory journal = _journal();
        _roles[i] = [name, artifact];
        Create memory found = _createToRecover(journal, name, artifact, _sender, _initcodeHash(artifact, args));
        if (found.addr == address(0)) return address(0);
        _requireCurrent(found, artifact, args);
        _found[i] = abi.encode(found);
        return found.addr;
    }

    /// @dev Writes every role found, once every check passed, so that a refusal leaves no key behind.
    function commit() external {
        uint256 n = _found.length;
        string[2][] memory names = new string[2][](n);
        Create[] memory found = new Create[](n);
        for (uint256 i; i < n; ++i) {
            names[i] = _roles[i];
            if (_found[i].length != 0) found[i] = abi.decode(_found[i], (Create));
        }
        _journalRecovered(_journal(), names, found);
    }

    function _unit() internal view override returns (string memory) {
        return _ctx.unit;
    }

    function _deployments() internal view override returns (string memory) {
        return _ctx.deployments;
    }

    function _deployScript() internal view override returns (string memory) {
        return _ctx.deployScript;
    }

    function _graphScript() internal pure override returns (string memory) {
        return "";
    }

    function _defaultChain(string memory) internal view override returns (string memory) {
        return _ctx.defaultChain;
    }

    function _selectedChain() internal view override returns (string memory) {
        return _ctx.selectedChain;
    }

    function _fenced() internal view override returns (bool) {
        return _ctx.fenced;
    }

    function _rehearsal() internal view override returns (bool) {
        return _ctx.rehearsal;
    }
}

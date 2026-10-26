// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FileGraph} from "../src/FileGraph.sol";
import {Role, create} from "../src/Roles.sol";
import {Unit} from "../src/Unit.sol";
import {Step} from "../src/graph/Step.sol";
import {FixtureToken} from "./FixtureToken.sol";
import {FixtureVault} from "./FixtureVault.sol";

uint256 constant SUPPLY = 1000;
uint256 constant LIMIT = 7;

function TOKEN() pure returns (Role memory) {
    return create("token", "FixtureToken").unit("token").args(abi.encode(SUPPLY));
}

/// @dev The unit has no `Deploy*.s.sol` directory, which only a recovery command names.
abstract contract FixtureUnit is Unit {
    function _deployScript() internal pure override returns (string memory) {
        return "test/VaultGraph.sol";
    }
}

contract TokenUnit is FixtureUnit {
    function steps() external view returns (Step[] memory s) {
        s = new Step[](2);
        s[0] = _step("token.deploy", this.deploy);
        s[1] = _step("token.check", this.check).needs("token.deploy");
    }

    function deploy(string calldata network) external step(network) {
        _deploy(TOKEN());
    }

    function check(string calldata network) external step(network) {
        _at(TOKEN());
        _endCheck();
    }

    function _roles() internal pure override returns (Role[] memory) {
        return _list(TOKEN());
    }

    function _unit() internal pure override returns (string memory) {
        return "token";
    }
}

/// @dev The operator configures the vault, and the deployer funds it once `vault.openAt` has passed.
///      `approved` waits for a person outside the graph.
contract VaultUnit is FixtureUnit {
    function steps() external view returns (Step[] memory s) {
        s = new Step[](5);
        s[0] = _step("vault.deploy", this.deploy).needs("token.deploy");
        s[1] = _step("vault.configure", this.configure).needs("vault.deploy").by("vault.operator");
        s[2] = _step("vault.fund", this.fund).needs("vault.deploy").notBefore("vault.openAt");
        s[3] = _until("vault.approved", "approved", this.approved).needs("vault.fund");
        s[4] = _step("vault.check", this.check).needs("vault.configure").needs("vault.fund").needs("token.check");
    }

    function deploy(string calldata network) external step(network) {
        _deploy(vault());
    }

    function configure(string calldata network) external step(network) {
        FixtureVault v = FixtureVault(_at(vault()));
        _want(v.limit() == LIMIT, address(v), abi.encodeCall(FixtureVault.configure, (LIMIT)));
    }

    function fund(string calldata network) external step(network) {
        FixtureToken token = FixtureToken(_at(TOKEN()));
        address v = _at(vault());
        _want(token.balanceOf(v) != 0, address(token), abi.encodeCall(FixtureToken.transfer, (v, 1)));
    }

    function approved(string calldata network) external returns (bool) {
        _use(network);
        return FixtureVault(_at(vault())).approved();
    }

    function check(string calldata network) external step(network) {
        require(FixtureToken(_at(TOKEN())).balanceOf(_at(vault())) != 0, "the vault is not funded");
        _endCheck();
    }

    function vault() internal pure returns (Role memory) {
        return create("vault", "FixtureVault").args(_vaultArgs);
    }

    function _vaultArgs() internal returns (bytes memory) {
        return abi.encode(_at(TOKEN()), _requiredAddress(_unitInput(), "operator"));
    }

    function _roles() internal pure override returns (Role[] memory) {
        return _list(vault());
    }

    function _unit() internal pure override returns (string memory) {
        return "vault";
    }
}

contract VaultGraph is FileGraph {
    constructor() {
        _add(address(new TokenUnit()), "script/TokenUnit.s.sol:TokenUnit");
        _add(address(new VaultUnit()), "script/VaultUnit.s.sol:VaultUnit");
        _validateGraph();
    }
}

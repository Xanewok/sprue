// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Role, create} from "sprue/Roles.sol";
import {Recovers, Unit} from "sprue/Unit.sol";
import {Step} from "sprue/graph/Step.sol";
import {TOKEN} from "../token/DeployToken.s.sol";
import {Token} from "../token/Token.sol";

/// @dev The vault is funded once its date (`vault.input.json`'s `openAt`) has passed.
contract DeployVault is Unit, Recovers {
    function steps() external view returns (Step[] memory s) {
        s = new Step[](3);
        s[0] = _step("vault.deploy", this.deploy).needs("token.deploy");
        s[1] = _step("vault.fund", this.fund).needs("vault.deploy").notBefore("vault.openAt");
        s[2] = _step("vault.check", this.check).needs("vault.fund").needs("token.check");
    }

    function deploy(string calldata network) external step(network) {
        _deploy(vault());
    }

    function fund(string calldata network) external step(network) {
        Token token = Token(_at(TOKEN()));
        address v = _at(vault());
        _want(token.balanceOf(v) != 0, address(token), abi.encodeCall(Token.transfer, (v, 1)));
    }

    function check(string calldata network) external step(network) {
        require(Token(_at(TOKEN())).balanceOf(_at(vault())) != 0, "the vault is not funded");
        _endCheck();
    }

    function vault() internal pure returns (Role memory) {
        return create("vault", "Vault").args(_vaultArgs);
    }

    function _vaultArgs() internal returns (bytes memory) {
        return abi.encode(_at(TOKEN()));
    }

    function _roles() internal pure override returns (Role[] memory) {
        return _list(vault());
    }

    function _unit() internal pure override returns (string memory) {
        return "vault";
    }
}

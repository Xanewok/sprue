// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Unit} from "sprue/Unit.sol";
import {Step} from "sprue/graph/Step.sol";
import {Token} from "../token/Token.sol";
import {Vault} from "./Vault.sol";

/// @dev The vault is funded once its date (`vault.input.json`'s `openAt`) has passed.
contract DeployVault is Unit {
    function steps() external view returns (Step[] memory s) {
        s = new Step[](3);
        s[0] = _step("vault.deploy", this.deploy, this.deployDue).needs("token.check");
        s[1] = _step("vault.fund", this.fund, this.fundDue).needs("vault.deploy").notBefore("vault.openAt");
        s[2] = _step("vault.check", this.check).needs("vault.fund");
    }

    function deploy(string calldata network) external returns (string memory) {
        string memory journal = _use(network);
        (, bool sent) =
            _deployRole(journal, "vault", "Vault", abi.encode(_checked("token", "token")), _create, _authenticate);
        return _done(sent);
    }

    function deployDue(string calldata network) external returns (bool) {
        string memory journal = _use(network);
        bytes memory args = abi.encode(_checked("token", "token"));
        address recorded = _reuseForDue(journal, "vault", "Vault", args);
        if (recorded != address(0)) _authenticate(recorded, args);
        return recorded == address(0);
    }

    function fund(string calldata network) external returns (string memory) {
        string memory journal = _use(network);
        (address token, address vault, bool short) = _funding(journal);
        if (short) {
            _startBroadcast();
            require(Token(token).transfer(vault, 1), "the transfer failed");
            vm.stopBroadcast();
        }
        return _done(short);
    }

    function check(string calldata network) external returns (string memory) {
        string memory journal = _use(network);
        (, address vault, bool short) = _funding(journal);
        require(!short, "the vault is not funded");
        _recordReceipt(journal, "vault", vault);
        return _certifyRole(_beginChecked("vault", vault), "vault", vault);
    }

    function fundDue(string calldata network) external returns (bool) {
        (,, bool short) = _funding(_use(network));
        return short;
    }

    function _funding(string memory journal) private view returns (address token, address vault, bool short) {
        token = _checked("token", "token");
        vault = _requireRecordedCode(journal, "vault");
        _authenticate(vault, abi.encode(token));
        short = Token(token).balanceOf(vault) == 0;
    }

    function _create(bytes memory args) private returns (address) {
        return address(new Vault(abi.decode(args, (address))));
    }

    function _authenticate(address vault, bytes memory args) private view {
        require(Vault(vault).TOKEN() == abi.decode(args, (address)), "the vault's token is not token.json's");
    }

    function _unit() internal pure override returns (string memory) {
        return "vault";
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Unit} from "sprue/Unit.sol";
import {Step} from "sprue/graph/Step.sol";
import {Token} from "./Token.sol";

contract DeployToken is Unit {
    uint256 internal constant SUPPLY = 1000;

    function steps() external pure returns (Step[] memory s) {
        s = new Step[](2);
        s[0] = _step("token.deploy", DeployToken.deploy.selector);
        s[1] = _step("token.check", DeployToken.check.selector).needs("token.deploy");
    }

    function deploy(string calldata network) external returns (string memory) {
        string memory journal = _use(network);
        (, bool sent) = _deployRole(journal, "token", "Token", abi.encode(SUPPLY), _create, _authenticate);
        return _done(sent);
    }

    function check(string calldata network) external returns (string memory) {
        string memory journal = _use(network);
        address token = _requireRecordedCode(journal, "token");
        _authenticate(token, abi.encode(SUPPLY));
        _recordReceipt(journal, "token", token);
        return _certifyRole(_beginChecked("token", token), "token", token);
    }

    /// @dev Rebuilds a lost journal from forge's broadcast records.
    function recover(string calldata network) external returns (string memory) {
        _adopt(network);
        _recover(network, "token", "Token", abi.encode(SUPPLY));
        return _done(false);
    }

    function _create(bytes memory args) private returns (address) {
        return address(new Token(abi.decode(args, (uint256))));
    }

    function _authenticate(address token, bytes memory args) private view {
        require(Token(token).SUPPLY() == abi.decode(args, (uint256)), "the token's supply differs");
    }

    function _unit() internal pure override returns (string memory) {
        return "token";
    }
}

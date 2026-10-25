// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Unit} from "sprue/Unit.sol";
import {Step} from "sprue/graph/Step.sol";
import {Source} from "./Source.sol";

contract DeploySource is Unit {
    function steps() external view returns (Step[] memory s) {
        s = new Step[](2);
        s[0] = _step("source.deploy", this.deploy);
        s[1] = _step("source.check", this.check).needs("source.deploy");
    }

    function deploy(string calldata network) external returns (string memory) {
        string memory journal = _use(network);
        (, bool sent) = _deployRole(journal, "source", "Source", "", _create, _authenticate);
        return _done(sent);
    }

    function check(string calldata network) external returns (string memory) {
        string memory journal = _use(network);
        address source = _requireRecordedCode(journal, "source");
        return _certify(_certificate(journal, "source", source));
    }

    function _create(bytes memory) private returns (address) {
        return address(new Source());
    }

    function _authenticate(address, bytes memory) private view {}

    function _unit() internal pure override returns (string memory) {
        return "source";
    }
}

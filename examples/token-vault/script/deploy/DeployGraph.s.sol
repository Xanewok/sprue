// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FileGraph} from "sprue/FileGraph.sol";
import {DeployToken} from "./units/token/DeployToken.s.sol";
import {DeployVault} from "./units/vault/DeployVault.s.sol";

contract DeployGraph is FileGraph {
    constructor() {
        _add(address(new DeployToken()), "script/deploy/units/token/DeployToken.s.sol:DeployToken");
        _add(address(new DeployVault()), "script/deploy/units/vault/DeployVault.s.sol:DeployVault");
        _validateGraph();
    }
}

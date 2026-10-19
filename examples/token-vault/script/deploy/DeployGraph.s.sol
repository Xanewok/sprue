// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FileGraph} from "sprue/FileGraph.sol";

contract DeployGraph is FileGraph {
    constructor() {
        _add("script/deploy/units/token/DeployToken.s.sol:DeployToken");
        _add("script/deploy/units/vault/DeployVault.s.sol:DeployVault");
        _validateGraph();
    }
}

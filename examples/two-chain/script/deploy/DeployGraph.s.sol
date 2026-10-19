// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FileGraph} from "sprue/FileGraph.sol";

contract DeployGraph is FileGraph {
    constructor() {
        _add("script/deploy/units/source/DeploySource.s.sol:DeploySource");
        _add("script/deploy/units/receiver/DeployReceiver.s.sol:DeployReceiver");
        _validateGraph();
    }
}

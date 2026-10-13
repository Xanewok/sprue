// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FileGraph} from "sprue/FileGraph.sol";
import {DeploySource} from "./units/source/DeploySource.s.sol";
import {DeployReceiver} from "./units/receiver/DeployReceiver.s.sol";

contract DeployGraph is FileGraph {
    constructor() {
        _add(address(new DeploySource()), "script/deploy/units/source/DeploySource.s.sol:DeploySource");
        _add(address(new DeployReceiver()), "script/deploy/units/receiver/DeployReceiver.s.sol:DeployReceiver");
        _validateGraph();
    }
}

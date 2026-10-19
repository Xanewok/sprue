// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Unit} from "sprue/Unit.sol";
import {Step} from "sprue/graph/Step.sol";
import {Receiver} from "./Receiver.sol";

/// @dev The receiver contract already exists on its chain: `receiver.input.json` names it. The unit opens
///      its windows 0, 1, 2 in order, each at `openAt` plus a day per index on the receiver's clock.
contract DeployReceiver is Unit {
    function steps() external view returns (Step[] memory s) {
        s = new Step[](3);
        for (uint8 i; i < 3; ++i) {
            s[i] = _step(string.concat("receiver.notify.", vm.toString(i)), "notify", this.notify, this.notifyDue, i)
                .gateView("windowStart", DeployReceiver.windowStart.selector)
                .on("receiver")
                .reads("source")
                .ownsForks();
            s[i] =
                i == 0 ? s[i].needs("source.check") : s[i].needs(string.concat("receiver.notify.", vm.toString(i - 1)));
        }
    }

    function notify(string calldata network, uint8 window) external returns (string memory) {
        _adopt(network);
        _selectChain("source");
        address source = _checked("source", "source");
        Receiver receiver = _receiver();
        _startBroadcast();
        receiver.open(window, source);
        vm.stopBroadcast();
        return _done(true);
    }

    function notifyDue(string calldata network, uint8 window) external returns (bool) {
        _adopt(network);
        return _receiver().opened(window) == address(0);
    }

    /// @dev A gate view must leave the gate's chain (here the receiver's) selected: the graph compares
    ///      the date it returns with `block.timestamp` of whichever chain is selected when it returns.
    function windowStart(string calldata network, uint8 window) external returns (uint256) {
        _adopt(network);
        _selectChain("receiver");
        return _uint(_unitInput(), ".openAt") + uint256(window) * 1 days;
    }

    function _receiver() private returns (Receiver) {
        _selectChain("receiver");
        return Receiver(_requiredAddress(_unitInput(), "receiver"));
    }

    function _unit() internal pure override returns (string memory) {
        return "receiver";
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {ToyPayload} from "./ToyPayload.sol";
import {ToyUnit} from "./ToyUnit.sol";

/// @notice The nonce fence against a set model: after any history of CREATEs, burnt nonces, journals
///         and retirements, a role the journal lacks is sent exactly when no CREATE with code is both
///         unjournaled and unretired.
contract FenceModelTest is Test {
    uint256 private constant FENCED = 777;
    uint256 private constant FREE = 31337;
    uint256 private constant MAX_OPS = 12;

    address private ops = makeAddr("ops");
    ToyUnit private unit = new ToyUnit();
    string private network;
    string private dir;

    address[] private created;
    uint256[] private nonces;
    bool[] private journaled;
    bool[] private retired;

    function _network(string memory name, uint256 chain) private {
        vm.chainId(chain);
        // Fuzz runs may share the filesystem concurrently, so a run needs a directory of its own.
        network = string.concat(
            "fence-", name, "-", vm.toString(uint64(uint256(keccak256(abi.encode(vm.unixTime(), vm.randomUint())))))
        );
        dir = string.concat("cache/core-test/deployments/", network);
        vm.createDir(dir, true);
        unit.setTestSender(ops);
        vm.writeFile(
            string.concat(dir, "/network.json"), string.concat('{"chains": {"main": {"id": ', vm.toString(chain), "}}}")
        );
    }

    function _journal(uint256 i) private {
        string memory role = string.concat("r", vm.toString(i));
        vm.serializeAddress(role, role, created[i]);
        vm.serializeAddress(role, string.concat(role, "Deployer"), ops);
        vm.serializeUint(role, string.concat(role, "Nonce"), nonces[i]);
        vm.writeJson(
            vm.serializeBytes32(role, string.concat(role, "CodeHash"), created[i].codehash),
            string.concat(dir, "/", role, ".json")
        );
    }

    function _writeRetired() private {
        string memory list;
        for (uint256 i; i < created.length; ++i) {
            if (!retired[i]) continue;
            list = string.concat(list, bytes(list).length == 0 ? "" : ",", '"', vm.toString(created[i]), '"');
        }
        vm.writeFile(string.concat(dir, "/toy.json"), string.concat('{"retired": [', list, "]}"));
    }

    function _play(uint256 seed, uint8 length) private {
        for (uint256 k; k < length % (MAX_OPS + 1); ++k) {
            uint256 word = uint256(keccak256(abi.encode(seed, k)));
            uint256 op = word % 4;
            uint256 pick = created.length == 0 ? 0 : (word >> 8) % created.length;
            if (op == 0) {
                nonces.push(vm.getNonce(ops));
                vm.broadcast(ops);
                created.push(address(new ToyPayload(9)));
                journaled.push(false);
                retired.push(false);
            } else if (op == 1) {
                vm.setNonce(ops, vm.getNonce(ops) + 1);
            } else if (created.length != 0 && op == 2) {
                journaled[pick] = true;
                _journal(pick);
            } else if (created.length != 0) {
                retired[pick] = true;
                _writeRetired();
            }
        }
    }

    function _dangling() private view returns (bool) {
        for (uint256 i; i < created.length; ++i) {
            if (!journaled[i] && !retired[i]) return true;
        }
        return false;
    }

    function testFuzz_fence_refusesExactlyWhenACreateWithCodeIsUnaccounted(uint256 seed, uint8 length) public {
        _network("fenced", FENCED);
        _play(seed, length);

        (bool ok,) = address(unit).call(abi.encodeCall(ToyUnit.landed, (network, ops)));
        assertEq(ok, !_dangling(), "the fence and the model disagree");
        vm.removeDir(dir, true);
    }

    function testFuzz_fence_neverRefusesOnAFreeChain(uint256 seed, uint8 length) public {
        _network("free", FREE);
        _play(seed, length);

        assertEq(unit.landed(network, ops), address(0));
        vm.removeDir(dir, true);
    }
}

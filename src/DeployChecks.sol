// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {VmSafe} from "forge-std/Vm.sol";

VmSafe constant cheats = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @notice Reverts unless a recorded deployment with no code can be forgotten. It can once
///         `deployer`'s nonce is past `nonce`: a CREATE address is fixed by the deployer and the
///         nonce, so nothing can land at `at` afterwards. Before that the transaction may still be
///         pending.
function requireLost(address at, address deployer, uint256 nonce) view {
    require(at.code.length == 0, string.concat(cheats.toString(at), " has code"));
    require(
        cheats.computeCreateAddress(deployer, nonce) == at,
        string.concat(cheats.toString(at), " is not the recorded deployer's CREATE at the recorded nonce")
    );
    require(
        cheats.getNonce(deployer) > nonce,
        string.concat(
            "the deployment at nonce ",
            cheats.toString(nonce),
            " of ",
            cheats.toString(deployer),
            " may still be pending: wait for it, or replace that nonce, then rerun"
        )
    );
}

/// @dev Reverts unless the code at `at` is artifact `name`, read from `out/<name>.sol/<name>.json`.
///      It takes the artifact's runtime code, writes each immutable into the places the compiler
///      lists for it, and compares the result whole with the live code. `immutables` must be in
///      declaration order, which is the order of the compiler's AST ids within one file.
function requireCode(address at, string memory name, bytes32[] memory immutables) view {
    string memory id = string.concat(name, ".sol:", name);
    bytes memory code = cheats.getDeployedCode(id);
    string memory artifact = cheats.readFile(string.concat("out/", name, ".sol/", name, ".json"));
    string memory refs = ".deployedBytecode.immutableReferences";
    string[] memory ids = cheats.keyExistsJson(artifact, refs) ? cheats.parseJsonKeys(artifact, refs) : new string[](0);
    require(ids.length == immutables.length, string.concat(id, " has another number of immutables"));

    uint256[] memory order = sortedIds(ids);
    for (uint256 k; k < order.length; ++k) {
        string memory places = string.concat(refs, ".", cheats.toString(order[k]));
        for (uint256 j; cheats.keyExistsJson(artifact, string.concat(places, "[", cheats.toString(j), "]")); ++j) {
            string memory place = string.concat(places, "[", cheats.toString(j), "]");
            uint256 start = cheats.parseJsonUint(artifact, string.concat(place, ".start"));
            require(cheats.parseJsonUint(artifact, string.concat(place, ".length")) == 32, "an immutable is not a word");
            require(wordAt(code, start) == 0, "an immutable's place is not blank in the artifact");
            putWord(code, start, immutables[k]);
        }
    }
    require(
        at.code.length == code.length && keccak256(code) == at.codehash,
        string.concat(cheats.toString(at), " is not ", id)
    );
}

function word(address a) pure returns (bytes32) {
    return bytes32(uint256(uint160(a)));
}

function wordAt(bytes memory b, uint256 offset) pure returns (bytes32 value) {
    assembly ("memory-safe") {
        value := mload(add(add(b, 0x20), offset))
    }
}

function putWord(bytes memory b, uint256 offset, bytes32 value) pure {
    assembly ("memory-safe") {
        mstore(add(add(b, 0x20), offset), value)
    }
}

/// @dev Parses the decimal ids and sorts them ascending. The lists are short, so insertion sort.
function sortedIds(string[] memory ids) pure returns (uint256[] memory sorted) {
    sorted = new uint256[](ids.length);
    for (uint256 i; i < ids.length; ++i) {
        uint256 v = cheats.parseUint(ids[i]);
        uint256 j = i;
        for (; j > 0 && sorted[j - 1] > v; --j) {
            sorted[j] = sorted[j - 1];
        }
        sorted[j] = v;
    }
}

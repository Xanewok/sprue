// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {ToyUnit} from "./ToyUnit.sol";

contract CertifyUnit is ToyUnit {
    function certify(string calldata network, string calldata checked) external {
        _use(network);
        _certify(checked);
    }
}

/// @notice `_certify` rewrites the certificate unless it is equal to the recorded one up to the
///         values of `evmBlock`, `l1Block` and `l2Block`; the model is that rule written key by key.
contract CertifyIdentityTest is Test {
    uint256 private constant KEYS = 6;

    struct Cert {
        bool[KEYS] present;
        uint256[KEYS] value;
        bool[KEYS] text; // a JSON string rather than a number
    }

    // The first three are the block keys.
    function _key(uint256 i) private pure returns (string memory) {
        return ["evmBlock", "l1Block", "l2Block", "mainChainId", "toy", "toyCodeHash"][i];
    }

    function _json(Cert memory c) private pure returns (string memory out) {
        out = "{";
        bool first = true;
        for (uint256 i; i < KEYS; ++i) {
            if (!c.present[i]) continue;
            string memory v = vm.toString(c.value[i]);
            out = string.concat(out, first ? "" : ",", '"', _key(i), '":', c.text[i] ? string.concat('"', v, '"') : v);
            first = false;
        }
        return string.concat(out, "}");
    }

    function _first(uint256 seed) private pure returns (Cert memory c) {
        for (uint256 i; i < KEYS; ++i) {
            uint256 word = uint256(keccak256(abi.encode(seed, i)));
            c.present[i] = i == 3 || word % 2 == 0;
            c.value[i] = (word >> 8) % 3;
            c.text[i] = (word >> 16) % 4 == 0;
        }
    }

    /// @dev A rerun at later blocks, one changed key, or a pile of changes: equality is common in the
    ///      first two and must be told from a changed identity.
    function _second(Cert memory a, uint256 seed, uint256 mode, uint256 only) private pure returns (Cert memory c) {
        for (uint256 i; i < KEYS; ++i) {
            (c.present[i], c.value[i], c.text[i]) = (a.present[i], a.value[i], a.text[i]);
        }
        for (uint256 i; i < KEYS; ++i) {
            uint256 word = uint256(keccak256(abi.encode(seed, "second", i)));
            if (mode % 3 == 0 && i >= 3) continue;
            if (mode % 3 == 1 && i != only % KEYS) continue;
            if (mode % 3 == 2 && word % 2 == 0) continue;
            uint256 what = (word >> 8) % 3;
            if (what == 0) c.value[i] = (c.value[i] + 1 + (word >> 16) % 2) % 3;
            if (what == 1 && i != 3) c.present[i] = !c.present[i];
            if (what == 2) c.text[i] = !c.text[i];
        }
    }

    function _same(Cert memory a, Cert memory b) private pure returns (bool) {
        for (uint256 i; i < KEYS; ++i) {
            if (a.present[i] != b.present[i]) return false;
            if (!a.present[i] || i < 3) continue;
            if (a.value[i] != b.value[i] || a.text[i] != b.text[i]) return false;
        }
        return true;
    }

    function testFuzz_certify_rewritesUnlessEqualUpToTheBlockKeys(uint256 seed, uint8 mode, uint8 only) public {
        string memory net = string.concat(
            "certify-", vm.toString(uint64(uint256(keccak256(abi.encode(vm.unixTime(), vm.randomUint())))))
        );
        string memory dir = string.concat("cache/core-test/deployments/", net);
        vm.createDir(dir, true);
        vm.writeFile(
            string.concat(dir, "/network.json"),
            string.concat('{"chains": {"main": {"id": ', vm.toString(block.chainid), "}}}")
        );
        vm.writeFile(string.concat(dir, "/toy.json"), "{}");
        CertifyUnit unit = new CertifyUnit();

        Cert memory a = _first(seed);
        Cert memory b = _second(a, seed, mode, only);
        unit.certify(net, _json(a));
        unit.certify(net, _json(b));

        string memory written = vm.readFile(string.concat(dir, "/toy.json"));
        Cert memory expected = _same(a, b) ? a : b;
        assertEq(vm.parseJson(written, ".checked"), vm.parseJson(_json(expected)), "wrong certificate kept");
        vm.removeDir(dir, true);
    }
}

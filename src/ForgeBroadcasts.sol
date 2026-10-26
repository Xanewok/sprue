// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {Journal, slashed} from "./Journal.sol";

/// @dev A cheatcode that forge 1.8 provides and the forge-std this library builds against does not
///      declare.
interface VmRpcJson {
    function rpcJson(string calldata method, string calldata params) external returns (string memory);
}

/// @dev What a unit and `SprueEngine` share about forge's `broadcast/` records, which only the engine reads. They
///      are the evidence a lost journal is rebuilt from: `broadcast/<script>/<chain id>/<step>-latest.json`, the
///      timestamped records beside it, and multi-chain records under `broadcast/multi/`, whose runs
///      sit in `.deployments[]`. A transaction's hash in a record is only a candidate, because older
///      forge versions ordered `transactions[].hash` by the order the sends returned. The receipts
///      name the right one.
abstract contract ForgeBroadcasts is Journal {
    /// @dev The unit's script: a refusal's recovery command names it, and forge keeps the records of its runs
    ///      under `<records>/<its file name>/`.
    function _deployScript() internal view virtual returns (string memory);

    function _fenced() internal view virtual returns (bool);

    struct Create {
        /// @dev A factory call forge recorded as `CREATE2`: no nonce fixes its address.
        bool create2;
        address addr;
        address from;
        uint256 nonce;
        string path;
        string record;
        /// @dev The run's and the transaction's paths within `record`.
        string run;
        string key;
        /// @dev The current inputs' constructor arguments, set by `_requireCurrent`.
        bytes args;
    }

    function _endsWith(string memory s, string memory suffix) internal pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory end = bytes(suffix);
        if (b.length < end.length) return false;
        for (uint256 i; i < end.length; ++i) {
            if (b[b.length - end.length + i] != end[i]) return false;
        }
        return true;
    }

    /// @dev The input of the chain's transaction `hash`, whose receipt the chain showed. Virtual only
    ///      so a test with no RPC can supply it.
    function _sentInput(bytes32 hash) internal virtual returns (bytes memory) {
        string memory sent =
            VmRpcJson(address(vm)).rpcJson("eth_getTransactionByHash", string.concat('["', vm.toString(hash), '"]'));
        require(
            _has(sent, ".input"),
            string.concat(
                "the RPC shows the receipt of ",
                vm.toString(hash),
                " but not the transaction: if it lags behind the chain, run again once it shows it"
            )
        );
        return vm.parseJsonBytes(sent, ".input");
    }

    /// @dev The block in which `txHash` created `deployed` on the selected chain, or zero. A
    ///      candidate from another chain has no receipt here, or one the node refuses to serve.
    ///      Virtual only so a test with no RPC can confirm a receipt.
    function _createdIn(bytes32 txHash, address deployed, bool create2) internal virtual returns (uint256) {
        string memory hash = string.concat('["', vm.toString(txHash), '"]');
        try VmRpcJson(address(vm)).rpcJson("eth_getTransactionReceipt", hash) returns (string memory receipt) {
            if (!_has(receipt, ".status") || _uint(receipt, ".status") != 1) return 0;
            if (create2) return _factoryCreated(hash) == deployed ? _uint(receipt, ".blockNumber") : 0;
            // A call's receipt names no created address.
            try vm.parseJsonAddress(receipt, ".contractAddress") returns (address created) {
                return created == deployed ? _uint(receipt, ".blockNumber") : 0;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    /// @dev The address that the factory call `hash` (input: `salt ++ initcode`) created, else zero.
    ///      The receipt names no created address, and a broadcast record is a local, editable file.
    ///      So the address is computed from what the chain says was sent to the factory.
    function _factoryCreated(string memory hash) private returns (address) {
        string memory sent = VmRpcJson(address(vm)).rpcJson("eth_getTransactionByHash", hash);
        try vm.parseJsonAddress(sent, ".to") returns (address to) {
            if (to != CREATE2_FACTORY) return address(0);
        } catch {
            return address(0);
        }
        bytes memory input = vm.parseJsonBytes(sent, ".input");
        if (input.length < 32) return address(0);
        bytes32 salt;
        bytes32 initcodeHash;
        assembly ("memory-safe") {
            salt := mload(add(input, 0x20))
            initcodeHash := keccak256(add(input, 0x40), sub(mload(input), 0x20))
        }
        return vm.computeCreate2Address(salt, initcodeHash, CREATE2_FACTORY);
    }

    /// @dev The deployer that `network.json` pins with `deployer`, or zero when it pins none. Reverts
    ///      if the field is the zero address or forge's default sender.
    function _pinnedDeployer() internal view returns (address) {
        string memory network = _networkJson();
        if (!_has(network, ".deployer")) return address(0);
        address pinned = _addr(network, ".deployer");
        require(
            pinned != address(0) && pinned != address(uint160(uint256(keccak256("foundry default caller")))),
            "network.json's deployer is the zero or forge's default address: fix it, or remove the field"
        );
        return pinned;
    }

    /// @dev The hashes of `input` without its last `tail` bytes, and of those bytes.
    function _hashSplit(bytes memory input, uint256 tail) internal pure returns (bytes32 code, bytes32 rest) {
        // SAFETY: the caller checks `tail <= input.length`, so `cut` does not underflow and both ranges lie
        // within `input`.
        assembly ("memory-safe") {
            let start := add(input, 32)
            let cut := sub(mload(input), tail)
            code := keccak256(start, cut)
            rest := keccak256(add(start, cut), tail)
        }
    }

    /// @dev The broadcaster and its next nonce, read inside the broadcast that will use them.
    function _broadcaster() internal returns (address deployer, uint256 nonce) {
        (, deployer,) = vm.readCallers();
        nonce = vm.getNonce(deployer);
    }

    /// @dev Records the deployer and nonce, which fix the CREATE address, so that a rerun can tell a
    ///      lost broadcast from a pending one. Reverts if `deployed` is not that address.
    function _recordSender(string memory role, address deployed, address deployer, uint256 nonce) internal {
        require(vm.computeCreateAddress(deployer, nonce) == deployed, "a deployment is not at its sender's nonce");
        _put(string.concat(".", role, "Deployer"), vm.toString(deployer));
        _put(string.concat(".", role, "Nonce"), vm.toString(nonce));
    }

    function _initcodeHash(string memory name, bytes memory args) internal view returns (bytes32) {
        return keccak256(_initcode(name, args));
    }

    function _initcode(string memory name, bytes memory args) internal view returns (bytes memory) {
        return bytes.concat(vm.getCode(string.concat(name, ".sol:", name)), args);
    }

    function _recordBuild(string memory role, address deployed, string memory name) internal {
        if (_inProbe()) revert StepDue();
        string memory metadataPath = string.concat(_dir(), "/", name, ".metadata.json");
        vm.writeFile(
            metadataPath,
            vm.parseJsonString(vm.readFile(string.concat("out/", name, ".sol/", name, ".json")), ".rawMetadata")
        );
        _put(string.concat(".", role, "Commit"), '"pending"');
        _put(string.concat(".", role, "CodeHash"), vm.toString(deployed.codehash));
        _put(string.concat(".", role, "Metadata"), string.concat('"', metadataPath, '"'));
    }
}

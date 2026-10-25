// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {defaultChainIn} from "../src/Chains.sol";
import {Deployment} from "../src/Deployment.sol";
import {Certificate} from "../src/Journal.sol";
import {Declares} from "../src/graph/Step.sol";
import {ToyPayload} from "./ToyPayload.sol";

/// @dev The deployment layers without `Unit`, with test-specific overrides of what `Unit` takes from
///      `sprue.json`: a journals directory of its own, its own fenced chain and rehearsal rule.
abstract contract ToyJournal is Deployment, Declares {
    uint256 internal constant FENCED_CHAIN = 777;

    bool public simulating;

    bool public otherDeployerAllowed;

    function allowOtherDeployer() external {
        otherDeployerAllowed = true;
    }

    function envAllows() external view returns (bool) {
        return super._unexpectedDeployerAllowed();
    }

    function defaultVariables() external pure returns (string memory, string memory) {
        return (super._optInVariable(), super._dirtyVariable());
    }

    function _optInVariable() internal pure override returns (string memory) {
        return "CORE_TEST_UNEXPECTED_DEPLOYER";
    }

    function _unexpectedDeployerAllowed() internal view override returns (bool) {
        return otherDeployerAllowed;
    }

    function simulate() external {
        simulating = true;
    }

    function _deployments() internal pure override returns (string memory) {
        return "cache/core-test/deployments";
    }

    /// @dev A test-specific rule, whatever project it runs in: no `chains.default`.
    function _defaultChain(string memory network) internal view override returns (string memory) {
        string memory chain = defaultChainIn("{}", network);
        require(bytes(chain).length != 0, "toy network: not exactly one chain");
        return chain;
    }

    function _graphScript() internal pure override returns (string memory) {
        return "toy.s.sol";
    }

    function _deployScript() internal pure virtual override returns (string memory) {
        return "test/ToyUnit.sol";
    }

    function _fenced() internal view override returns (bool) {
        return block.chainid == FENCED_CHAIN;
    }

    /// @dev Every network journals under `forge test`, unless the test asks for a simulation.
    function _rehearsal() internal view override returns (bool) {
        return !simulating;
    }
}

/// @dev One role, `toy`, deployed through `_deployRole` and certified by `check`.
contract ToyUnit is ToyJournal {
    uint256 public tag = 1;
    uint256 public hooks;
    bool public journaledAtHook;
    mapping(bytes32 => bool) public confirmed;
    bytes internal sentInput;

    function setTag(uint256 tag_) external {
        tag = tag_;
    }

    function confirm(bytes32 hash) external {
        confirmed[hash] = true;
    }

    /// @dev What the chain shows the confirmed transaction sent.
    function send(bytes calldata input) external {
        sentInput = input;
    }

    function findCreationInput(string calldata network) external returns (bytes memory) {
        return _findCreationInput(_use(network), "toy");
    }

    function requireCreatedFrom(string calldata network) external {
        _requireCreatedFrom(_use(network), "toy", "ToyPayload", abi.encode(tag));
    }

    function requireCreatedWith(string calldata network) external {
        _requireCreatedWith(_use(network), "toy", abi.encode(tag));
    }

    function reuse(string calldata network) external returns (address) {
        return _reuse(_use(network), "toy", abi.encode(tag));
    }

    function requireCreatedWithArgs(string calldata network, bytes calldata args) external {
        _requireCreatedWith(_use(network), "toy", args);
    }

    function deployFromInitcode(string calldata network) external returns (string memory) {
        (, bool sent) = _deployRole(_use(network), "toy", "ToyPayload", abi.encode(tag), Proof.WithArgs);
        return _done(sent);
    }

    function deployWithArgs(string calldata network) external returns (string memory) {
        (, bool sent) = _deployRole(_use(network), "toy", "ToyPayload", abi.encode(tag), _create, Proof.WithArgs);
        return _done(sent);
    }

    function deployByCreation(string calldata network) external returns (string memory) {
        (, bool sent) = _deployRole(_use(network), "toy", "ToyPayload", abi.encode(tag), _create);
        return _done(sent);
    }

    function deploy(string calldata network) external returns (string memory) {
        string memory m = _use(network);
        (, bool sent) = _deployRole(m, "toy", "ToyPayload", abi.encode(tag), _create, _authenticate);
        return _done(sent);
    }

    function check(string calldata network) external returns (string memory) {
        string memory m = _use(network);
        address addr = _requireRecordedCode(m, "toy");
        _authenticate(addr, abi.encode(tag));
        _recordReceipt(m, "toy", addr);
        return _certifyRole(_beginChecked("toy", addr), "toy", addr);
    }

    /// @dev `check` through the builder, with a second role's address and code.
    function checkBuilt(string calldata network, address spare) external returns (string memory) {
        string memory m = _use(network);
        address addr = _requireRecordedCode(m, "toy");
        _authenticate(addr, abi.encode(tag));
        Certificate memory c = spare == address(1) ? _certificate("toy", addr) : _certificate(m, "toy", addr);
        if (spare == address(1)) spare = address(0);
        if (spare != address(0)) c = c.withCode("spare", spare).withUint("tag", tag);
        return _certify(c);
    }

    /// @dev `_recover` with the test sender, which `_recovering` cannot take: it asks forge for
    ///      its own, and a test has none but the default.
    function recover(string calldata network) external returns (string memory) {
        string memory m = _use(network);
        _startBroadcast();
        (address sender,) = _broadcaster();
        vm.stopBroadcast();
        string[2][] memory roles = new string[2][](1);
        roles[0] = ["toy", "ToyPayload"];
        Create[] memory found = new Create[](1);
        found[0] = _createToRecover(m, "toy", "ToyPayload", sender);
        _requireCurrent(found[0], "ToyPayload", abi.encode(tag));
        _journalRecovered(m, roles, found);
        return _done(false);
    }

    function recoverAsForge(string calldata network) external returns (string memory) {
        _recover(network, "toy", "ToyPayload", abi.encode(tag));
        return _done(false);
    }

    function landed(string calldata network, address sender) external returns (address) {
        return _reuseForSend(_use(network), "toy", "ToyPayload", abi.encode(tag), sender, vm.getNonce(sender));
    }

    function recordedRole(string calldata network) external returns (address) {
        return _reuseForDue(_use(network), "toy", "ToyPayload", abi.encode(tag));
    }

    function decided(string calldata json, string calldata key) external pure returns (string memory) {
        return _decided(json, key);
    }

    function inputUint(string calldata json, string calldata key, uint256 min, uint256 max)
        external
        pure
        returns (uint256)
    {
        return _inputUint(json, key, min, max);
    }

    function requiredAddress(string calldata json, string calldata key) external pure returns (address) {
        return _requiredAddress(json, key);
    }

    function useNetwork(string calldata network) external {
        _use(network);
    }

    function requireNoStray(string calldata network, address adopted) external {
        _requireNoStray(_use(network), "toy", "ToyPayload", adopted);
    }

    function checkedToy(string calldata network) external returns (address) {
        _use(network);
        return _checked("toy", "toy");
    }

    function checkedOptional(string calldata network, string memory role) external returns (bool, address) {
        _use(network);
        return _checkedOptional("toy", role);
    }

    /// @dev A check that finds no toy at `at`, nor a `spare` at `spare`, and records both absent.
    function checkAbsent(string calldata network, address at, address spare) external returns (string memory) {
        _use(network);
        string memory obj = _beginChecked("toy", at);
        _recordAbsent(obj, "toy", at);
        _certify(_recordAbsent(obj, "spare", spare));
        return _done(false);
    }

    function _createdIn(bytes32 hash, address, bool create2) internal view virtual override returns (uint256) {
        return confirmed[hash] && !create2 ? 5 : 0;
    }

    /// @dev Unless a test chose an input, the journal's intent was sent.
    function _sentInput(bytes32) internal view virtual override returns (bytes memory) {
        if (sentInput.length != 0) return sentInput;
        return bytes.concat(vm.getCode("ToyPayload.sol:ToyPayload"), vm.parseJsonBytes(_journal(), ".toyArgs"));
    }

    function _onDeployment(string memory journal, string memory role, bytes memory args) internal override {
        ++hooks;
        super._onDeployment(journal, role, args);
        journaledAtHook = vm.exists(_path()) && _has(vm.readFile(_path()), ".toyInitcodeHash");
    }

    function _create(bytes memory args) private returns (address) {
        return address(new ToyPayload(abi.decode(args, (uint256))));
    }

    function _authenticate(address addr, bytes memory args) private view {
        require(ToyPayload(addr).tag() == abi.decode(args, (uint256)), "the payload's tag differs from the input");
    }

    function _unit() internal pure override returns (string memory) {
        return "toy";
    }
}

/// @dev Reads a variable of its own, which only the test that sets it uses.
contract DirtyToyUnit is ToyUnit {
    function _dirtyVariable() internal pure override returns (string memory) {
        return "CORE_TEST_DIRTY_MARK";
    }
}

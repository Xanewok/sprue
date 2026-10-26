// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {FileGraph} from "../src/FileGraph.sol";
import {Registration, Step, Declares} from "../src/graph/Step.sol";
import {Graph} from "../src/graph/Graph.sol";
import {BuilderGraph, StepFunctions} from "./StepBuilders.t.sol";
import {ToyJournal} from "./ToyUnit.sol";
import {ToyPayload} from "./ToyPayload.sol";

/// @dev A unit whose step changes the selected chain between `_use` and the deployment.
contract MovedToyUnit is ToyJournal {
    function deployOn(string calldata network, uint256 chainId_) external {
        string memory m = _use(network);
        vm.chainId(chainId_);
        _deployIdentified(m, "toy", "ToyPayload", abi.encode(uint256(1)), _authenticate);
    }

    function _create(bytes memory args) private returns (address) {
        return address(new ToyPayload(abi.decode(args, (uint256))));
    }

    function _authenticate(address, bytes memory) private pure {}

    function _unit() internal pure override returns (string memory) {
        return "toy";
    }
}

/// @dev A unit that has selected a second chain, as `Unit._selectChain` records.
contract SelectedChainToyUnit is MovedToyUnit {
    function _selectedChain() internal pure override returns (string memory) {
        return "other";
    }
}

/// @dev A unit whose script compiles no `recover(string)`.
contract PlainToyUnit is ToyJournal {
    function hasRecoverStep() external view returns (bool) {
        return _hasRecoverStep();
    }

    function _deployScript() internal pure virtual override returns (string memory) {
        return "test/Guards.t.sol";
    }

    function _unit() internal pure override returns (string memory) {
        return "toy";
    }
}

/// @dev A unit whose script compiles `recover(string)`: `ToyUnit.sol` holds one.
contract RecoveringToyUnit is PlainToyUnit {
    function _deployScript() internal pure override returns (string memory) {
        return "test/ToyUnit.sol";
    }
}

/// @dev Deploys an artifact whose constructor returns other runtime code than the artifact's.
contract ImpostorToyUnit is ToyJournal {
    function deploy(string calldata network) external {
        string memory m = _use(network);
        _deployIdentified(m, "toy", "OtherRuntime", "", _authenticate);
    }

    function _authenticate(address, bytes memory) private pure {}

    function _unit() internal pure override returns (string memory) {
        return "toy";
    }
}

/// @dev A unit that opts out of the artifact comparison, as a constructor-returned runtime must.
contract UnshownCodeToyUnit is ImpostorToyUnit {
    function _requireBuild(address, string memory) internal view override {}
}

contract DoneFunctions {
    function deploy(string calldata) external {}
    function check(string calldata) external {}

    function deployDue(string calldata) external pure returns (bool) {
        return false;
    }

    function checkDue(string calldata) external pure returns (bool) {
        return false;
    }
}

/// @dev `deploy` and `check`, each done by its `Due` view.
contract DoneGraph is FileGraph, Declares {
    constructor() {
        Step[] memory s = new Step[](2);
        s[0] = _step("fixture.deploy", DoneFunctions.deploy.selector).due(DoneFunctions.deployDue.selector);
        s[1] = _step("fixture.check", DoneFunctions.check.selector)
            .due(DoneFunctions.checkDue.selector)
            .needs("fixture.deploy");
        address unit = address(new DoneFunctions());
        _units.push(unit);
        _add(Registration(unit, "toy.s.sol:Toy"), s);
        _validateGraph();
    }
}

contract DueFunctions {
    function deploy(string calldata) external {}
    function check(string calldata) external {}

    function deployDue(string calldata) external pure returns (bool) {
        return true;
    }

    function checkDue(string calldata) external pure returns (bool) {
        return true;
    }
}

contract DueGraph is FileGraph, Declares {
    constructor() {
        Step[] memory s = new Step[](2);
        s[0] = _step("fixture.deploy", DueFunctions.deploy.selector).due(DueFunctions.deployDue.selector);
        s[1] = _step("fixture.check", DueFunctions.check.selector)
            .due(DueFunctions.checkDue.selector)
            .needs("fixture.deploy");
        address unit = address(new DueFunctions());
        _units.push(unit);
        _add(Registration(unit, "toy.s.sol:Toy"), s);
        _validateGraph();
    }
}

contract GuardsTest is Test, Declares {
    string private constant DIR = "cache/core-test/deployments/";

    function _network(string memory name) private returns (string memory) {
        string memory dir = string.concat(DIR, name);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(dir, true);
        vm.chainId(31337);
        vm.writeFile(string.concat(dir, "/network.json"), '{"chains": {"main": {"id": 31337}}}');
        return name;
    }

    function test_deploy_stampsTheSelectedChain() public {
        SelectedChainToyUnit unit = new SelectedChainToyUnit();
        string memory net = _network("guards-selected");
        unit.deployOn(net, 5);
        string memory journal = vm.readFile(string.concat(DIR, net, "/toy.json"));
        assertEq(vm.parseJsonUint(journal, ".otherChainId"), 5);
        assertFalse(vm.keyExistsJson(journal, ".mainChainId"));
    }

    function test_deploy_stampsTheDefaultChainByDefault() public {
        MovedToyUnit unit = new MovedToyUnit();
        string memory net = _network("guards-default-stamp");
        unit.deployOn(net, 5);
        assertEq(vm.parseJsonUint(vm.readFile(string.concat(DIR, net, "/toy.json")), ".mainChainId"), 5);
    }

    function _fixture(string memory net, address journaled) private {
        string memory dir = string.concat("deployments/", net);
        vm.createDir(dir, true);
        vm.writeFile(string.concat(dir, "/network.json"), '{"chains":{"l2":{"id":31337}}}');
        vm.writeFile(string.concat(dir, "/fixture.json"), string.concat('{"token":"', vm.toString(journaled), '"}'));
    }

    function test_plan_warnsOfARoleWhoseCreationCodeThisBuildNoLongerMakes() public {
        DoneGraph g = new DoneGraph();
        string memory net = "rehearsal-guards-older";
        _fixture(net, address(new ToyPayload(1)));
        string memory journal = string.concat("deployments/", net, "/fixture.json");
        vm.writeJson('"deployments/x/ToyPayload.metadata.json"', journal, ".tokenMetadata");
        vm.writeJson(vm.toString(keccak256(vm.getCode("ToyPayload.sol:ToyPayload"))), journal, ".tokenCreationCodeHash");
        string memory done = "# chain l2 31337 local\n# done fixture.deploy\n# done fixture.check\n";
        assertEq(g.plan(net, "fixture.check"), done);

        vm.writeJson(vm.toString(bytes32(uint256(1))), journal, ".tokenCreationCodeHash");
        assertEq(g.plan(net, "fixture.check"), done, "a unit whose nodes are all done");
        string memory warning =
            "# warning fixture.json's token runs code that this build of ToyPayload does not make; it stays deployed, and no step replaces it\n";
        assertEq(
            g.plan(net, "fixture.check", true),
            string.concat("# chain l2 31337 local\n", warning, "# done fixture.deploy\n# done fixture.check\n")
        );
        vm.writeJson('"0x12"', journal, ".tokenCreationCodeHash");
        assertEq(g.plan(net, "fixture.check", true), done, "a malformed hash");
        vm.writeJson(vm.toString(bytes32(uint256(1))), journal, ".tokenCreationCodeHash");
        vm.writeJson("[7]", journal, ".tokenMetadata");
        assertEq(g.plan(net, "fixture.check", true), done, "a metadata path that is not a string");
        vm.writeJson('"deployments/x/Gone.metadata.json"', journal, ".tokenMetadata");
        assertTrue(
            vm.contains(
                g.plan(net, "fixture.check", true), "# warning fixture.json's token runs code that this build of Gone"
            )
        );
        vm.writeJson('"deployments/x/ToyPayload.metadata.json"', journal, ".tokenMetadata");
        vm.writeFile(
            string.concat("deployments/", net, "/network.json"), '{"chains":{"l2":{"id":31337,"rpc":"probe"}}}'
        );
        assertTrue(vm.contains(new DueGraph().plan(net, "fixture.check"), warning), "a unit with a node due");
        vm.writeFile(journal, vm.replace(vm.readFile(journal), '"tokenCreationCodeHash"', '"tokenCreationCode"'));
        assertFalse(
            vm.contains(g.plan(net, "fixture.check"), "# warning"), "a role without a recorded creation code hash"
        );
        vm.removeDir(string.concat("deployments/", net), true);
    }

    function test_deploy_refusesACreateThatIsNotTheArtifactAndRecordsNothing() public {
        ImpostorToyUnit unit = new ImpostorToyUnit();
        string memory net = _network("guards-impostor");
        (bool ok, bytes memory ret) = address(unit).call(abi.encodeCall(unit.deploy, (net)));
        assertFalse(ok);
        assertTrue(vm.contains(string(ret), " is not OtherRuntime.sol:OtherRuntime"), string(ret));
        assertFalse(vm.exists(string.concat(DIR, net, "/toy.json")));
    }

    function test_recoverStep_isReadFromTheScriptsCompiledAbi() public {
        assertFalse(new PlainToyUnit().hasRecoverStep());
        assertTrue(new RecoveringToyUnit().hasRecoverStep());
    }

    function test_add_refusesNamesOutsideThePlanLineGrammar() public {
        address target = address(new StepFunctions());
        BuilderGraph g = new BuilderGraph(Registration(target, "u.s.sol:U"), new Step[](0));
        Step[] memory s = new Step[](1);
        s[0] = _step("fixture.deploy", StepFunctions.deploy.selector);
        vm.expectRevert(abi.encodeWithSelector(Graph.UnsafeName.selector, "script/Deploy+.s.sol:Deploy"));
        g.add(Registration(target, "script/Deploy+.s.sol:Deploy"), s);
        string[3] memory bad = [":Toy", "script/Toy.s.sol:", "script/a:b/c.s.sol:Toy"];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Graph.UnsafeName.selector, bad[i]));
            g.add(Registration(target, bad[i]), s);
        }
        string[3] memory devices = ["con", "LPT1", "Nul"];
        for (uint256 i; i < devices.length; ++i) {
            s[0] = _step(string.concat(devices[i], ".deploy"), StepFunctions.deploy.selector);
            vm.expectRevert(abi.encodeWithSelector(Graph.UnsafeName.selector, devices[i]));
            g.add(Registration(target, "u.s.sol:U"), s);
        }
        s[0].fn = "deploy$";
        vm.expectRevert(abi.encodeWithSelector(Graph.UnsafeName.selector, "deploy$"));
        g.add(Registration(target, "u.s.sol:U"), s);
    }

    function test_requireBuild_overrideLetsAConstructorReturnedRuntimeBeJournaled() public {
        UnshownCodeToyUnit unit = new UnshownCodeToyUnit();
        string memory net = _network("guards-unshown");
        unit.deploy(net);
        assertTrue(vm.exists(string.concat(DIR, net, "/toy.json")));
    }
}

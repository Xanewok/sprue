// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {FileGraph} from "../src/FileGraph.sol";
import {Registration, Step, Declares} from "../src/graph/Step.sol";
import {Graph} from "../src/graph/Graph.sol";
import {BuilderGraph, StepFunctions} from "./StepBuilders.t.sol";
import {CertifyUnit} from "./CertifyIdentity.t.sol";
import {ToyJournal} from "./ToyUnit.sol";
import {ToyPayload} from "./ToyPayload.sol";

/// @dev A unit whose step changes the selected chain between `_use` and the deployment.
contract MovedToyUnit is ToyJournal {
    function deployOn(string calldata network, uint256 chainId_) external {
        string memory m = _use(network);
        vm.chainId(chainId_);
        _deployRole(m, "toy", "ToyPayload", abi.encode(uint256(1)), _create, _authenticate);
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

contract Impostor {
    uint256 public immutable tag = 1;
    uint256 public other = 2;
}

/// @dev Deploys another contract under ToyPayload's artifact name, as a same-named contract does.
contract ImpostorToyUnit is ToyJournal {
    function deploy(string calldata network) external {
        string memory m = _use(network);
        _deployRole(m, "toy", "ToyPayload", abi.encode(uint256(1)), _create, _authenticate);
    }

    function _create(bytes memory) private returns (address) {
        return address(new Impostor());
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

contract CertGraph is FileGraph, Declares {
    constructor() {
        Step[] memory s = new Step[](2);
        s[0] = _step("fixture.deploy", StepFunctions.deploy.selector);
        s[1] = _step("fixture.check", StepFunctions.check.selector).needs("fixture.deploy");
        address unit = address(new StepFunctions());
        _units.push(unit);
        _add(Registration(unit, "toy.s.sol:Toy"), s);
        _validateGraph();
    }
}

/// @dev The same graph with an input date on the certified node.
contract DatedCertGraph is FileGraph, Declares {
    constructor() {
        Step[] memory s = new Step[](2);
        s[0] = _step("fixture.deploy", StepFunctions.deploy.selector).notBefore("fixture.openAt");
        s[1] = _step("fixture.check", StepFunctions.check.selector).needs("fixture.deploy");
        address unit = address(new StepFunctions());
        _units.push(unit);
        _add(Registration(unit, "toy.s.sol:Toy"), s);
        _validateGraph();
    }
}

contract ArgCheckFunctions {
    function deploy(string calldata) external {}
    function check(string calldata, uint8) external {}
}

/// @dev Two sibling checks, each certifying `fixture.deploy`.
contract SiblingGraph is FileGraph, Declares {
    constructor() {
        Step[] memory s = new Step[](3);
        s[0] = _step("fixture.deploy", ArgCheckFunctions.deploy.selector);
        s[1] = _step("fixture.check.0", "check", ArgCheckFunctions.check.selector).withArg(0).needs("fixture.deploy");
        s[2] = _step("fixture.check.1", "check", ArgCheckFunctions.check.selector).withArg(1).needs("fixture.deploy");
        address unit = address(new ArgCheckFunctions());
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

    function test_deployRole_stampsTheSelectedChain() public {
        SelectedChainToyUnit unit = new SelectedChainToyUnit();
        string memory net = _network("guards-selected");
        unit.deployOn(net, 5);
        string memory journal = vm.readFile(string.concat(DIR, net, "/toy.json"));
        assertEq(vm.parseJsonUint(journal, ".otherChainId"), 5);
        assertFalse(vm.keyExistsJson(journal, ".mainChainId"));
    }

    function test_deployRole_stampsTheDefaultChainByDefault() public {
        MovedToyUnit unit = new MovedToyUnit();
        string memory net = _network("guards-default-stamp");
        unit.deployOn(net, 5);
        assertEq(vm.parseJsonUint(vm.readFile(string.concat(DIR, net, "/toy.json")), ".mainChainId"), 5);
    }

    function _certificate(string memory net, address addr, address journaled, bytes32 hash) private {
        string memory dir = string.concat("deployments/", net);
        vm.createDir(dir, true);
        vm.writeFile(string.concat(dir, "/network.json"), '{"chains":{"l2":{"id":31337}}}');
        vm.writeFile(
            string.concat(dir, "/fixture.json"),
            string.concat(
                '{"token":"',
                vm.toString(journaled),
                '","checked":{"evmBlock":1,"l2ChainId":31337,"token":"',
                vm.toString(addr),
                '","tokenCodeHash":"',
                vm.toString(hash),
                '"}}'
            )
        );
    }

    function test_certificate_isDoneBeforeItsNodesDateIsJudged() public {
        DatedCertGraph g = new DatedCertGraph();
        string memory net = "fork-test-guards-dated";
        address token = address(new ToyPayload(1));
        _certificate(net, token, token, token.codehash);
        vm.writeFile(string.concat("deployments/", net, "/fixture.input.json"), '{"openAt":"4102444800"}');
        assertEq(g.plan(net, "fixture.check"), "# chain l2 31337 local\n# done fixture.deploy\n# done fixture.check\n");
        vm.removeDir(string.concat("deployments/", net), true);
    }

    function test_certify_writesNothingOnADryRun() public {
        CertifyUnit unit = new CertifyUnit();
        string memory net = _network("guards-dry");
        unit.simulate();
        unit.certify(net, '{"evmBlock":1}');
        assertFalse(vm.exists(string.concat(DIR, net, "/toy.json")), "a dry run left a certificate");
    }

    function test_deployRole_refusesACreateThatIsNotTheArtifactAndRecordsNothing() public {
        ImpostorToyUnit unit = new ImpostorToyUnit();
        string memory net = _network("guards-impostor");
        (bool ok, bytes memory ret) = address(unit).call(abi.encodeCall(unit.deploy, (net)));
        assertFalse(ok);
        assertTrue(vm.contains(string(ret), " is not ToyPayload.sol:ToyPayload"), string(ret));
        assertFalse(vm.exists(string.concat(DIR, net, "/toy.json")));
    }

    function test_plan_refusesATargetThatExcludesTheCertifierOfANodeItNeeds_unlessTheNodeIsDone() public {
        CertGraph g = new CertGraph();
        string memory net = "fork-test-guards-target";
        vm.createDir(string.concat("deployments/", net), true);
        vm.writeFile(string.concat("deployments/", net, "/network.json"), '{"chains":{"l2":{"id":31337}}}');
        vm.expectRevert(bytes("cannot reach fixture.deploy: fixture.deploy is done only by fixture.check: target that"));
        g.plan(net, "fixture.deploy");

        address token = address(new ToyPayload(1));
        _certificate(net, token, token, token.codehash);
        assertEq(g.plan(net, "fixture.deploy"), "# chain l2 31337 local\n# done fixture.deploy\n");
        vm.removeDir(string.concat("deployments/", net), true);
    }

    function test_plan_acceptsEitherOfSeveralCertifiers() public {
        SiblingGraph g = new SiblingGraph();
        string memory net = "fork-test-guards-siblings";
        vm.createDir(string.concat("deployments/", net), true);
        vm.writeFile(string.concat("deployments/", net, "/network.json"), '{"chains":{"l2":{"id":31337}}}');
        assertTrue(vm.contains(g.plan(net, "fixture.check.0"), "forge script"));
        assertTrue(vm.contains(g.plan(net, "fixture.check.1"), "forge script"));
        vm.expectRevert(
            bytes("cannot reach fixture.deploy: fixture.deploy is done only by fixture.check.0: target that")
        );
        g.plan(net, "fixture.deploy");
        vm.removeDir(string.concat("deployments/", net), true);
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

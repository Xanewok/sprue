// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {chainRpc, defaultChainIn, validatedProject} from "../src/Chains.sol";

/// @dev Free functions revert in the test's own frame, which `expectRevert` cannot see.
contract ChainsCaller {
    function inOf(string calldata project, string calldata network) external view returns (string memory) {
        return defaultChainIn(project, network);
    }

    function validated(string calldata path) external view returns (string memory) {
        return validatedProject(path);
    }
}

contract CoreChainsTest is Test {
    ChainsCaller internal caller = new ChainsCaller();

    string private constant PROJECT = "cache/core-test/sprue-shape.json";
    string internal constant CHAINS =
        '{"chains":{"near":{"id":101,"rpc":"toy-alias"},"l2":{"id":102},"far":{"id":103}}}';

    /// @dev Chains of their own, so that no other suite's `<CHAIN>_RPC` is touched.
    function test_chainRpc_readsTheChainVariableWithoutAnAlias() public {
        string memory saved = vm.envOr("ENVONLY_RPC", string(""));
        vm.setEnv("ENVONLY_RPC", "http://envonly");
        assertEq(chainRpc(CHAINS, "envonly", false), "http://envonly", "no rpc: <CHAIN>_RPC");
        assertEq(chainRpc(CHAINS, "unset-chain", true), "", "optional and unset");
        vm.setEnv("ENVONLY_RPC", saved);
    }

    /// @dev `foundry.toml` declares the literal alias `probe`.
    function test_chainRpc_theAliasWinsOverTheChainVariable() public {
        string memory savedProbe = vm.envOr("PROBE_RPC", string(""));
        vm.setEnv("PROBE_RPC", "http://probe");
        assertEq(
            chainRpc('{"chains":{"probe":{"id":1,"rpc":"probe"}}}', "probe", false),
            "http://127.0.0.1:1",
            "the alias wins over a set <CHAIN>_RPC"
        );
        vm.setEnv("PROBE_RPC", savedProbe);
    }

    function test_defaultChain_isTheProjectsKeyElseTheOnlyOne() public {
        string memory withKey = '{"chains":{"default":"l2"}}';
        string memory without = '{"chains":{}}';
        assertEq(caller.inOf(withKey, CHAINS), "l2", "the key");
        assertEq(caller.inOf(withKey, '{"chains":{"l2":{"id":1},"a":{"id":2}}}'), "l2", "the key beats the count");
        assertEq(caller.inOf(without, '{"chains":{"main":{"id":1}}}'), "main", "the only chain");
        assertEq(caller.inOf(without, CHAINS), "", "several chains and no key: none");
        assertEq(caller.inOf(without, "{}"), "", "no chains: none");
        vm.expectRevert("network.json lacks sprue.json's default chain l2");
        caller.inOf(withKey, '{"chains":{"main":{"id":1}}}');
        vm.expectRevert("network.json lacks sprue.json's default chain l2");
        caller.inOf(withKey, "{}");
    }

    /// @dev Each file breaks one rule, so each check must refuse it alone.
    function test_project_isRefusedUnlessItIsExactlyTheShape() public {
        string memory paths = '{"graph":"g.s.sol","units":"u","deployments":"d","rehearsal":"d/fork-test"}';
        string memory chains = '"local":[31337],"test":[],"unrecordedDeploys":{}';
        string memory shape = "sprue.json is not exactly paths and chains";
        string memory keys = "sprue.json: unknown or missing key under paths or chains";
        string memory path = "sprue.json: paths must be nonempty strings using only A-Z a-z 0-9 _ . / -";
        string memory rehearsal = "sprue.json: paths.rehearsal is not <paths.deployments>/<lower-case name>";
        string memory list = "sprue.json: a chain list holds a non-number or 0";
        string memory exemption = "sprue.json: an exemption is not a decimal id";

        vm.createDir("cache/core-test", true);
        _project(paths, chains, "");
        _project(paths, string.concat(chains, ',"default":"l2"'), "");
        _project(paths, string.concat(chains, ',"default":"a-b"'), "sprue.json: chains.default is not a chain name");
        _project(paths, string.concat(chains, ',"default":5'), "sprue.json: chains.default is not a chain name");
        _project(paths, string.concat(chains, ',"extra":1'), keys);
        _project(paths, '"local":[],"test":[],"other":{}', keys);
        _project(paths, '"local":[],"test":[]', keys);
        _project(vm.replace(paths, '"graph":"g.s.sol",', '"graph":"g.s.sol","extra":"x",'), chains, keys);
        _project(vm.replace(paths, '"graph":"g.s.sol"', '"graph":""'), chains, path);
        _project(vm.replace(paths, '"graph":"g.s.sol"', '"graph":5'), chains, path);
        _project(vm.replace(paths, '"graph":"g.s.sol"', '"graph":"g(x).s.sol"'), chains, path);
        _project(vm.replace(paths, '"graph":"g.s.sol"', '"graph":"g$x.s.sol"'), chains, path);
        _project(vm.replace(paths, "d/fork-test", "other/fork-test"), chains, rehearsal);
        _project(vm.replace(paths, "d/fork-test", "d/Fork"), chains, rehearsal);
        _project(vm.replace(paths, "d/fork-test", "d/-fork"), chains, rehearsal);
        _project(paths, '"local":[0],"test":[],"unrecordedDeploys":{}', list);
        _project(paths, '"local":["31337"],"test":[],"unrecordedDeploys":{}', list);
        _project(paths, '"local":[],"test":[0],"unrecordedDeploys":{}', list);
        _project(paths, '"local":[],"test":[],"unrecordedDeploys":{"0x1":"r"}', exemption);
        _project(paths, '"local":[],"test":[],"unrecordedDeploys":{"01":"r"}', exemption);
        _project(
            paths,
            '"local":[],"test":[],"unrecordedDeploys":{"1":""}',
            "sprue.json: an exemption has no reason, or it starts with 0x"
        );
        vm.writeFile(PROJECT, '{"paths":{},"chains":{},"x":1}');
        vm.expectRevert(bytes(shape));
        caller.validated(PROJECT);
    }

    function _project(string memory paths, string memory chains, string memory refusal) private {
        vm.writeFile(PROJECT, string.concat('{"paths":', paths, ',"chains":{', chains, "}}"));
        if (bytes(refusal).length != 0) vm.expectRevert(bytes(refusal));
        caller.validated(PROJECT);
    }
}

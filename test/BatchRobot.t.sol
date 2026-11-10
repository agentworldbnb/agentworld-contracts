// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VrfEnv} from "./Fixture.sol";
import {AgentWorldArena, IArenaRobots, IArenaGear} from "../src/AgentWorldArena.sol";
import {AgentWorldGear, IRobots} from "../src/AgentWorldGear.sol";
import {AgentWorldRobots} from "../src/AgentWorldRobots.sol";
import {IAgentEligibility} from "../src/IAgentEligibility.sol";

contract BatchElig is IAgentEligibility {
    function agentKey(address, bytes calldata) external pure returns (bool, bytes32) { return (false, bytes32(0)); }
    function requiresProof() external pure returns (bool) { return false; }
}

/// One robot may sit in a batch only once. The next epoch is a new batch.
contract BatchRobotTest is VrfEnv {
    uint256 internal constant FEE = 0.01 ether;
    address internal constant USER = address(0xA11CE);
    AgentWorldRobots internal robots;
    AgentWorldArena internal arena;

    function setUp() public {
        _vrf();
        BatchElig elig = new BatchElig();
        robots = new AgentWorldRobots(0.001 ether, address(0x7771), elig, bytes32("prov"), "h");
        robots.setOpen(false, true);
        uint256[3] memory prices = [uint256(0.0001 ether), 0.0001 ether, 0.0001 ether];
        AgentWorldGear gear = new AgentWorldGear(address(0x7771), address(0x51), elig, rnd, IRobots(address(robots)), prices);
        arena = new AgentWorldArena(address(0x7771), address(0x52), elig, rnd, IArenaRobots(address(robots)), IArenaGear(address(gear)), FEE, 0);
        arena.setBracketRatio(0);
        rnd.setRegistrar(address(arena), true);
        vm.deal(USER, 2 ether);
        _req(address(arena).code.length <= 24_576, "arena runtime");
    }

    function _mint() internal returns (uint256 id) {
        uint256 before = robots.totalMinted();
        vm.prank(USER);
        robots.mint{value: 0.001 ether}(1, "");
        id = robots.totalMinted();
        _req(id == before + 1, "mint");
    }

    function _team(uint256 id) internal pure returns (uint256[3] memory t) { t[0] = id; }

    function test_duplicateRobotRevertsAndSiblingWorks() public {
        uint256 a = _mint();
        uint256 b = _mint();
        vm.prank(USER);
        arena.enter{value: FEE}(_team(a), false);
        vm.prank(USER);
        (bool again,) = address(arena).call(abi.encodeCall(AgentWorldArena.enter, (_team(a), false)));
        _req(!again, "same robot twice");
        vm.prank(USER);
        uint256 second = arena.enter{value: FEE}(_team(b), false);
        _req(second == 2 && robots.ownerOf(a) == USER && robots.ownerOf(b) == USER, "other robot");
    }

    function test_cancelFreesTheRobotInThisBatch() public {
        uint256 a = _mint();
        vm.prank(USER);
        uint256 id = arena.enter{value: FEE}(_team(a), false);
        vm.prank(USER);
        arena.cancel(id);
        vm.prank(USER);
        uint256 again = arena.enter{value: FEE}(_team(a), false);
        _req(again == 2, "re-enter after cancel");
    }

    function test_robotCanEnterTheNextBatch() public {
        uint256 a = _mint();
        vm.prank(USER);
        arena.enter{value: FEE}(_team(a), false);
        _seal(9);
        vm.prank(USER);
        uint256 nextId = arena.enter{value: FEE}(_team(a), false);
        _req(nextId == 2, "next batch");
    }
}

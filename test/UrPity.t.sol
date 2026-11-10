// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VrfEnv} from "./Fixture.sol";
import {AgentWorldGear, IRobots} from "../src/AgentWorldGear.sol";
import {AgentWorldRobots} from "../src/AgentWorldRobots.sol";
import {IAgentEligibility} from "../src/IAgentEligibility.sol";

contract PityElig is IAgentEligibility {
    function agentKey(address, bytes calldata) external pure returns (bool, bytes32) { return (false, bytes32(0)); }
    function requiresProof() external pure returns (bool) { return false; }
}

/// 199 controlled non-UR rolls, then purchase-order pity makes box 200 UR.
contract UrPityTest is VrfEnv {
    uint256 internal constant PRICE = 0.0001 ether;
    address internal constant USER = address(0xA11CE);
    AgentWorldGear internal gear;

    function setUp() public {
        _vrf();
        PityElig elig = new PityElig();
        AgentWorldRobots robots = new AgentWorldRobots(0.001 ether, address(0x7771), elig, bytes32("p"), "h");
        uint256[3] memory prices = [uint256(PRICE), PRICE, PRICE];
        gear = new AgentWorldGear(address(0x7771), address(0x51), elig, rnd, IRobots(address(robots)), prices);
        gear.setDailyBoxLimit(0, 250);
        rnd.setRegistrar(address(gear), true);
        vm.deal(USER, 1 ether);
        _req(address(gear).code.length <= 23_825, "gear runtime not grown");
    }

    function test_twoHundredthBoxIsPityUrInPurchaseOrder() public {
        for (uint256 n; n < 20; n++) {
            vm.prank(USER);
            gear.buyMany{value: PRICE * 10}(0, 10);
        }
        _req(gear.boxCount() == 200, "two hundred");
        uint256 epoch = rnd.currentEpoch();
        uint256 word;
        bool found;
        for (uint256 w = 1; w < 3000 && !found; w++) {
            bool bad;
            for (uint256 id = 1; id <= 200 && !bad; id++) {
                uint256 r = uint256(keccak256(abi.encode(w, epoch, address(gear), id)));
                if (uint16(r % 10_000) >= 9970) bad = true;
            }
            if (!bad) { word = w; found = true; }
        }
        _req(found, "controlled seed");
        _seal(word);
        bytes32 key = gear.accountKey(USER);
        for (uint256 i; i < 6; i++) gear.materialize(key, 32);
        gear.materialize(key, 7);
        _req(gear.pityCursor(key) == 199, "stops before 200");
        _req(gear.sinceUR(key) == 199, "counter");
        _req(!gear.rarityReady(200), "200 not finalized yet");
        for (uint256 id = 1; id <= 199; id++) _req(gear.rolledRarity(id) < 4, "no early ur");
        gear.materialize(key, 1);
        _req(gear.pityCursor(key) == 200, "purchase order");
        _req(gear.rolledRarity(200) == 4, "pity ur");
        _req(gear.sinceUR(key) == 0, "counter reset");
    }
}

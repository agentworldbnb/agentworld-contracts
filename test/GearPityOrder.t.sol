// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VrfEnv} from "./Fixture.sol";
import {AgentWorldGear, IRobots} from "../src/AgentWorldGear.sol";
import {IAgentEligibility} from "../src/IAgentEligibility.sol";

contract GearRobots {
    function ownerOf(uint256) external pure returns (address) { return address(1); }
    function mintSpecial(address, uint256, bool) external pure returns (uint256) { return 0; }
}

contract GearDeny is IAgentEligibility {
    function agentKey(address, bytes calldata) external pure returns (bool, bytes32) { return (false, bytes32(0)); }
    function requiresProof() external pure returns (bool) { return false; }
}

/// Pre-fix: open() applied pity from the counters at call time, so a buyer who could see every
/// roll would open the miss first and keep a natural high roll for afterwards.
/// Post-fix: pity is finalized in purchase order, at most 32 boxes per call, and open() only mints that result.
contract GearPityOrderTest is VrfEnv {
    AgentWorldGear internal gear;
    address internal user = address(0xC0FFEE);
    address internal constant TREASURY = address(0x71);
    address internal constant SINK = address(0x72);

    function setUp() public {
        _vrf();
        uint256[3] memory prices = [uint256(0.0001 ether), 0.0001 ether, 0.0001 ether];
        gear = new AgentWorldGear(TREASURY, SINK, new GearDeny(), rnd, IRobots(address(new GearRobots())), prices);
        rnd.setRegistrar(address(gear), true);
        _req(gear.odds(0, 2) == 9700, "odds");
        vm.deal(user, 10 ether);
    }

    function _natural(uint256 seed, uint256 id) internal view returns (uint8) {
        uint256 r = uint256(keccak256(abi.encode(seed, uint256(1), address(gear), id)));
        uint16 x = uint16(r % 10_000);
        for (uint8 i; i < 5; i++) if (x < gear.odds(0, i)) return i;
        return 4;
    }

    function _findSeed() internal view returns (uint256 seed) {
        for (seed = 1; seed < 5000; seed++) {
            bool ok = true;
            for (uint256 id = 1; id <= 40 && ok; id++) if (_natural(seed, id) >= 3) ok = false;
            if (ok) return seed;
        }
        revert("no seed");
    }

    function test_pityFollowsPurchaseOrderNotOpenOrder() public {
        _req(rnd.currentEpoch() == 1, "epoch");
        uint256 price = gear.priceWei(0);
        for (uint256 t; t < 4; t++) {
            vm.prank(user);
            gear.buyMany{value: price * 10}(0, 10);
        }
        bytes32 key = gear.accountKey(user);
        _req(gear.pityQueueLength(key) == 40, "queue");
        uint256 seed = _findSeed();
        _req(_natural(seed, 40) < 3, "box 40 would miss");
        _seal(seed);

        vm.prank(user);
        (bool openedEarly,) = address(gear).call(abi.encodeWithSignature("open(uint256)", uint256(40)));
        _req(!openedEarly, "open cannot walk the whole queue");
        _req(gear.pityCursor(key) == 0, "failed open rolls back");

        _req(gear.materialize(key, 32) == 32, "first chunk");
        _req(!gear.rarityReady(40), "40 still pending");
        vm.prank(user);
        uint256 g40 = gear.open(40); // finishes the remaining 8, then mints
        _req(gear.pityCursor(key) == 40, "caught up");
        _req(gear.rolledRarity(40) == 3, "40th box takes SSR pity");
        _req(g40 % 5 == 3, "minted the stored pity result");
        _req(gear.sinceUR(key) == 40 && gear.sinceSSR(key) == 0, "counters follow purchase order");

        uint8 n1 = _natural(seed, 1);
        vm.prank(user);
        uint256 g1 = gear.open(1);
        _req(g1 % 5 == n1 && n1 < 3, "first box stayed a miss");
        _req(gear.sinceUR(key) == 40 && gear.sinceSSR(key) == 0, "later open does not re-roll pity");
    }

    function test_materializeStepCap() public {
        (bool zero,) = address(gear).call(abi.encodeWithSignature("materialize(bytes32,uint256)", bytes32(0), uint256(0)));
        (bool over,) = address(gear).call(abi.encodeWithSignature("materialize(bytes32,uint256)", bytes32(0), uint256(33)));
        _req(!zero && !over, "step cap");
    }

    function test_earlierUnreadyBoxBlocksUntilGraceThenDropsOut() public {
        uint256 price = gear.priceWei(0);
        uint256 t0 = block.timestamp;
        vm.prank(user); uint256 b1 = gear.buy{value: price}(0);
        uint256 req1 = rnd.requestSeed();
        vm.warp(t0 + 31);
        vm.prank(user); uint256 b2 = gear.buy{value: price}(0);
        uint256 req2 = rnd.requestSeed();
        uint256[] memory words = new uint256[](1);
        words[0] = 9;
        vm.prank(address(coord));
        rnd.rawFulfillRandomWords(req2, words);
        _req(rnd.isReady(address(gear), b2) && !rnd.isReady(address(gear), b1), "only later seed");

        bytes32 key = gear.accountKey(user);
        vm.prank(user);
        (bool ok,) = address(gear).call(abi.encodeWithSignature("open(uint256)", b2));
        _req(!ok, "cannot skip b1");
        _req(gear.materialize(key, 8) == 0, "grace holds the cursor");
        _req(gear.sinceUR(key) == 0 && gear.sinceSSR(key) == 0, "no pity movement");

        vm.warp(t0 + gear.PITY_SEED_GRACE() + 1);
        _req(gear.materialize(key, 8) == 2, "skip b1 and finalize b2");
        _req(gear.pityExcluded(b1) && !gear.rarityReady(b1), "b1 left the queue");
        _req(gear.rarityReady(b2), "b2 fixed");
        vm.prank(user); gear.open(b2);
        uint16 su = gear.sinceUR(key);
        uint16 ss = gear.sinceSSR(key);

        words[0] = 11;
        vm.prank(address(coord));
        rnd.rawFulfillRandomWords(req1, words);
        vm.prank(user); gear.open(b1);
        _req(!gear.rarityReady(b1), "late b1 is not a pity box");
        _req(gear.sinceUR(key) == su && gear.sinceSSR(key) == ss, "late b1 does not move counters");
    }

    function test_shardBoxDoesNotEnterOrBlockPity() public {
        gear.setForge(address(this));
        bytes32 key = gear.accountKey(user);
        uint256 shard = gear.forgeRedeemBox(user, key, 0);
        uint256 price = gear.priceWei(0);
        vm.prank(user); uint256 bought = gear.buy{value: price}(0);
        _seal(4);
        _req(gear.pityQueueLength(key) == 1, "shard not queued");
        vm.prank(user); gear.open(bought);
        uint16 su = gear.sinceUR(key);
        uint16 ss = gear.sinceSSR(key);
        vm.prank(user); gear.open(shard);
        (,,, bool opened,) = gear.boxes(shard);
        _req(opened, "shard opened");
        _req(gear.sinceUR(key) == su && gear.sinceSSR(key) == ss, "shard did not move pity");
        _req(!gear.rarityReady(shard) && !gear.pityExcluded(shard), "shard has no pity record");
    }
}

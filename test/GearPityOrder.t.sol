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
/// Post-fix: pity stays 40 SSR / 200 UR, is finalized in purchase order, and a box with no
/// finalized result cannot be opened. A late seed is waited on and still consumes pity.
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

    function _at(uint256 seed, uint256 epoch, uint256 id) internal view returns (uint8) {
        uint256 r = uint256(keccak256(abi.encode(seed, epoch, address(gear), id)));
        uint16 x = uint16(r % 10_000);
        for (uint8 i; i < 5; i++) if (x < gear.odds(0, i)) return i;
        return 4;
    }

    /// First seed whose boxes fromId..toId all have natural rarity < below, in that epoch.
    function _find(uint256 epoch, uint256 fromId, uint256 toId, uint8 below) internal view returns (uint256 seed) {
        for (seed = 1; seed < 8000; seed++) {
            bool ok = true;
            for (uint256 id = fromId; id <= toId && ok; id++) if (_at(seed, epoch, id) >= below) ok = false;
            if (ok) return seed;
        }
        revert("no seed");
    }

    function _fulfill(uint256 req, uint256 word) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vm.prank(address(coord));
        rnd.rawFulfillRandomWords(req, words);
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
        uint256 seed = _find(1, 1, 40, 3);
        _req(_at(seed, 1, 40) < 3, "box 40 would miss");
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

        uint8 n1 = _at(seed, 1, 1);
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

    function test_delayedSeedWaitsAndStillTakesPity() public {
        uint256 price = gear.priceWei(0);
        for (uint256 t; t < 3; t++) {
            vm.prank(user);
            gear.buyMany{value: price * 10}(0, 10);
        }
        vm.prank(user);
        gear.buyMany{value: price * 9}(0, 9);
        uint256 s1 = _find(1, 1, 39, 3);
        uint256 req1 = rnd.requestSeed();
        vm.warp(block.timestamp + 31);
        vm.prank(user);
        uint256 b40 = gear.buy{value: price}(0);
        _req(b40 == 40, "cross-batch id");
        uint256 req2 = rnd.requestSeed();
        uint256 s2 = _find(2, 40, 40, 3);
        _fulfill(req2, s2);
        vm.warp(block.timestamp + 30 days);
        bytes32 key = gear.accountKey(user);
        _req(rnd.isReady(address(gear), b40) && !rnd.isReady(address(gear), 1), "later batch ready, earlier seed missing");
        _req(gear.materialize(key, 32) == 0, "time does not skip the missing seed");
        _req(gear.pityCursor(key) == 0 && gear.sinceUR(key) == 0 && gear.sinceSSR(key) == 0, "pity untouched");
        vm.prank(user);
        (bool opened,) = address(gear).call(abi.encodeWithSignature("open(uint256)", b40));
        _req(!opened, "ready box cannot open ahead of an earlier seed");
        uint256[] memory many = new uint256[](1);
        many[0] = b40;
        vm.prank(user);
        _req(gear.openMany(many) == 0, "openMany does not skip ahead");

        _fulfill(req1, s1);
        _req(gear.materialize(key, 32) == 32, "first 32");
        _req(gear.materialize(key, 32) == 7, "ready remainder");
        _req(gear.pityCursor(key) == 39, "cursor reaches the late box");
        _req(gear.sinceUR(key) == 39 && gear.sinceSSR(key) == 39, "earlier misses kept");
        vm.prank(user);
        uint256 g = gear.open(b40);
        _req(gear.rolledRarity(b40) == 3 && g % 5 == 3, "late box still receives SSR pity");
        _req(gear.sinceUR(key) == 40 && gear.sinceSSR(key) == 0, "counters continued in order");
        _req(gear.pityCursor(key) == 40, "queue finished");
    }

    function test_naturalUrResetsBeforeTheNextBox() public {
        uint256 price = gear.priceWei(0);
        vm.prank(user); gear.buy{value: price}(0);
        vm.prank(user); gear.buy{value: price}(0);
        uint256 seed = 1;
        for (; seed < 20000; seed++) {
            if (_at(seed, 1, 1) == 4 && _at(seed, 1, 2) < 3) break;
        }
        _req(seed < 20000, "ur seed");
        _seal(seed);
        bytes32 key = gear.accountKey(user);
        _req(gear.materialize(key, 8) == 2, "both");
        _req(gear.rolledRarity(1) == 4, "natural UR");
        _req(gear.rolledRarity(2) == _at(seed, 1, 2) && gear.rolledRarity(2) < 3, "next box is not pity");
        _req(gear.sinceUR(key) == 1 && gear.sinceSSR(key) == 1, "UR reset, then one miss");
    }

    function test_twoHundredthBoxTakesUrPity() public {
        gear.setDailyBoxLimit(0, 250);
        uint256 price = gear.priceWei(0);
        for (uint256 t; t < 20; t++) {
            vm.prank(user);
            gear.buyMany{value: price * 10}(0, 10);
        }
        uint256 seed = _find(1, 1, 200, 4);
        _seal(seed);
        bytes32 key = gear.accountKey(user);
        uint256 seen;
        while (seen < 200) {
            uint256 n = gear.materialize(key, 32);
            _req(n > 0 && n <= 32, "bounded chunk");
            seen += n;
        }
        _req(gear.rolledRarity(200) == 4, "200th is UR pity");
        _req(_at(seed, 1, 200) < 4, "not a natural UR");
        _req(gear.sinceUR(key) == 0 && gear.sinceSSR(key) == 0, "UR clears both counters");
        vm.prank(user);
        _req(gear.open(200) % 5 == 4, "minted UR");
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
        _req(!gear.rarityReady(shard), "shard has no pity record");
    }
}

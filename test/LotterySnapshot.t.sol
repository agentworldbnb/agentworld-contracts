// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VrfEnv} from "./Fixture.sol";
import {AgentWorldLottery, IArenaLottery} from "../src/AgentWorldLottery.sol";
import {AgentWorldArena, IArenaRobots, IArenaGear} from "../src/AgentWorldArena.sol";
import {AgentWorldRobots} from "../src/AgentWorldRobots.sol";
import {IAgentEligibility} from "../src/IAgentEligibility.sol";

contract MockArena {
    mapping(uint256 => uint256) public revenue_;
    mapping(uint256 => bytes32[]) internal keys;
    mapping(uint256 => mapping(bytes32 => address)) public walletOf;
    mapping(uint256 => bool) public frozen;

    function revenueOnDay(uint256 day) external view returns (uint256) { return revenue_[day]; }
    function eligibleCount(uint256 day) external view returns (uint256) { return keys[day].length; }
    function eligibleAt(uint256 day, uint256 i) external view returns (bytes32 key, address wallet) {
        key = keys[day][i]; wallet = walletOf[day][key];
    }
    function freezeDay(uint256 day) external { frozen[day] = true; }
    function add(uint256 day, address w, uint256 revenueAdd) external {
        require(!frozen[day], "frozen");
        bytes32 k = keccak256(abi.encode(w));
        keys[day].push(k);
        walletOf[day][k] = w;
        revenue_[day] += revenueAdd;
    }
    function forcePush(uint256 day, address w) external {
        bytes32 k = keccak256(abi.encode("force", w));
        keys[day].push(k);
        walletOf[day][k] = w;
    }
    function forceRevenue(uint256 day, uint256 v) external { revenue_[day] = v; }
}

contract FixedGearL {
    function gearPowerBps(uint256) external pure returns (uint256) { return 0; }
}

contract DenyEligL is IAgentEligibility {
    function agentKey(address, bytes calldata) external pure returns (bool, bytes32) { return (false, bytes32(0)); }
    function requiresProof() external pure returns (bool) { return false; }
}

/// Pre-fix: draw() read the live eligible list after the seed was public, and commit did not reserve the pot.
/// Post-fix: commit freezes the day and stores the count and pot. Later entries cannot win that draw.
contract LotterySnapshotTest is VrfEnv {
    MockArena internal arena;
    AgentWorldLottery internal lot;
    address internal a = address(0x1);
    address internal b = address(0x2);
    address internal c = address(0x3);
    address internal late = address(0x4);

    function setUp() public {
        _vrf();
        arena = new MockArena();
        lot = new AgentWorldLottery(IArenaLottery(address(arena)), rnd);
        rnd.setRegistrar(address(lot), true);
        vm.warp(10 days);
    }

    function test_snapshotIgnoresEntrantAddedAfterCommit() public {
        arena.add(1, a, 1 ether);
        vm.deal(address(lot), 1 ether);
        lot.commit(1);
        _req(lot.committedCount(1) == 1, "snap count");
        (bool added,) = address(arena).call(abi.encodeWithSignature("add(uint256,address,uint256)", uint256(1), b, uint256(1 ether)));
        _req(!added, "freeze rejects");
        arena.forcePush(1, late);
        arena.forcePush(1, c);
        _req(arena.eligibleCount(1) == 3, "live list grew");
        arena.forceRevenue(1, 1000 ether);
        _req(lot.potFor(1) == lot.committedPot(1), "pot stays snapshotted");
        _seal(99);
        (address[3] memory w, uint256[3] memory amt) = lot.draw(1);
        _req(w[0] == a && w[1] == address(0) && w[2] == address(0), "only the committed entrant");
        _req(amt[1] == 0 && amt[2] == 0, "no extra shares");
        _req(amt[0] == lot.committedPot(1) * 5000 / 10_000, "half of the reserved pot");
        _req(lot.reserved() == 0, "reserve released");
        _req(lot.freeBalance() == 1 ether - amt[0], "unpaid share is free again");
        uint256 bal = a.balance;
        vm.prank(a); lot.claim();
        _req(a.balance == bal + amt[0], "claim");
        _req(lot.owed() == 0, "owed");
        _req(address(lot).balance == dust, "conserved");
    }

    function test_zeroEligibleClosesWithoutReserving() public {
        lot.commit(3);
        _req(lot.status(3) == 2, "closed");
        _req(lot.reserved() == 0 && lot.committedPot(3) == 0, "nothing reserved");
        (bool added,) = address(arena).call(abi.encodeWithSignature("add(uint256,address,uint256)", uint256(3), a, uint256(1 ether)));
        _req(!added, "day stays shut");
        (bool drew,) = address(lot).call(abi.encodeWithSignature("draw(uint256)", uint256(3)));
        _req(!drew, "no draw");
    }

    function test_twoDaysCannotSpendTheSameBalance() public {
        lot.setCaps(0.05 ether, 0.08 ether);
        arena.add(1, a, 100 ether); arena.add(1, b, 0); arena.add(1, c, 0);
        address d1 = address(0x11); address d2 = address(0x12); address d3 = address(0x13);
        arena.add(2, d1, 100 ether); arena.add(2, d2, 0); arena.add(2, d3, 0);
        vm.deal(address(lot), 0.10 ether);
        lot.commit(1);
        lot.commit(2);
        _req(lot.committedPot(1) == 0.08 ether, "day1 takes the cap");
        _req(lot.committedPot(2) == 0.02 ether, "day2 gets the remainder");
        _req(lot.reserved() == 0.10 ether && lot.freeBalance() == 0, "fully reserved");
        _seal(5);
        lot.draw(1);
        lot.draw(2);
        _req(lot.reserved() == 0, "drawn");
        uint256 paid;
        address[3] memory w1 = lot.winnersOf(1);
        address[3] memory w2 = lot.winnersOf(2);
        paid = _claim(w1[0]) + _claim(w1[1]) + _claim(w1[2]) + _claim(w2[0]) + _claim(w2[1]) + _claim(w2[2]);
        _req(paid + address(lot).balance == 0.10 ether, "no mint and no loss");
        _req(lot.owed() == 0, "cleared");
    }

    function _claim(address w) internal returns (uint256 amt) {
        uint256 before = w.balance;
        vm.prank(w); amt = lot.claim();
        _req(w.balance == before + amt, "paid");
    }

    function test_capsAndDonationDoNotChangeCommittedPot() public {
        lot.setCaps(0.05 ether, 0.08 ether);
        arena.add(4, a, 0.2 ether); // 5% = 0.01 ether, under the ticket cap
        vm.deal(address(lot), 1 ether);
        lot.commit(4);
        _req(lot.committedPot(4) == 0.01 ether, "revenue binds");
        lot.setCaps(0.0001 ether, 0.0002 ether);
        vm.deal(address(lot), address(lot).balance + 5 ether);
        _req(lot.potFor(4) == 0.01 ether, "still the snapshot");
        _seal(8);
        (, uint256[3] memory amt) = lot.draw(4);
        _req(amt[0] == 0.005 ether, "50% of the committed 0.01");
        _req(amt[1] == 0 && amt[2] == 0, "one entrant");
    }

    function test_ticketCapAndMaxPotBoundaries() public {
        // Ticket cap binds: 3 * 0.000675 < 5% of revenue and < maxPot.
        arena.add(5, a, 10 ether); arena.add(5, b, 0); arena.add(5, c, 0);
        vm.deal(address(lot), 1 ether);
        uint256 ticketPot = 3 * lot.ticketCapWei();
        lot.commit(5);
        _req(lot.committedPot(5) == ticketPot, "ticket cap");

        // Max pot binds once the ticket cap is raised above it.
        lot.setCaps(0.03 ether, 0.04 ether);
        arena.add(6, address(0x21), 10 ether);
        arena.add(6, address(0x22), 0);
        arena.add(6, address(0x23), 0);
        lot.commit(6);
        _req(lot.committedPot(6) == 0.04 ether, "max pot");
    }
}

/// The real arena, not the mock: the 10th battle of an already-open day cannot join after commit,
/// and that battle can still be settled and paid.
contract RealArenaCutoffTest is VrfEnv {
    uint256 internal constant FEE = 0.01 ether;
    address internal constant TREASURY = address(0x7772);
    AgentWorldArena internal arena;
    AgentWorldRobots internal robots;
    AgentWorldLottery internal lot;
    address internal p1 = address(0xA71);
    address internal p2 = address(0xB72);
    uint256 internal id1;
    uint256 internal id2;

    function setUp() public {
        _vrf();
        DenyEligL elig = new DenyEligL();
        robots = new AgentWorldRobots(0.001 ether, TREASURY, elig, bytes32("prov"), "h");
        robots.setOpen(false, true);
        arena = new AgentWorldArena(TREASURY, address(0x779), elig, rnd, IArenaRobots(address(robots)), IArenaGear(address(new FixedGearL())), FEE, 0);
        arena.setBracketRatio(0);
        lot = new AgentWorldLottery(IArenaLottery(address(arena)), rnd);
        arena.setLottery(address(lot));
        rnd.setRegistrar(address(arena), true);
        rnd.setRegistrar(address(lot), true);
        vm.deal(p1, 2 ether);
        vm.deal(p2, 2 ether);
        vm.deal(address(this), 2 ether);
        arena.fundHouse{value: 1 ether}();
        vm.prank(p1); id1 = robots.mint{value: 0.001 ether}(1, "");
        vm.prank(p2); id2 = robots.mint{value: 0.001 ether}(1, "");
    }

    function _team(uint256 id) internal pure returns (uint256[3] memory t) { t[0] = id; }

    function test_tenthBattleAfterCommitDoesNotQualifyAndStillPays() public {
        for (uint256 i; i < 9; i++) {
            if (i != 0) vm.warp(block.timestamp + 31);
            vm.prank(p1); arena.enter{value: FEE}(_team(id1), false);
            vm.prank(p2); arena.enter{value: FEE}(_team(id2), false);
            uint256 ep = _seal(100 + i);
            arena.resolve(ep, 5);
            arena.settle(arena.matchCount());
        }
        (bool ok, bytes32 key) = arena.agentKeyOf(p1);
        _req(!ok, "wallet key");
        _req(arena.entriesOnDay(key, 0) == 9, "nine");
        _req(arena.eligibleCount(0) == 0, "not yet");
        _req(arena.revenueOnDay(0) == 18 * FEE, "nine pots of two fees");

        vm.warp(block.timestamp + 31);
        vm.prank(p1); uint256 eid = arena.enter{value: FEE}(_team(id1), true);
        vm.warp(2 days);
        lot.commit(0);
        _req(arena.dayFrozen(0), "frozen");
        _req(lot.status(0) == 2, "empty day closed");
        uint256 ep10 = _seal(777);
        arena.resolve(ep10, 5);
        _req(arena.entriesOnDay(key, 0) == 9, "tenth ignored");
        _req(arena.eligibleCount(0) == 0, "still empty");
        _req(arena.revenueOnDay(0) == 18 * FEE, "revenue frozen");

        uint256 mid = arena.matchOfEntry(eid);
        _req(mid != 0, "paired");
        arena.settle(mid);
        AgentWorldArena.Match memory m = arena.getMatch(mid);
        _req(m.state == 2 && m.prize != 0, "paid path");
        address winner = m.winner == 1 ? m.walletA : m.walletB;
        if (winner != address(0x40005E)) {
            vm.prank(winner); arena.claim();
        }
        _req(address(arena).balance == arena.houseBankroll() + arena.pending(p1) + arena.pending(p2), "no stuck prize");
    }
}

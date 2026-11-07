// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VrfEnv} from "./Fixture.sol";
import {AgentWorldArena, IArenaRobots, IArenaGear} from "../src/AgentWorldArena.sol";
import {AgentWorldRobots} from "../src/AgentWorldRobots.sol";
import {IAgentEligibility} from "../src/IAgentEligibility.sol";

/// Gear bonus is a fixed distinctive value so battleInputs shows whether it was kept.
contract FixedGear {
    function gearPowerBps(uint256) external pure returns (uint256) { return 12_345; }
}

contract DenyElig is IAgentEligibility {
    function agentKey(address, bytes calldata) external pure returns (bool, bytes32) { return (false, bytes32(0)); }
    function requiresProof() external pure returns (bool) { return false; }
}

/// Pre-fix: robots.ownerOf reverts after burn, and settle reverts with it, so the prize never reaches pending.
/// Post-fix: burn matches a transfer (character stays, gear bonus drops) and the prize is payable.
contract ArenaBurnSettleTest is VrfEnv {
    uint256 internal constant FEE = 0.01 ether;
    uint256 internal constant DEV = 0.006 ether;   // 30% of two fees
    uint256 internal constant PRIZE = 0.014 ether; // the rest
    address internal constant HOUSE = address(0x40005E);
    address internal constant TREASURY = address(0x7771);

    AgentWorldArena internal arena;
    AgentWorldRobots internal robots;
    address internal p1 = address(0xA11);
    address internal p2 = address(0xB22);
    address internal p3 = address(0xC33);
    uint256 internal id1;
    uint256 internal id2;
    uint256 internal id3;

    function setUp() public {
        _vrf();
        DenyElig elig = new DenyElig();
        robots = new AgentWorldRobots(0.001 ether, TREASURY, elig, bytes32("prov"), "h");
        robots.setOpen(false, true);
        arena = new AgentWorldArena(TREASURY, address(0x778), elig, rnd, IArenaRobots(address(robots)), IArenaGear(address(new FixedGear())), FEE, 0);
        arena.setBracketRatio(0);
        rnd.setRegistrar(address(arena), true);
        vm.deal(p1, 2 ether);
        vm.deal(p2, 2 ether);
        vm.deal(p3, 2 ether);
        vm.prank(p1); id1 = robots.mint{value: 0.001 ether}(1, "");
        vm.prank(p2); id2 = robots.mint{value: 0.001 ether}(1, "");
        vm.prank(p3); id3 = robots.mint{value: 0.001 ether}(1, "");
        _req(arena.feeOfBracket(0) == FEE, "fee");
    }

    function _team(uint256 id) internal pure returns (uint256[3] memory t) { t[0] = id; }

    function _sides(uint256 mid) internal view returns (uint256 p1Slot, uint256 p2Slot) {
        AgentWorldArena.Match memory m = arena.getMatch(mid);
        p1Slot = m.walletA == p1 ? 0 : 3;
        p2Slot = p1Slot == 0 ? 3 : 0;
    }

    function _pair(address a, uint256 ia, address b, uint256 ib, uint256 word) internal returns (uint256 mid, uint256 ep) {
        vm.prank(a); arena.enter{value: FEE}(_team(ia), false);
        vm.prank(b); arena.enter{value: FEE}(_team(ib), false);
        ep = _seal(word);
        arena.resolve(ep, 5);
        mid = arena.matchCount();
    }

    function _assertPaid(uint256 mid) internal {
        AgentWorldArena.Match memory m = arena.getMatch(mid);
        _req(m.state == 2, "state");
        _req(m.prize == PRIZE, "prize");
        address winner = m.winner == 1 ? m.walletA : m.walletB;
        uint256 before = winner.balance;
        vm.prank(winner);
        arena.claim();
        _req(winner.balance == before + PRIZE, "claim");
        _req(arena.pending(winner) == 0, "pending cleared");
    }

    function test_heldRobotKeepsGearAndSettles() public {
        uint256 tre0 = TREASURY.balance;
        (uint256 mid,) = _pair(p1, id1, p2, id2, 3);
        _req(TREASURY.balance == tre0 + DEV, "dev");
        (uint256[6] memory c, uint256[6] memory g) = arena.battleInputs(mid);
        _req(c[0] != 255 && c[3] != 255, "chars");
        _req((g[0] & 0xffffffff) == 12_345 && (g[3] & 0xffffffff) == 12_345, "gear kept");
        arena.settle(mid);
        _assertPaid(mid);
        _req(address(arena).balance == 0, "no stuck");
    }

    function test_transferStripsGearAndSettles() public {
        (uint256 mid,) = _pair(p1, id1, p2, id2, 4);
        vm.prank(p1); robots.transferFrom(p1, address(0xD00D), id1);
        (uint256 p1Slot, uint256 p2Slot) = _sides(mid);
        (uint256[6] memory c, uint256[6] memory g) = arena.battleInputs(mid);
        _req(c[p1Slot] == 10, "char stays");
        _req((g[p1Slot] & 0xffffffff) == 0, "gear off");
        _req((g[p2Slot] & 0xffffffff) == 12_345, "opponent gear stays");
        arena.settle(mid);
        _assertPaid(mid);
        _req(address(arena).balance == 0, "no stuck");
    }

    function test_burnStripsGearAndStillSettles() public {
        (uint256 mid,) = _pair(p1, id1, p2, id2, 5);
        vm.prank(p1); robots.burn(id1);
        (bool alive,) = address(robots).staticcall(abi.encodeWithSignature("ownerOf(uint256)", id1));
        _req(!alive, "ownerOf reverts"); // this is what used to revert settle
        (uint256 p1Slot, uint256 p2Slot) = _sides(mid);
        (uint256[6] memory c, uint256[6] memory g) = arena.battleInputs(mid);
        _req(c[p1Slot] == 10, "char stays after burn");
        _req((g[p1Slot] & 0xffffffff) == 0, "gear off after burn");
        _req((g[p2Slot] & 0xffffffff) == 12_345, "opponent gear stays");
        arena.settle(mid);
        _assertPaid(mid);
        _req(address(arena).balance == 0, "prize not stuck");
    }

    function test_settleOneThenBurnDoesNotFreezeTheOther() public {
        (uint256 first,) = _pair(p1, id1, p2, id2, 6);
        arena.settle(first);
        vm.warp(block.timestamp + 31);
        (uint256 second,) = _pair(p1, id1, p3, id3, 7);
        vm.prank(p1); robots.burn(id1);
        arena.settle(second);
        _assertPaid(first);
        _assertPaid(second);
        _req(address(arena).balance == 0, "both pots paid");
    }

    function test_houseBurnConservesBankroll() public {
        vm.deal(address(this), 2 ether);
        arena.fundHouse{value: 1 ether}();
        vm.prank(p1); arena.enter{value: FEE}(_team(id1), true);
        uint256 ep = _seal(8);
        uint256 cut = FEE * 3000 / 10_000;
        uint256 locked = FEE - cut;
        arena.resolve(ep, 5);
        _req(arena.houseBankroll() == 1 ether - locked, "locked");
        vm.prank(p1); robots.burn(id1);
        uint256 mid = arena.matchCount();
        arena.settle(mid);
        AgentWorldArena.Match memory m = arena.getMatch(mid);
        _req(m.prize == 2 * locked, "house prize");
        bool houseWon = (m.winner == 1 && m.walletA == HOUSE) || (m.winner == 2 && m.walletB == HOUSE);
        if (houseWon) {
            _req(arena.pending(p1) == 0, "player empty");
            _req(arena.houseBankroll() == 1 ether - locked + m.prize, "house paid");
        } else {
            _req(arena.pending(p1) == m.prize, "player paid");
            _req(arena.houseBankroll() == 1 ether - locked, "house stays");
        }
        _req(address(arena).balance == arena.houseBankroll() + arena.pending(p1), "conserved");
    }
}

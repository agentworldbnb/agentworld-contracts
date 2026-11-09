// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VrfEnv} from "./Fixture.sol";
import {AgentWorldArena, IArenaRobots, IArenaGear} from "../src/AgentWorldArena.sol";
import {AgentWorldGear, IRobots} from "../src/AgentWorldGear.sol";
import {AgentWorldLottery, IArenaLottery} from "../src/AgentWorldLottery.sol";
import {AgentWorldRobots} from "../src/AgentWorldRobots.sol";
import {IAgentEligibility} from "../src/IAgentEligibility.sol";

contract PathElig is IAgentEligibility {
    function agentKey(address, bytes calldata) external pure returns (bool, bytes32) { return (false, bytes32(0)); }
    function requiresProof() external pure returns (bool) { return false; }
}

/// Receives BNB and tries the same payment again. The nested call must fail.
contract Reenter {
    AgentWorldGear public gear;
    AgentWorldArena public arena;
    AgentWorldLottery public lot;
    uint256 public gearPrice;
    bool public gearNested;
    bool public arenaNested;
    bool public lotNested;
    bool public armGear;
    bool public armArena;
    bool public armLot;

    function setGear(AgentWorldGear g, uint256 price) external { gear = g; gearPrice = price; armGear = true; }
    function setArena(AgentWorldArena a) external { arena = a; armArena = true; }
    function setLot(AgentWorldLottery l) external { lot = l; armLot = true; }

    receive() external payable {
        if (armGear) {
            armGear = false;
            try gear.buy{value: gearPrice}(0) returns (uint256) { gearNested = true; } catch {}
        }
        if (armArena) {
            armArena = false;
            try arena.claim() returns (uint256) { arenaNested = true; } catch {}
        }
        if (armLot) {
            armLot = false;
            try lot.claim() returns (uint256) { lotNested = true; } catch {}
        }
    }

    function buy(uint8 tier) external payable { gear.buy{value: msg.value}(tier); }
    function enter(uint256 id, uint256 value) external {
        uint256[3] memory t; t[0] = id;
        arena.enter{value: value}(t, false);
    }
    function cancel(uint256 entryId) external { arena.cancel(entryId); }
    function takeArena() external { arena.claim(); }
    function takeLot() external { lot.claim(); }
}

contract TinyArena is IArenaLottery {
    function revenueOnDay(uint256) external pure returns (uint256) { return 1 ether; }
    function eligibleCount(uint256) external pure returns (uint256) { return 1; }
    function eligibleAt(uint256, uint256) external view returns (bytes32 key, address wallet) {
        return (keccak256("re"), walletOf);
    }
    function freezeDay(uint256) external {}
    address public walletOf;
    constructor(address w) { walletOf = w; }
}

/// Buy, wait, open out of order, equip, battle, claim, and reject a second payment.
contract LaunchPathTest is VrfEnv {
    uint256 internal constant FEE = 0.01 ether;
    uint256 internal constant PRICE = 0.0001 ether;
    address internal constant TREASURY = address(0x7771);

    AgentWorldRobots internal robots;
    AgentWorldGear internal gear;
    AgentWorldArena internal arena;
    AgentWorldLottery internal lot;
    Reenter internal atk;
    address internal user = address(0xA11CE);
    address internal other = address(0xB0B);
    uint256 internal robotUser;
    uint256 internal robotOther;
    uint256 internal robotAtk;

    function setUp() public {
        _vrf();
        PathElig elig = new PathElig();
        robots = new AgentWorldRobots(0.001 ether, TREASURY, elig, bytes32("prov"), "h");
        robots.setOpen(false, true);
        uint256[3] memory prices = [uint256(PRICE), PRICE, PRICE];
        gear = new AgentWorldGear(TREASURY, address(0x51), elig, rnd, IRobots(address(robots)), prices);
        arena = new AgentWorldArena(TREASURY, address(0x52), elig, rnd, IArenaRobots(address(robots)), IArenaGear(address(gear)), FEE, 0);
        arena.setBracketRatio(0);
        lot = new AgentWorldLottery(IArenaLottery(address(arena)), rnd);
        arena.setLottery(address(lot));
        gear.setArena(address(arena));
        rnd.setRegistrar(address(gear), true);
        rnd.setRegistrar(address(arena), true);
        rnd.setRegistrar(address(lot), true);
        atk = new Reenter();
        vm.deal(user, 5 ether);
        vm.deal(other, 5 ether);
        vm.deal(address(atk), 5 ether);
        robotUser = _mint(user);
        robotOther = _mint(other);
        robotAtk = _mint(address(atk));
    }

    function _mint(address w) internal returns (uint256 id) {
        uint256 before = robots.totalMinted();
        vm.prank(w);
        robots.mint{value: 0.001 ether}(1, "");
        id = robots.totalMinted();
        _req(id == before + 1 && robots.ownerOf(id) == w, "mint");
    }

    function _team(uint256 id) internal pure returns (uint256[3] memory t) { t[0] = id; }

    function _cons(string memory m) internal view {
        _req(address(arena).balance == arena.houseBankroll() + arena.pending(user) + arena.pending(other) + arena.pending(address(atk)), m);
        _req(address(lot).balance == lot.owed() + lot.reserved() + lot.freeBalance(), "lottery identity");
    }

    function test_deployedRuntimeFitsEip170() public view {
        _req(address(gear).code.length <= 24_576, "gear runtime");
        _req(address(arena).code.length <= 24_576, "arena runtime");
        _req(address(robots).code.length <= 24_576, "robots runtime");
        _req(address(lot).code.length <= 24_576, "lottery runtime");
    }

    function test_feeLadderStopsAtUint16() public {
        _req(type(uint16).max < 100_000, "100000 cannot be stored");
        uint16[6] memory top = [uint16(10_000), 15_000, 20_000, 30_000, 40_000, 65_535];
        arena.setFeeLadder(top, 4);
        _req(arena.feeLadderBps(5) == 65_535, "ceiling stored");
        uint16[6] memory down = [uint16(10_000), 10_000, 10_000, 10_000, 20_000, 15_000];
        (bool ok,) = address(arena).call(abi.encodeCall(AgentWorldArena.setFeeLadder, (down, 4)));
        _req(!ok, "decreasing ladder");
        _req(arena.feeOfBracket(20) == FEE * 65_535 / 10_000, "top band uses 65535");
    }

    function test_buyWaitsThenOpensInPurchaseOrderAndEquips() public {
        vm.prank(user);
        uint256 first = gear.buy{value: PRICE}(0);
        vm.prank(user);
        uint256 second = gear.buy{value: PRICE}(0);
        _req(first == 1 && second == 2, "purchase order");
        vm.prank(user);
        (bool early,) = address(gear).call(abi.encodeCall(AgentWorldGear.open, (second)));
        _req(!early, "no seed yet");
        _seal(11);
        vm.prank(user);
        uint256 g2 = gear.open(second);
        vm.prank(user);
        uint256 g1 = gear.open(first);
        _req(g1 >= 100 && g1 <= 179 && g2 >= 100 && g2 <= 179, "gear ids");
        _req(gear.pityCursor(gear.accountKey(user)) == 2, "both finalized");
        vm.prank(user);
        gear.equip(robotUser, g1);
        (uint256[4] memory ids) = gear.equipped(robotUser);
        _req(ids[uint8((g1 - 100) % 20 / 5)] == g1, "equipped");
        _req(gear.gearPowerBps(robotUser) > 0, "bonus live");
        _cons("after gear");
    }

    function test_battleSettleClaimRejectsSecondPayment() public {
        vm.prank(user);
        arena.enter{value: FEE}(_team(robotUser), false);
        vm.prank(other);
        arena.enter{value: FEE}(_team(robotOther), false);
        uint256 ep = _seal(4);
        uint256 tre0 = TREASURY.balance;
        arena.resolve(ep, 5);
        uint256 dev = 2 * FEE * arena.DEV_BPS() / 10_000;
        _req(TREASURY.balance == tre0 + dev, "dev cut");
        uint256 mid = arena.matchCount();
        arena.settle(mid);
        _req(TREASURY.balance == tre0 + dev, "settle does not pay dev again");
        AgentWorldArena.Match memory m = arena.getMatch(mid);
        _req(m.prize == 2 * FEE - dev, "prize is the remainder");
        address winner = m.winner == 1 ? m.walletA : m.walletB;
        uint256 before = winner.balance;
        vm.prank(winner);
        arena.claim();
        _req(winner.balance == before + m.prize, "prize once");
        _req(arena.pending(winner) == 0, "pending cleared");
        _cons("after battle");
    }

    function test_gearPaymentCannotReenterBuy() public {
        atk.setGear(gear, PRICE);
        gear.setTreasury(address(atk));
        uint256 before = gear.boxCount();
        vm.prank(user);
        gear.buy{value: PRICE}(0);
        _req(gear.boxCount() == before + 1, "one box");
        _req(!atk.gearNested(), "nested buy failed");
        _req(address(atk).balance >= PRICE / 2, "dev cut delivered");
    }

    function test_arenaClaimCannotReenter() public {
        atk.setArena(arena);
        vm.prank(address(atk));
        atk.enter(robotAtk, FEE);
        vm.prank(address(atk));
        atk.cancel(1);
        uint256 before = address(atk).balance;
        vm.prank(address(atk));
        atk.takeArena();
        _req(address(atk).balance == before + FEE, "refund once");
        _req(!atk.arenaNested(), "nested claim failed");
        _req(arena.pending(address(atk)) == 0, "no second credit");
        _cons("after reenter");
    }

    function test_lotteryClaimCannotReenterAndConserves() public {
        TinyArena tiny = new TinyArena(address(atk));
        AgentWorldLottery isolated = new AgentWorldLottery(IArenaLottery(address(tiny)), rnd);
        rnd.setRegistrar(address(isolated), true);
        atk.setLot(isolated);
        vm.deal(address(isolated), 1 ether);
        vm.warp(block.timestamp + 3 days);
        isolated.commit(0);
        _seal(9);
        isolated.draw(0);
        uint256 owed = isolated.pending(address(atk));
        _req(owed > 0, "winner paid into pending");
        uint256 before = address(atk).balance;
        vm.prank(address(atk));
        atk.takeLot();
        _req(address(atk).balance == before + owed, "lottery once");
        _req(!atk.lotNested(), "nested lottery claim failed");
        _req(address(isolated).balance == 1 ether - owed, "unpaid share stays");
        _req(isolated.owed() == 0 && isolated.reserved() == 0, "books cleared");
    }

    function test_pauseBlocksNewBuyAndEnterButNotClaim() public {
        vm.prank(user);
        arena.enter{value: FEE}(_team(robotUser), false);
        uint256 eid = arena.entryCount();
        vm.prank(user);
        arena.cancel(eid);
        gear.pause();
        arena.pause();
        vm.prank(user);
        (bool bought,) = address(gear).call{value: PRICE}(abi.encodeWithSignature("buy(uint8)", uint8(0)));
        _req(!bought, "gear paused");
        vm.prank(other);
        (bool entered,) = address(arena).call{value: FEE}(abi.encodeCall(AgentWorldArena.enter, (_team(robotOther), false)));
        _req(!entered, "arena paused");
        uint256 before = user.balance;
        vm.prank(user);
        arena.claim();
        _req(user.balance == before + FEE, "claim while paused");
    }
}

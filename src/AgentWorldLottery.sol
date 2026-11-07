// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EpochRandomness} from "./EpochRandomness.sol";

interface IArenaLottery {
    function revenueOnDay(uint256 day) external view returns (uint256);
    function eligibleCount(uint256 day) external view returns (uint256);
    function eligibleAt(uint256 day, uint256 i) external view returns (bytes32 key, address wallet);
    function freezeDay(uint256 day) external;
}

/// @title Agent World daily battle lottery (DRAFT, unaudited, not deployed)
/// @notice Funded ONLY by BNB already sent to this contract by the pools (set it as/feed it from the pool sink).
/// The dev treasury never pays in, so dev P&L is unaffected on every day. Eligibility: 10 arena battles in a UTC day,
/// one ticket per account (Agent ID key or manual-wallet key; same rule for both). Pot for day d =
/// min(5% of that day's arena revenue, eligible x ticketCapWei (~0.5U), maxPotWei (~50U), free balance).
/// 3 distinct winners 50/30/20 (fewer if fewer eligible; unused share stays in the pool). No eligible -> nothing
/// moves, no rollover. The arena has no daily claim cap (NOCAP 2026-10-29); lottery max per person per day = 50% of maxPot (~25U).
/// Flow: from day d+2 anyone calls commit(d), which freezes that arena day and reserves the pot, then draw(d) after the seed.
/// Winners pull with claim() (pull pattern).
contract AgentWorldLottery is Ownable, Pausable, ReentrancyGuard {
    uint16 public constant REV_BPS = 500;
    uint16[3] public SHARE_BPS = [uint16(5000), 3000, 2000];
    uint256 public constant MAX_POT_LIMIT = 0.1 ether; // hard ceiling for owner config

    IArenaLottery public arena; EpochRandomness public randomness;
    uint256 public ticketCapWei = 0.000675 ether; // ~0.5U per eligible account
    uint256 public maxPotWei = 0.0675 ether;      // ~50U
    uint256 public owed;                          // unclaimed winnings (reserved)
    uint256 public reserved;                      // pots committed but not yet drawn
    mapping(address => uint256) public pending;
    mapping(uint256 => uint8) public status;      // day => 0 none,1 committed,2 drawn
    mapping(uint256 => uint256) public potOfDay;
    mapping(uint256 => uint256) public committedCount;
    mapping(uint256 => uint256) public committedPot;
    mapping(uint256 => address[3]) internal _winners;

    event Funded(address indexed from, uint256 amount);
    event Committed(uint256 indexed day, uint256 epoch, uint256 eligible);
    event PotReserved(uint256 indexed day, uint256 pot);
    event Drawn(uint256 indexed day, uint256 pot, address[3] winners, uint256[3] amounts, uint256 seed);
    event Claimed(address indexed wallet, uint256 amount);
    error DayNotOver(); error BadStatus(); error NotReady(); error Nothing(); error TransferFailed(); error BadConfig();

    constructor(IArenaLottery a, EpochRandomness r) Ownable(msg.sender) { arena = a; randomness = r; }
    receive() external payable { emit Funded(msg.sender, msg.value); }

    function today() public view returns (uint256) { return block.timestamp / 1 days; }
    function freeBalance() public view returns (uint256) { return address(this).balance - owed - reserved; }

    /// @notice Live pot before commit. After commit, the value reserved at commit (later revenue and cap edits do not apply).
    function potFor(uint256 day) public view returns (uint256 p) {
        if (status[day] != 0) return committedPot[day];
        uint256 n = arena.eligibleCount(day); if (n == 0) return 0;
        p = arena.revenueOnDay(day) * REV_BPS / 10_000;
        uint256 c = n * ticketCapWei; if (c < p) p = c;
        if (maxPotWei < p) p = maxPotWei;
        uint256 f = freeBalance(); if (f < p) p = f;
    }

    function commit(uint256 day) external nonReentrant whenNotPaused returns (uint256 epoch) {
        if (day + 2 > today()) revert DayNotOver(); // 1-day lag: arena rounds of `day` are paired after their epoch seed
        if (status[day] != 0) revert BadStatus();
        arena.freezeDay(day); // O(1). Later arena resolves cannot extend this day.
        uint256 n = arena.eligibleCount(day);
        if (n == 0) { status[day] = 2; emit Committed(day, 0, 0); return 0; } // nothing to draw; funds stay
        uint256 p = potFor(day);
        status[day] = 1; committedCount[day] = n; committedPot[day] = p; reserved += p;
        epoch = randomness.register(day);
        emit Committed(day, epoch, n); emit PotReserved(day, p);
    }

    function draw(uint256 day) external nonReentrant whenNotPaused returns (address[3] memory w, uint256[3] memory amt) {
        if (status[day] != 1) revert BadStatus();
        if (!randomness.isReady(address(this), day)) revert NotReady();
        status[day] = 2;
        uint256 seed = randomness.randomOf(address(this), day);
        uint256 n = committedCount[day];
        uint256 pot = committedPot[day]; potOfDay[day] = pot;
        reserved -= pot; // unpaid share and rounding dust return to freeBalance
        uint256 k = n < 3 ? n : 3;
        uint256[3] memory idx;
        for (uint256 i; i < k; i++) {
            uint256 x = uint256(keccak256(abi.encode(seed, i))) % (n - i);
            // partial Fisher-Yates over a virtual array: map collisions forward
            for (uint256 j; j < i; j++) if (x >= idx[j]) x++;
            // keep idx sorted so the skip-forward stays correct
            uint256 pos = i; while (pos > 0 && idx[pos - 1] > x) { idx[pos] = idx[pos - 1]; pos--; } idx[pos] = x;
            (, address wa) = arena.eligibleAt(day, x);
            w[i] = wa; amt[i] = pot * SHARE_BPS[i] / 10_000;
            if (amt[i] != 0) { pending[wa] += amt[i]; owed += amt[i]; }
        }
        _winners[day] = w;
        emit Drawn(day, pot, w, amt, seed);
    }

    function claim() external nonReentrant returns (uint256 a) {
        a = pending[msg.sender]; if (a == 0) revert Nothing();
        pending[msg.sender] = 0; owed -= a;
        (bool ok,) = payable(msg.sender).call{value: a}(""); if (!ok) revert TransferFailed();
        emit Claimed(msg.sender, a);
    }

    // views (no wallet needed)
    function winnersOf(uint256 day) external view returns (address[3] memory) { return _winners[day]; }
    function dayInfo(uint256 day) external view returns (uint8 st, uint256 eligible, uint256 revenue, uint256 potNow, uint256 potDrawn) {
        uint256 n = status[day] == 0 ? arena.eligibleCount(day) : committedCount[day];
        return (status[day], n, arena.revenueOnDay(day), potFor(day), potOfDay[day]);
    }

    function setCaps(uint256 ticketCap, uint256 maxPot) external onlyOwner {
        if (ticketCap == 0 || maxPot == 0 || maxPot > MAX_POT_LIMIT || ticketCap > maxPot) revert BadConfig();
        ticketCapWei = ticketCap; maxPotWei = maxPot;
    }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}

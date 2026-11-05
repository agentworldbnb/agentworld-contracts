// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EpochRandomness} from "./EpochRandomness.sol";

interface IGearForge {
    function accountKey(address a) external view returns (bytes32);
    function forgeBurn(address from, uint256 gearId, uint256 n) external;
    function forgeMint(address to, uint256 gearId) external;
    function forgeRedeemBox(address buyer, bytes32 a, uint8 tier) external returns (uint256);
    function treasury() external view returns (address);
    function poolSink() external view returns (address);
    function seasonSink() external view returns (address);
}

interface ICodex { function lightCodex(address w, uint256[] calldata ids) external; }
interface IRobotsCraft {
    function specialCharOf(uint256 id) external view returns (uint8);
    function ownerOf(uint256 id) external view returns (address);
    function fusionBurn(uint256 id) external;
    function mintSpecial(address to, uint256 c, bool crafted) external returns (uint256);
    function craftHold(uint256 c, bool reserve) external;
    function craftLock(uint256 id, bool on) external;
    function craftLocked(uint256 id) external view returns (bool);
    function isApprovedForAll(address o, address op) external view returns (bool);
    function getApproved(uint256 id) external view returns (address);
}

/// @title Agent World Resonance Forge + dismantle + shards (DRAFT, unaudited, not deployed)
/// @notice Identical rules for Agent ID wallets and manual wallets (account key from AgentWorldGear.accountKey).
/// Forge: 3 gear + fee -> 1 gear, 40% chance of a bonus "echo" item; settled from the shared VRF epoch seed.
/// Gear power stays capped at +20% per hero in AgentWorldGear (GEAR_POWER_CAP_BPS); traits emitted here are cosmetic only.
/// HERO CRAFTING (2026-10-30 final): deterministic recipes (player picks the target, no randomness) -> special hero, Fusion frame.
/// Weeks for the shard cap are block.timestamp / 7 days = Thursday 00:00 UTC (Thursday 08:00 Taipei) resets.
/// Shards: bound to the account key, no transfer function exists. Fee split 50% dev / 42.9% daily / 7.1% season.
contract AgentWorldForge is Ownable, Pausable, ReentrancyGuard {
    uint16 public constant DEV_BPS = 5000; uint16 public constant SEASON_BPS = 710;
    uint16 public constant BONUS_BPS = 4000;   // 40% echo
    uint16 public constant UPGRADE_BPS = 5000; // 50% chance output = min input rarity + 1
    uint256 public constant RESONANCE_ENTRIES = 50; // epoch with >=50 entries: echo rarity = output rarity
    uint256 public constant MAX_FEE = 0.01 ether;
    uint8 public constant REDEEM_PER_WEEK = 2;
    uint16[5] public SHARD_YIELD = [uint16(1), 3, 8, 20, 50];
    uint256[2] public redeemShards = [40, 120];

    IGearForge public gear; EpochRandomness public randomness;
    uint256 public forgeFeeWei = 0.00081 ether;            // ~0.6U
    uint256[2] public redeemFeeWei = [uint256(0.000135 ether), 0.00027 ether]; // ~0.1U / 0.2U
    uint256 public dailyPoolWei; uint256 public seasonPoolWei;

    mapping(bytes32 => uint256) public shards;                       // account key => shards (non-transferable)
    mapping(bytes32 => mapping(uint256 => uint8)) public redeemedInWeek; // key => week => n
    struct Entry { address owner; bytes32 key; uint8 minRar; bool settled; uint256 epoch; uint256 traitMix; uint8 set; } // set 0..3 = all inputs one set, 255 = mixed (VRF picks)
    mapping(uint256 => Entry) public entries; uint256 public entryCount;
    mapping(uint256 => uint256) public entriesInEpoch;
    uint256 internal constant ID_BASE = 1 << 128; // forge ids live in their own randomness id space

    event Dismantled(bytes32 indexed key, address indexed owner, uint256 gearId, uint256 n, uint256 shards);
    event ForgeEntered(uint256 indexed entryId, bytes32 indexed key, address owner, uint256[3] gearIds, uint256 epoch);
    event ForgeSettled(uint256 indexed entryId, uint256 gearId, uint256 echoGearId, uint256 traitSeed);
    event ShardsRedeemed(bytes32 indexed key, address owner, uint8 tier, uint256 boxId);
    error WrongValue(); error BadGear(); error BadQty(); error NotReady(); error Settled(); error NotOwner();
    error NoShards(); error WeeklyCap(); error BadTier(); error BadFee(); error TransferFailed();

    constructor(IGearForge g, EpochRandomness r) Ownable(msg.sender) { gear = g; randomness = r; }

    // ---------- hero crafting (合成), VRF since 2026-10-30 ----------
    // Elite  (f01-f10): 3 UR gear (any slots) + craftFeeWei[0] (~1U)          success 80%
    // Mythic (e01-e05): 2 Elite-class heroes (f, any frame) + craftFeeWei[1] (~2U)  success 60%
    // Legend (l01-l02): 2 Mythic-class heroes (e, any frame) + craftFeeWei[2] (~5U) success 40%  -- Legend is Forge-only
    // Request: fee taken and split (kept on failure), one cap slot reserved, gear inputs burned / hero inputs locked in
    // place (holder must setApprovalForAll(forge)). Settle (anyone, once the shared VRF epoch seed exists):
    // success -> hero inputs burned, hero minted (Fusion frame); failure -> slot released, ONE random input returned
    // (1 of the 3 gear re-minted, or 1 of the 2 heroes unlocked; the other burned). No pity. Same seed flow as enter/settle.
    IRobotsCraft public robots;
    uint256[3] public craftFeeWei = [uint256(0.00135 ether), 0.0027 ether, 0.00675 ether];
    uint16 public constant CRAFT_ELITE_BPS = 8000; uint16 public constant CRAFT_MYTHIC_BPS = 6000; uint16 public constant CRAFT_LEGEND_BPS = 4000;
    uint256 internal constant CRAFT_BASE = 2 << 128; // craft ids: own randomness id space (disjoint from forge entries)
    struct Craft { address owner; uint8 recipe; uint8 c; bool settled; uint256[3] mats; }
    mapping(uint256 => Craft) internal crafts; uint256 public craftCount;
    event CraftRequested(uint256 indexed craftId, address indexed owner, uint256 charIdx, uint8 recipe, uint256 epoch);
    event HeroCrafted(address indexed owner, uint256 indexed robotId, uint256 charIdx, uint8 recipe);
    event CraftFailed(uint256 indexed craftId, address indexed owner, uint256 returnedId, uint8 recipe);
    error Capped();
    function setRobots(IRobotsCraft r) external onlyOwner { robots = r; }
    ICodex public codex; // Arena: crafted hero kind is lit in the wallet's codex (best effort, never blocks settle)
    function setCodex(ICodex c) external onlyOwner { codex = c; }
    function setCraftFees(uint256 a, uint256 b, uint256 c) external onlyOwner { if (a == 0 || b == 0 || c == 0 || a > MAX_FEE || b > MAX_FEE || c > MAX_FEE) revert BadFee(); craftFeeWei = [a, b, c]; }
    /// @return id craft request id (settle with settleCraft once the epoch seed is fulfilled)
    function craftElite(uint8 target, uint256[3] calldata urGear) external payable nonReentrant whenNotPaused returns (uint256 id) {
        if (target > 9) revert BadTier(); if (msg.value != craftFeeWei[0]) revert WrongValue();
        for (uint256 i; i < 3; i++) { if (urGear[i] < 100 || urGear[i] > 179 || urGear[i] % 5 != 4) revert BadGear(); gear.forgeBurn(msg.sender, urGear[i], 1); }
        id = _craftRequest(35 + target, 0, urGear);
    }
    function craftMythic(uint8 target, uint256[2] calldata heroes) external payable nonReentrant whenNotPaused returns (uint256 id) {
        if (target > 4) revert BadTier(); if (msg.value != craftFeeWei[1]) revert WrongValue();
        _lockHeroes(heroes, 35, 44); id = _craftRequest(30 + target, 1, [heroes[0], heroes[1], 0]);
    }
    function craftLegend(uint8 target, uint256[2] calldata heroes) external payable nonReentrant whenNotPaused returns (uint256 id) {
        if (target > 1) revert BadTier(); if (msg.value != craftFeeWei[2]) revert WrongValue();
        _lockHeroes(heroes, 30, 34); id = _craftRequest(45 + target, 2, [heroes[0], heroes[1], 0]);
    }
    function _lockHeroes(uint256[2] calldata h, uint256 lo, uint256 hi) internal {
        if (h[0] == h[1]) revert BadQty();
        for (uint256 i; i < 2; i++) {
            uint256 c = robots.specialCharOf(h[i]); if (c < lo || c > hi) revert BadGear();
            if (robots.ownerOf(h[i]) != msg.sender) revert NotOwner();
            if (robots.craftLocked(h[i])) revert Settled();
            if (!robots.isApprovedForAll(msg.sender, address(this)) && robots.getApproved(h[i]) != address(this)) revert NotOwner();
            robots.craftLock(h[i], true);
        }
    }
    function _craftRequest(uint256 c, uint8 recipe, uint256[3] memory mats) internal returns (uint256 id) {
        robots.craftHold(c, true); // reverts if minted + pending would exceed the cap
        id = ++craftCount;
        crafts[id] = Craft(msg.sender, recipe, uint8(c), false, mats);
        uint256 ep = randomness.register(CRAFT_BASE + id);
        _split(msg.value); emit CraftRequested(id, msg.sender, c, recipe, ep);
    }
    /// @notice Pure preview once the seed exists: success, and on failure the index of the returned input.
    function previewCraft(uint256 id) public view returns (bool ok, uint256 back) {
        if (crafts[id].owner == address(0)) revert BadQty();
        if (!randomness.isReady(address(this), CRAFT_BASE + id)) revert NotReady();
        uint256 r = randomness.randomOf(address(this), CRAFT_BASE + id);
        Craft storage x = crafts[id];
        ok = r % 10_000 < (x.recipe == 0 ? CRAFT_ELITE_BPS : x.recipe == 1 ? CRAFT_MYTHIC_BPS : CRAFT_LEGEND_BPS);
        back = (r >> 64) % (x.recipe == 0 ? 3 : 2);
    }
    /// @notice Anyone may settle (keepers/agents); results always go to the requester.
    function settleCraft(uint256 id) external nonReentrant whenNotPaused returns (bool ok, uint256 robotId) {
        Craft storage x = crafts[id]; if (x.settled) revert Settled();
        uint256 back; (ok, back) = previewCraft(id);
        x.settled = true; address o = x.owner; uint8 rc = x.recipe;
        if (rc != 0) for (uint256 i; i < 2; i++) {
            if (!ok && i == back) robots.craftLock(x.mats[i], false); else robots.fusionBurn(x.mats[i]);
        }
        if (ok) {
            robotId = robots.mintSpecial(o, x.c, true); if (robotId == 0) revert Capped();
            emit HeroCrafted(o, robotId, x.c, rc);
            if (address(codex) != address(0)) { uint256[] memory l = new uint256[](1); l[0] = robotId; try codex.lightCodex(o, l) {} catch {} }
        } else {
            robots.craftHold(x.c, false);
            if (rc == 0) gear.forgeMint(o, x.mats[back]);
            emit CraftFailed(id, o, x.mats[back], rc);
        }
    }
    function craftOf(uint256 id) external view returns (address who, uint8 recipe, uint8 charIdx, bool settled, uint256[3] memory mats, bool ready) {
        Craft storage x = crafts[id];
        return (x.owner, x.recipe, x.c, x.settled, x.mats, x.owner != address(0) && randomness.isReady(address(this), CRAFT_BASE + id));
    }

    // ---------- dismantle ----------
    function dismantle(uint256 gearId, uint256 n) external nonReentrant whenNotPaused returns (uint256 got) {
        got = _dismantle(gearId, n);
    }
    function dismantleMany(uint256[] calldata ids, uint256[] calldata ns) external nonReentrant whenNotPaused returns (uint256 got) {
        if (ids.length != ns.length || ids.length == 0 || ids.length > 20) revert BadQty();
        for (uint256 i; i < ids.length; i++) got += _dismantle(ids[i], ns[i]);
    }
    function _dismantle(uint256 gearId, uint256 n) internal returns (uint256 got) {
        if (n == 0) revert BadQty(); if (gearId < 100 || gearId > 179) revert BadGear();
        bytes32 k = gear.accountKey(msg.sender);
        gear.forgeBurn(msg.sender, gearId, n);      // reverts if not owned or equipped (locked)
        got = SHARD_YIELD[gearId % 5] * n; shards[k] += got;
        emit Dismantled(k, msg.sender, gearId, n, got);
    }

    // ---------- shard -> box redemption (no pity, weekly cap 2, seasonal not redeemable) ----------
    function redeem(uint8 tier) external payable nonReentrant whenNotPaused returns (uint256 boxId) {
        if (tier > 1) revert BadTier();
        if (msg.value != redeemFeeWei[tier]) revert WrongValue();
        bytes32 k = gear.accountKey(msg.sender);
        uint256 wk = block.timestamp / 7 days;
        if (redeemedInWeek[k][wk] >= REDEEM_PER_WEEK) revert WeeklyCap();
        if (shards[k] < redeemShards[tier]) revert NoShards();
        redeemedInWeek[k][wk]++; shards[k] -= redeemShards[tier];
        boxId = gear.forgeRedeemBox(msg.sender, k, tier);
        _split(msg.value);
        emit ShardsRedeemed(k, msg.sender, tier, boxId);
    }

    // ---------- resonance forge ----------
    function enter(uint256[3] calldata ids) external payable nonReentrant whenNotPaused returns (uint256 e) {
        if (msg.value != forgeFeeWei) revert WrongValue();
        e = _enter(ids);
        _split(msg.value);
    }
    function enterMany(uint256[3][] calldata sets) external payable nonReentrant whenNotPaused returns (uint256[] memory es) {
        if (sets.length == 0 || sets.length > 10) revert BadQty();
        if (msg.value != forgeFeeWei * sets.length) revert WrongValue();
        es = new uint256[](sets.length);
        for (uint256 i; i < sets.length; i++) es[i] = _enter(sets[i]);
        _split(msg.value);
    }
    function _enter(uint256[3] calldata ids) internal returns (uint256 e) {
        bytes32 k = gear.accountKey(msg.sender);
        uint8 minR = 4; uint256 mix; uint8 st;
        for (uint256 i; i < 3; i++) {
            if (ids[i] < 100 || ids[i] > 179) revert BadGear();
            gear.forgeBurn(msg.sender, ids[i], 1);
            uint8 r = uint8(ids[i] % 5); if (r < minR) minR = r;
            uint8 si = uint8((ids[i] - 100) / 20); if (i == 0) st = si; else if (si != st) st = 255;
            mix = uint256(keccak256(abi.encode(mix, ids[i])));
        }
        e = ++entryCount;
        uint256 ep = randomness.register(ID_BASE + e);
        entriesInEpoch[ep]++;
        entries[e] = Entry(msg.sender, k, minR, false, ep, mix, st);
        emit ForgeEntered(e, k, msg.sender, ids, ep);
    }
    /// @notice Anyone may settle (keepers/agents); output always goes to the entry owner. Deterministic from epoch seed.
    function settle(uint256 e) public nonReentrant whenNotPaused returns (uint256 out, uint256 echo) { (out, echo) = _settle(e); }
    function settleMany(uint256[] calldata es) external nonReentrant whenNotPaused returns (uint256 n) {
        for (uint256 i; i < es.length; i++) {
            Entry storage x = entries[es[i]];
            if (x.owner != address(0) && !x.settled && randomness.isReady(address(this), ID_BASE + es[i])) { _settle(es[i]); n++; }
        }
    }
    /// @notice Pure preview of the outcome once the seed exists (lets anyone verify settlement).
    function preview(uint256 e) public view returns (uint256 out, uint256 echo, uint256 traitSeed) {
        Entry storage x = entries[e]; if (x.owner == address(0)) revert BadQty();
        if (!randomness.isReady(address(this), ID_BASE + e)) revert NotReady();
        uint256 r = randomness.randomOf(address(this), ID_BASE + e);
        uint8 rar = x.minRar; if (rar < 4 && r % 10_000 < UPGRADE_BPS) rar++;
        // GEAR v2: one-set inputs keep their set; mixed sets => set from the VRF word ((r>>128)%4 out, (r>>160)%4 echo)
        out = 100 + (x.set < 4 ? x.set : (r >> 128) % 4) * 20 + (r >> 32) % 4 * 5 + rar;
        echo = type(uint256).max;
        if ((r >> 64) % 10_000 < BONUS_BPS) {
            uint8 er = entriesInEpoch[x.epoch] >= RESONANCE_ENTRIES ? rar : (rar > 0 ? rar - 1 : 0);
            echo = 100 + (x.set < 4 ? x.set : (r >> 160) % 4) * 20 + (r >> 96) % 4 * 5 + er;
        }
        traitSeed = uint256(keccak256(abi.encode(r, x.traitMix)));
    }
    function _settle(uint256 e) internal returns (uint256 out, uint256 echo) {
        Entry storage x = entries[e];
        if (x.settled) revert Settled();
        uint256 ts; (out, echo, ts) = preview(e);
        x.settled = true;
        gear.forgeMint(x.owner, out);
        if (echo != type(uint256).max) gear.forgeMint(x.owner, echo);
        emit ForgeSettled(e, out, echo, ts);
    }

    // ---------- views (by address or account key; no wallet needed) ----------
    function shardsOf(address a) external view returns (uint256) { return shards[gear.accountKey(a)]; }
    function redeemLeftThisWeek(address a) external view returns (uint256) {
        return REDEEM_PER_WEEK - redeemedInWeek[gear.accountKey(a)][block.timestamp / 7 days];
    }
    function entriesOf(address a) external view returns (uint256[] memory ids, bool[] memory settled, bool[] memory ready) {
        uint256 n; for (uint256 i = 1; i <= entryCount; i++) if (entries[i].owner == a) n++;
        ids = new uint256[](n); settled = new bool[](n); ready = new bool[](n); n = 0;
        for (uint256 i = 1; i <= entryCount; i++) if (entries[i].owner == a) {
            ids[n] = i; settled[n] = entries[i].settled; ready[n] = randomness.isReady(address(this), ID_BASE + i); n++; }
    }

    // ---------- money ----------
    function _split(uint256 v) internal {
        uint256 dev = v * DEV_BPS / 10_000; uint256 s = v * SEASON_BPS / 10_000;
        dailyPoolWei += v - dev - s; seasonPoolWei += s; _send(gear.treasury(), dev);
    }
    function flushPools() external nonReentrant {
        uint256 d = dailyPoolWei; uint256 s = seasonPoolWei; dailyPoolWei = 0; seasonPoolWei = 0;
        address ss = gear.seasonSink(); _send(gear.poolSink(), d); _send(ss == address(0) ? gear.poolSink() : ss, s); // daily -> lottery, season separate
    }
    function _send(address to, uint256 v) internal { if (v == 0) return; (bool ok,) = payable(to).call{value: v}(""); if (!ok) revert TransferFailed(); }
    function setFees(uint256 forgeFee, uint256 r0, uint256 r1) external onlyOwner {
        if (forgeFee == 0 || forgeFee > MAX_FEE || r0 > MAX_FEE || r1 > MAX_FEE) revert BadFee();
        forgeFeeWei = forgeFee; redeemFeeWei = [r0, r1];
    }
    function setRedeemShards(uint256 a, uint256 b) external onlyOwner { if (a < 20 || b < a) revert BadFee(); redeemShards = [a, b]; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}

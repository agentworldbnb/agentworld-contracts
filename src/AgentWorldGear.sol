// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IAgentEligibility} from "./IAgentEligibility.sol";
import {EpochRandomness} from "./EpochRandomness.sol";
import {AddressTimelock} from "./AddressTimelock.sol";

interface IGearArena { function charOf(uint256 id) external view returns (uint256); }
interface IRobots { function ownerOf(uint256 id) external view returns (address); function mintSpecial(address to, uint256 c, bool crafted) external returns (uint256); }

/// @title Agent World gear blind boxes (DRAFT, unaudited)
/// @notice Native BNB only. Buy = commit (box registered in the open VRF epoch); open = deterministic reveal from the
/// epoch seed. Split at payment: 50% dev treasury, 42.9% daily pool, 7.1% season pool (bps 5000/4290/710).
/// GEAR v2 (2026-10-30): tokenId = 100 + set*20 + slot*5 + rarity (100..179). set 0..3 Riftwalker(blade) / Starcore Hunter(gun)
/// / Singularity Siege(cannon) / Psionic Nexus(staff); slot 0..3 weapon/armor/core/accessory; rarity 0..4 N/R/SR/SSR/UR.
contract AgentWorldGear is ERC1155, Ownable, Pausable, ReentrancyGuard, AddressTimelock {
    enum Tier { Normal, Premium, Seasonal }
    uint16 public constant DEV_BPS = 5000; uint16 public constant DAILY_BPS = 4290; uint16 public constant SEASON_BPS = 710;
    uint16 public constant GEAR_POWER_CAP_BPS = 2000;    // +20% total (user decision 2026-10-29)
    uint16[5] public POWER_BPS = [uint16(125), 250, 375, 625, 750]; // per item, <= 7.5%
    uint8 public constant PITY_SSR = 40; uint16 public constant PITY_UR = 200;
    uint256 public constant MIN_PRICE = 0.0001 ether; uint256 public constant MAX_PRICE = 0.05 ether;
    uint256 public constant WL_SUPPLY = 500; uint256 public constant WL_PER_AGENT = 20;

    // odds in bps, cumulative N,R,SR,SSR,UR (published)
    uint16[5][3] public odds;
    uint256[3] public priceWei;              // ~1U / 3U / 8U in BNB
    uint256[3] public dailyBoxLimit = [uint256(100), 100, 100]; // 2026-10-30 final: per account per UTC day, PER box type (common/premium/seasonal), owner-adjustable
    uint256 public seasonId;                 // seasonal box tag; owner bumps per season
    bool public seasonalOpen;

    address public treasury; address public poolSink; // poolSink = future prize-pool contract
    uint256 public dailyPoolWei; uint256 public seasonPoolWei;
    IAgentEligibility public eligibility; EpochRandomness public randomness; IRobots public robots;

    struct Box { bytes32 agent; address buyer; uint8 tier; bool opened; bool wl; }
    mapping(uint256 => Box) public boxes; uint256 public boxCount;
    mapping(bytes32 => mapping(uint256 => mapping(uint8 => uint256))) public boughtOnDay; // account key => UTC day => tier => boxes bought
    mapping(bytes32 => uint16) public sinceSSR; mapping(bytes32 => uint16) public sinceUR;
    /// Pity is applied in purchase order once a box's seed is ready, never in the order the buyer chooses to open.
    /// One call walks at most MAX_PITY_STEPS boxes. A seed that never arrives is skipped after PITY_SEED_GRACE
    /// so a later box cannot be blocked forever; a skipped box then rolls its natural rarity and does not move pity.
    uint256 public constant MAX_PITY_STEPS = 32;
    uint256 public constant PITY_SEED_GRACE = 2 days;
    mapping(bytes32 => uint256[]) internal _pityQ;
    mapping(bytes32 => uint256) public pityCursor;
    mapping(uint256 => uint64) public boughtAt;
    mapping(uint256 => bool) public rarityReady;
    mapping(uint256 => uint8) public rolledRarity;
    mapping(uint256 => bool) public pityExcluded;

    // whitelist
    uint256 public wlFeeWei = 0.000675 ether; bytes32 public wlRoot; uint256 public wlCampaign; uint256 public wlClaimed;
    mapping(bytes32 => uint256) public wlByAgent; mapping(uint256 => mapping(bytes32 => uint256)) public wlInCampaign;

    // equipment: per robot, 4 slots, gear locked while equipped
    mapping(uint256 => uint256[4]) internal equippedPlus1;     // robotId => slot => gearId+1 (0 = empty)
    mapping(uint256 => address) public equippedBy;              // robotId => wallet holding the locked gear
    mapping(address => mapping(uint256 => uint256)) public locked; // wallet => gearId => n

    event BoxBought(uint256 indexed boxId, bytes32 indexed agent, uint8 tier, uint256 paid, uint256 epoch);
    event BoxOpened(uint256 indexed boxId, uint256 gearId, uint8 rarity, bool pity);
    event PityFinalized(uint256 indexed boxId, bytes32 indexed agent, uint8 rarity, bool pity);
    event PityExcluded(uint256 indexed boxId);
    event Equipped(uint256 indexed robotId, uint8 slot, uint256 gearId);
    event Unequipped(uint256 indexed robotId, uint8 slot, uint256 gearId);
    event WhitelistRootSet(uint256 indexed campaign, bytes32 root);
    error NotAgent(); error NotOpen(); error WrongValue(); error LimitReached(); error BadTier();
    error NotReady(); error AlreadyOpened(); error NotBuyer(); error BadPrice(); error NotRobotOwner(); error BadSlot();
    error NoGear(); error Locked(); error RecipientNotAgent(address to); error WlProof(); error WlCap(); error WlAgentCap();
    error WlAllocation(); error ZeroAddress(); error TransferFailed(); error BadQty(); error BadOdds(); error PityPending();

    constructor(address treasury_, address poolSink_, IAgentEligibility e, EpochRandomness r, IRobots robots_, uint256[3] memory prices)
        ERC1155("") Ownable(msg.sender) {
        if (treasury_ == address(0) || poolSink_ == address(0)) revert ZeroAddress();
        treasury = treasury_; poolSink = poolSink_; eligibility = e; randomness = r; robots = robots_;
        for (uint256 i; i < 3; i++) { if (prices[i] < MIN_PRICE || prices[i] > MAX_PRICE) revert BadPrice(); priceWei[i] = prices[i]; }
        odds[0] = [uint16(6000), 8700, 9700, 9970, 10000]; // N60 R27 SR10 SSR2.7 UR0.3
        odds[1] = [uint16(0), 5500, 8800, 9800, 10000];    // R55 SR33 SSR10 UR2
        odds[2] = [uint16(0), 0, 6000, 9500, 10000];       // seasonal: SR60 SSR35 UR5
    }

    function _agent(address a) internal view returns (bytes32 key) {
        (bool ok, bytes32 k) = eligibility.agentKey(a, "");
        if (ok) return k;
        if (!openToWallets) revert NotAgent();
        key = keccak256(abi.encode("wallet", a)); // manual wallet: same caps, keyed per wallet
    }
    function _agentOnly(address a) internal view returns (bytes32 k) { bool ok; (ok, k) = eligibility.agentKey(a, ""); if (!ok) revert NotAgent(); }
    /// @notice Manual wallets get every feature, whitelist claims included (keyed per wallet, same caps).
    bool public openToWallets = true;
    function setOpenToWallets(bool on) external onlyOwner { openToWallets = on; }

    // --- buy ---
    function buy(uint8 tier) external payable nonReentrant whenNotPaused returns (uint256 id) {
        if (msg.value != priceWei[tier < 3 ? tier : 0]) revert WrongValue();
        id = _buy(tier);
    }
    /// @notice Agent/human convenience: buy `n` boxes of one tier in one tx (same limits/caps as buy()).
    function buyMany(uint8 tier, uint256 n) external payable nonReentrant whenNotPaused returns (uint256[] memory ids) {
        if (n == 0 || n > 10) revert BadQty();
        if (tier > 2) revert BadTier();
        if (msg.value != priceWei[tier] * n) revert WrongValue();
        ids = new uint256[](n);
        for (uint256 i; i < n; i++) ids[i] = _buy(tier);
    }
    function _buy(uint8 tier) internal returns (uint256 id) {
        if (tier > 2) revert BadTier();
        if (tier == 2 && !seasonalOpen) revert NotOpen();
        bytes32 a = _agent(msg.sender);
        uint256 p = priceWei[tier];
        if (++boughtOnDay[a][block.timestamp / 1 days][tier] > dailyBoxLimit[tier]) revert LimitReached();
        id = _newBox(a, tier, false);
        uint256 dev = p * DEV_BPS / 10_000; uint256 season = p * SEASON_BPS / 10_000;
        dailyPoolWei += p - dev - season; seasonPoolWei += season;
        _send(treasury, dev);
        emit BoxBought(id, a, tier, p, 0);
    }
    function _newBox(bytes32 a, uint8 tier, bool wl) internal returns (uint256 id) {
        id = ++boxCount; boxes[id] = Box(a, msg.sender, tier, false, wl);
        boughtAt[id] = uint64(block.timestamp); _pityQ[a].push(id);
        randomness.register(id);
    }

    // --- whitelist (free except fee to treasury; no pool contribution) ---
    function claimWhitelist(uint256 qty, uint256 allocation, bytes32[] calldata proof) external payable nonReentrant whenNotPaused {
        if (wlRoot == bytes32(0)) revert NotOpen();
        if (qty == 0 || qty > WL_PER_AGENT) revert BadQty();
        if (msg.value != wlFeeWei * qty) revert WrongValue();
        bytes32 a = _agent(msg.sender); // Agent ID key, or keccak("wallet", addr) for a manual wallet: same caps
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(wlCampaign, a, allocation))));
        if (!MerkleProof.verifyCalldata(proof, wlRoot, leaf)) revert WlProof();
        if (wlInCampaign[wlCampaign][a] + qty > allocation) revert WlAllocation();
        if (wlByAgent[a] + qty > WL_PER_AGENT) revert WlAgentCap();
        if (wlClaimed + qty > WL_SUPPLY) revert WlCap();
        wlInCampaign[wlCampaign][a] += qty; wlByAgent[a] += qty; wlClaimed += qty;
        for (uint256 i; i < qty; i++) { uint256 id = _newBox(a, 0, true); emit BoxBought(id, a, 0, 0, 0); }
        _send(treasury, msg.value);
    }

    // --- open (after epoch seed) ---
    function open(uint256 id) external nonReentrant whenNotPaused returns (uint256 gearId) { gearId = _open(id, true); }
    /// @notice Open every ready box in `ids`. Not-ready, already-opened, or still waiting on an earlier pity box are skipped.
    function openMany(uint256[] calldata ids) external nonReentrant whenNotPaused returns (uint256 opened) {
        for (uint256 i; i < ids.length; i++) {
            Box storage b = boxes[ids[i]];
            if (b.buyer != msg.sender || b.opened || !randomness.isReady(address(this), ids[i])) continue;
            if (_open(ids[i], false) != 0) opened++;
        }
    }
    /// @notice Finalize up to maxSteps pity boxes for `agent` in purchase order. Anyone may call.
    /// Stops at the first box whose seed is missing and still inside PITY_SEED_GRACE. Does not mint.
    function materialize(bytes32 agent, uint256 maxSteps) external nonReentrant returns (uint256 n) {
        if (maxSteps == 0 || maxSteps > MAX_PITY_STEPS) revert BadQty();
        n = _materialize(agent, maxSteps);
    }
    function pityQueueLength(bytes32 agent) external view returns (uint256) { return _pityQ[agent].length; }
    /// @notice Box ids of `buyer` (view, for agents and the web UI; no wallet needed).
    function boxesOf(address buyer) external view returns (uint256[] memory ids, bool[] memory opened, bool[] memory ready) {
        uint256 n; for (uint256 i = 1; i <= boxCount; i++) if (boxes[i].buyer == buyer) n++;
        ids = new uint256[](n); opened = new bool[](n); ready = new bool[](n); n = 0;
        for (uint256 i = 1; i <= boxCount; i++) if (boxes[i].buyer == buyer) {
            ids[n] = i; opened[n] = boxes[i].opened; ready[n] = randomness.isReady(address(this), i); n++; }
    }
    /// @notice All 20 gear balances (tokenId = slot*10+rarity) and how many are locked (equipped).
    function inventory(address a) external view returns (uint256[80] memory bal, uint256[80] memory lockedN) {
        for (uint256 i; i < 80; i++) { bal[i] = balanceOf(a, 100 + i); lockedN[i] = locked[a][100 + i]; } // index i = gearId - 100
    }
    function _materialize(bytes32 agent, uint256 maxSteps) internal returns (uint256 n) {
        uint256[] storage q = _pityQ[agent];
        uint256 c = pityCursor[agent];
        uint256 stop = c + maxSteps;
        if (stop > q.length) stop = q.length;
        while (c < stop) {
            uint256 id = q[c];
            if (rarityReady[id] || pityExcluded[id]) { unchecked { c++; n++; } continue; }
            if (!randomness.isReady(address(this), id)) {
                if (block.timestamp < uint256(boughtAt[id]) + PITY_SEED_GRACE) break;
                pityExcluded[id] = true; emit PityExcluded(id);
                unchecked { c++; n++; } continue;
            }
            _finalizePity(id);
            unchecked { c++; n++; }
        }
        pityCursor[agent] = c;
    }
    function _finalizePity(uint256 id) internal {
        Box storage b = boxes[id];
        uint256 r = randomness.randomOf(address(this), id);
        uint8 rar = _roll(b.tier, uint16(r % 10_000));
        bool pity;
        uint16 su = sinceUR[b.agent] + 1; uint16 ss = sinceSSR[b.agent] + 1;
        if (rar < 4 && su >= PITY_UR) { rar = 4; pity = true; }
        else if (rar < 3 && ss >= PITY_SSR) { rar = 3; pity = true; }
        sinceUR[b.agent] = rar == 4 ? 0 : su; sinceSSR[b.agent] = rar >= 3 ? 0 : ss;
        rolledRarity[id] = rar; rarityReady[id] = true;
        emit PityFinalized(id, b.agent, rar, pity);
    }
    function _open(uint256 id, bool strict) internal returns (uint256 gearId) {
        Box storage b = boxes[id];
        if (b.buyer != msg.sender) revert NotBuyer();
        if (b.opened) revert AlreadyOpened();
        if (!randomness.isReady(address(this), id)) revert NotReady();
        if (noPity[id]) return _mintRoll(id, _roll(b.tier, uint16(randomness.randomOf(address(this), id) % 10_000)), false, false);
        if (!pityExcluded[id] && !rarityReady[id]) _materialize(b.agent, MAX_PITY_STEPS);
        if (pityExcluded[id]) return _mintRoll(id, _roll(b.tier, uint16(randomness.randomOf(address(this), id) % 10_000)), false, true);
        if (!rarityReady[id]) { if (strict) revert PityPending(); return 0; }
        uint256 r = randomness.randomOf(address(this), id);
        uint8 natural = _roll(b.tier, uint16(r % 10_000));
        return _mintRoll(id, rolledRarity[id], rolledRarity[id] != natural, true);
    }
    /// hero = false for shard boxes (noPity). Excluded and normal purchases still roll the hero drop.
    function _mintRoll(uint256 id, uint8 rar, bool pity, bool hero) internal returns (uint256 gearId) {
        Box storage b = boxes[id];
        b.opened = true;
        uint256 r = randomness.randomOf(address(this), id);
        gearId = 100 + (r >> 64) % 4 * 20 + (r >> 32) % 4 * 5 + rar;
        _mint(msg.sender, gearId, 1, "");
        emit BoxOpened(id, gearId, rar, pity);
        if (hero && !b.wl) _heroDrop(id, b.tier, r);
    }
    // --- SPECIAL HERO DROP (2026-10-30 final): every PURCHASED box (not whitelist, not shard-redeemed) also rolls, from the same
    // VRF word, a low-odds bonus hero: Common 0.1% / Premium 0.3% / Seasonal 1%. Hero: 80% Elite (f01-f10, 8% each),
    // 20% Mythic (e01-e05, 4% each). Legend l01/l02 never drop (Forge only). Official heroes never drop. Capped hero => no drop.
    uint32[3] public heroDropPpm = [uint32(1000), 3000, 10_000];
    uint32 public constant MAX_HERO_DROP_PPM = 20_000; // hard ceiling 2%
    event HeroDropped(uint256 indexed boxId, address indexed to, uint256 robotId, uint256 charIdx);
    event HeroDropOdds(uint8 tier, uint32 ppm);
    function setHeroDropPpm(uint8 tier, uint32 ppm) external onlyOwner { if (tier > 2 || ppm > MAX_HERO_DROP_PPM) revert BadOdds(); heroDropPpm[tier] = ppm; emit HeroDropOdds(tier, ppm); }
    function heroDropOf(uint8 tier, uint256 r) public view returns (bool hit, uint256 c) {
        hit = (r >> 96) % 1_000_000 < heroDropPpm[tier]; uint256 w = (r >> 128) % 100;
        c = w < 80 ? 35 + w / 8 : 30 + (w - 80) / 4;
    }
    function _heroDrop(uint256 boxId, uint8 tier, uint256 r) internal {
        (bool hit, uint256 c) = heroDropOf(tier, r); if (!hit || address(robots) == address(0)) return;
        try robots.mintSpecial(msg.sender, c, false) returns (uint256 rid) { if (rid != 0) emit HeroDropped(boxId, msg.sender, rid, c); }
        catch {} // robots paused / minter not set: the gear result stands, no hero (never blocks opening)
    }
    function _roll(uint8 tier, uint16 x) internal view returns (uint8) {
        for (uint8 i; i < 5; i++) if (x < odds[tier][i]) return i;
        return 4;
    }

    // --- equipment panel ---
    function equip(uint256 robotId, uint256 gearId) external whenNotPaused { _equip(robotId, gearId); }
    /// @notice Equip several items on one robot in one tx (one per slot; later ones replace earlier in the same slot).
    function equipMany(uint256 robotId, uint256[] calldata gearIds) external whenNotPaused {
        if (gearIds.length == 0 || gearIds.length > 4) revert BadQty();
        for (uint256 i; i < gearIds.length; i++) _equip(robotId, gearIds[i]);
    }
    function _equip(uint256 robotId, uint256 gearId) internal {
        if (robots.ownerOf(robotId) != msg.sender) revert NotRobotOwner();
        if (gearId < 100 || gearId > 179) revert BadSlot(); uint8 slot = uint8((gearId - 100) % 20 / 5);
        address prev = equippedBy[robotId];
        if (prev != address(0) && prev != msg.sender) _clear(robotId, prev); // robot changed hands: release old owner's gear
        uint256 cur = equippedPlus1[robotId][slot];
        if (cur != 0) { locked[msg.sender][cur - 1]--; emit Unequipped(robotId, slot, cur - 1); }
        if (balanceOf(msg.sender, gearId) <= locked[msg.sender][gearId]) revert NoGear();
        locked[msg.sender][gearId]++; equippedPlus1[robotId][slot] = gearId + 1; equippedBy[robotId] = msg.sender;
        emit Equipped(robotId, slot, gearId);
    }
    function unequip(uint256 robotId, uint8 slot) external {
        if (slot > 3) revert BadSlot();
        address holder = equippedBy[robotId];
        if (msg.sender != holder && robots.ownerOf(robotId) != msg.sender) revert NotRobotOwner();
        uint256 cur = equippedPlus1[robotId][slot]; if (cur == 0) revert NoGear();
        locked[holder][cur - 1]--; equippedPlus1[robotId][slot] = 0; emit Unequipped(robotId, slot, cur - 1);
    }
    function _clear(uint256 robotId, address holder) internal {
        for (uint8 s; s < 4; s++) { uint256 c = equippedPlus1[robotId][s]; if (c != 0) { locked[holder][c - 1]--; equippedPlus1[robotId][s] = 0; emit Unequipped(robotId, s, c - 1); } }
    }
    /// @notice Gear only counts while the robot's current owner is the one who equipped it.
    function equipped(uint256 robotId) external view returns (uint256[4] memory ids) {
        bool live = equippedBy[robotId] == robots.ownerOf(robotId);
        for (uint8 s; s < 4; s++) { uint256 c = equippedPlus1[robotId][s]; ids[s] = (live && c != 0) ? c - 1 : type(uint256).max; }
    }
    /// @notice Packed: bits 0-31 bps (items + 2pc + affinity, capped +20%; + Sovereign 100% exempt), bit 32 Sovereign flag,
    /// bits 33-35 4-piece set id (1..4), bits 36-38 UR weapon passive id (1..4), bits 48-63 set power bps (Arena matchmaking). Set effects only while the equipper holds the robot.
    function gearPowerBps(uint256 robotId) external view returns (uint256 p) { uint256 f;
        address o = robots.ownerOf(robotId);
        if (equippedBy[robotId] == o) {
            uint256 n; uint256 w = 9; // n = 4x4-bit piece counts per set; w = weapon's set (9 = none)
            for (uint8 s; s < 4; s++) { uint256 c = equippedPlus1[robotId][s]; if (c != 0) { c -= 101; p += POWER_BPS[c % 5]; n += 1 << (c / 20 * 4);
                if (s == 0) { w = c / 20; if (c % 5 == 4) f = (w + 1) << 36; } } } // UR weapon passive id (bits 36-38)
            for (uint256 k; k < 4; k++) { uint256 m = n >> (k * 4) & 15; if (m >= 2) p += 200; if (m == 4) f |= (k + 1) << 33; } // 2pc +2%, 4pc id (bits 33-35)
            if (w < 4 && arena != address(0) && AFFINITY >> (IGearArena(arena).charOf(robotId) * 2) & 3 == w) p += 100; // weapon affinity +1%
            if (p > GEAR_POWER_CAP_BPS) p = GEAR_POWER_CAP_BPS;
            p |= f; if (f != 0) p |= (uint256(uint8(FX_POWER[(f >> 33 & 7) * 2])) << 8 | uint8(FX_POWER[(f >> 33 & 7) * 2 + 1])
                + (uint256(uint8(FX_POWER[(f >> 36 & 7) * 2 + 10])) << 8 | uint8(FX_POWER[(f >> 36 & 7) * 2 + 11]))) << 48; // set power bps (matchmaking)
        }
        if (robotId != 0 && robotId == officialSetRobot && robots.ownerOf(robotId) == officialSetHolder) p += OFFICIAL_SET_BPS + ALL_STATS_FLAG; // cap-exempt; flag = +100% DEF & SPD too
    }

    // --- transfers: Agent ID wallets only; locked (equipped) gear can't move ---
    function _update(address from, address to, uint256[] memory ids, uint256[] memory vals) internal override {
        for (uint256 i; i < ids.length; i++) if (ids[i] == OFFICIAL_SET_ID && from != address(0)) revert Soulbound(); // no transfer, no burn
        if (from != address(0)) {
            for (uint256 i; i < ids.length; i++) if (balanceOf(from, ids[i]) < locked[from][ids[i]] + vals[i]) revert Locked();
        }
        if (to != address(0) && from != address(0) && !openToWallets) { (bool ok,) = eligibility.agentKey(to, ""); if (!ok) revert RecipientNotAgent(to); }
        super._update(from, to, ids, vals);
    }

    // --- OFFICIAL SET: exactly one, owner-granted once, soulbound, not in boxes/forge/shards/dismantle ---
    // Public & on-chain: anyone can see who holds it and which robot wears it. +100% hp/atk (BattleSim scales hp & atk only),
    // exempt from the +20% gear cap; it is counted in arena power, so power brackets match it against strong teams.
    uint256 public constant OFFICIAL_SET_ID = 200; uint16 public constant OFFICIAL_SET_BPS = 10_000; uint256 public constant ALL_STATS_FLAG = 1 << 32; // Sovereign Set: +100% HP/ATK/DEF/SPD
    bool public officialSetMinted; address public officialSetHolder; uint256 public officialSetRobot; // 0 = not worn
    event OfficialSetGranted(address indexed to); event OfficialSetWorn(uint256 indexed robotId);
    error AlreadyMinted(); error Soulbound();
    function grantOfficialSet(address to) external onlyOwner {
        if (officialSetMinted) revert AlreadyMinted(); if (to == address(0)) revert ZeroAddress();
        officialSetMinted = true; officialSetHolder = to; _mint(to, OFFICIAL_SET_ID, 1, ""); emit OfficialSetGranted(to);
    }
    /// @notice Holder puts the set on one of their robots (0 = take off).
    function wearOfficialSet(uint256 robotId) external {
        if (msg.sender != officialSetHolder) revert NoGear();
        if (robotId != 0 && robots.ownerOf(robotId) != msg.sender) revert NotRobotOwner();
        officialSetRobot = robotId; emit OfficialSetWorn(robotId);
    }

    // Hero weapon affinity (2 bits per char index 0..46, roster order): 0 blade 1 gun 2 cannon 3 staff = set whose weapon fits.
    uint256 public constant AFFINITY = 0x311f13334e3ac5f426a62389;
    /// Matchmaking power bps for set effects (uint16 BE): [none, 4pc 1..4][none, UR 1..4]; agent/gear_power_derive.mjs (exact sim).
    bytes public constant FX_POWER = hex"0000003e00400037004a0000005100540050003a";
    address public arena; // Arena.charOf source for affinity (0 = affinity off)
    function setArena(address a) external onlyOwner { arena = a; }
    // --- FORGE hooks (AgentWorldForge only). Same account key for Agent IDs and manual wallets. ---
    address public forge; mapping(uint256 => bool) public noPity;
    error NotForge();
    function setForge(address f) external onlyOwner { forge = f; }
    /// @notice Account key used for limits/shards: Agent ID key if the wallet holds one, else keccak("wallet", addr).
    function accountKey(address a) external view returns (bytes32) { return _agent(a); }
    function forgeBurn(address from, uint256 gearId, uint256 n) external { if (msg.sender != forge) revert NotForge(); _burn(from, gearId, n); }
    function forgeMint(address to, uint256 gearId) external { if (msg.sender != forge) revert NotForge(); _mint(to, gearId, 1, ""); }
    function forgeRedeemBox(address buyer, bytes32 a, uint8 tier) external returns (uint256 id) {
        if (msg.sender != forge) revert NotForge(); if (tier > 1) revert BadTier();
        id = ++boxCount; boxes[id] = Box(a, buyer, tier, false, false); noPity[id] = true; // not in _pityQ
        randomness.register(id); emit BoxBought(id, a, tier, 0, 0);
    }

    // --- pools / admin ---
    /// @notice Daily pool -> poolSink (e.g. the lottery); season pool -> seasonSink. Never mixed.
    function flushPools() external nonReentrant {
        uint256 d = dailyPoolWei; uint256 s = seasonPoolWei; dailyPoolWei = 0; seasonPoolWei = 0;
        _send(poolSink, d); _send(seasonSink == address(0) ? poolSink : seasonSink, s);
    }
    address public seasonSink; // 0 = legacy (same as poolSink); set before pointing poolSink at the lottery
    function setSeasonSink(address t) external { _directSet("seasonSink", t); } // setup only; afterwards proposeAddress("seasonSink")
    function _send(address to, uint256 v) internal { if (v == 0) return; (bool s,) = payable(to).call{value: v}(""); if (!s) revert TransferFailed(); }
    function setPrice(uint8 tier, uint256 w) external onlyOwner { if (tier > 2) revert BadTier(); if (w < MIN_PRICE || w > MAX_PRICE) revert BadPrice(); priceWei[tier] = w; }
    event DailyBoxLimit(uint8 tier, uint256 n);
    function setDailyBoxLimit(uint8 tier, uint256 n) external onlyOwner { if (tier > 2) revert BadTier(); if (n == 0) revert WrongValue(); dailyBoxLimit[tier] = n; emit DailyBoxLimit(tier, n); }
    function setSeasonal(bool o, uint256 sid) external onlyOwner { seasonalOpen = o; seasonId = sid; }
    function setWhitelistRoot(bytes32 r) external onlyOwner { wlCampaign++; wlRoot = r; emit WhitelistRootSet(wlCampaign, r); }
    function setWhitelistFee(uint256 w) external onlyOwner { if (w < 0.0001 ether || w > 0.005 ether) revert BadPrice(); wlFeeWei = w; }
    function setTreasury(address t) external { _directSet("treasury", t); } // setup only; afterwards 48h timelock
    function setPoolSink(address t) external { _directSet("poolSink", t); } // setup only; afterwards 48h timelock
    function _tlAuth() internal view override { _checkOwner(); }
    function _tlGet(bytes32 k) internal view override returns (address) {
        if (k == "treasury") return treasury; if (k == "poolSink") return poolSink; if (k == "seasonSink") return seasonSink; revert BadKey();
    }
    function _tlSet(bytes32 k, address a) internal override {
        if (k == "treasury") treasury = a; else if (k == "poolSink") poolSink = a; else if (k == "seasonSink") seasonSink = a; else revert BadKey();
    }
    function setURI(string calldata u) external onlyOwner { _setURI(u); }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}

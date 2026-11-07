// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAgentEligibility} from "./IAgentEligibility.sol";
import {EpochRandomness} from "./EpochRandomness.sol";
import {BattleSim} from "./BattleSim.sol";

interface IArenaRobots { function ownerOf(uint256 id) external view returns (address); function metadataIndex(uint256 id) external view returns (uint256); function specialCharOf(uint256 id) external view returns (uint8); function craftLocked(uint256 id) external view returns (bool); function seasonCharOf(uint256 id) external view returns (uint16); }
interface IAgentWorldTierTable { function unitOf(uint256 i) external view returns (uint8, uint8); function multOf(uint256 i) external view returns (uint8, uint8, uint256); }
interface IArenaGear { function gearPowerBps(uint256 robotId) external view returns (uint256); }

/// @title Agent World arena (DRAFT, unaudited)
/// @notice Plain-call battles, identical for an Agent wallet (CLI) and a human wallet (web UI): no signatures, no
/// off-chain step. enter() pays a BNB entry fee and queues a 3-robot team; the next entrant is paired with it and the
/// match is registered in the open VRF epoch. After the epoch seed, ANYONE may settle(); the winner's reward is credited
/// and pulled with claim(). Dev takes DEV_BPS of every fee up front (dev never loses). No daily payout cap, no daily match limit (user decision 2026-10-29).
contract AgentWorldArena is Ownable, Pausable, ReentrancyGuard {
    uint16 public constant DEV_BPS = 3000;
    uint256 public constant OFFICIAL_START = 10_001; uint256 public constant OFFICIAL_END = 10_010;
    IAgentEligibility public eligibility; EpochRandomness public randomness; IArenaRobots public robots; IArenaGear public gear;
    address public treasury; address public poolSink;
    uint256 public entryFeeWei;            // ~0.5U
    // NOCAP 2026-10-29: no daily payout cap and no daily match limit (user decision). Winner gets the full pot.
    uint256 public seasonPoolWei;          // NOCAP: no longer funded by the arena (kept for ABI compatibility; stays 0)
    
    struct Match { bytes32 agentA; bytes32 agentB; address walletA; address walletB; uint256[3] teamA; uint256[3] teamB;
        uint64 createdAt; uint8 state; /*0 waiting 1 paired 2 settled 3 cancelled*/ uint8 winner; /*1=A 2=B*/ uint256 prize; }
    mapping(uint256 => Match) internal _m; uint256 public matchCount;
    // POWER (2026-10-29): teams of 1-3 robots, matched only within the same power bracket (size-agnostic).
    mapping(uint256 => uint256) public bracketOf;        // match id => bracket
    mapping(uint256 => uint256[3][2]) internal _snapG;   // match id => side => per-slot gear bps snapshotted at entry
    IAgentWorldTierTable public tierTable;              // per-token archetype + frame tier (0 = legacy mapping)
    mapping(bytes32 => uint256[]) internal _byAgent;
    mapping(address => uint256) public pending;                          // claimable BNB
    mapping(bytes32 => mapping(uint256 => uint256)) public entriesOnDay;

    event Entered(uint256 indexed matchId, bytes32 indexed agent, address wallet, uint256[3] team);
    event Paired(uint256 indexed matchId, uint256 epoch);
    event Settled(uint256 indexed matchId, uint8 winner, uint256 prize, uint256 toSeason);
    /// @notice Exact simulation inputs used at settlement (replay reads this so it always matches the result).
    event BattleInputs(uint256 indexed matchId, uint256[6] chars, uint256[6] gearBps, uint256 seed);
    event Claimed(address indexed wallet, uint256 amount);
    event Cancelled(uint256 indexed matchId);
    error NotAgent(); error NotOwnerOfRobot(); error DuplicateRobot(); error TwoOfficials(); error WrongValue();
    error NotReady(); error BadState(); error NotYours(); error TooEarly(); error Nothing();
    error TransferFailed(); error ZeroAddress(); error SelfMatch(); error BadTeam(); error CraftPending();
    error NotLottery();

    constructor(address treasury_, address sink_, IAgentEligibility e, EpochRandomness r, IArenaRobots rb, IArenaGear g,
        uint256 fee, uint256 dailyCap) Ownable(msg.sender) {
        if (treasury_ == address(0) || sink_ == address(0)) revert ZeroAddress();
        treasury = treasury_; poolSink = sink_; eligibility = e; randomness = r; robots = rb; gear = g;
        entryFeeWei = fee; dailyCap; // NOCAP: arg kept so deploy scripts keep working; ignored
    }

    // ---------------- CONTINUOUS MATCHMAKING (2026-10-29 23:4x, user decisions) ----------------
    // Play any time, no round/battle caps. enter() puts an entry in the OPEN epoch of a dedicated arena EpochRandomness
    // (minInterval ~60-90s = batch window). The keeper closes the batch with requestSeed() as soon as it has >=1 entry and
    // the window passed; VRF seed is unknown at entry time (anti-sniping). After the seed anyone calls resolve(epoch,maxSteps):
    // the whole batch is shuffled (Fisher-Yates from the seed); entries are grouped by (fee band, bracket with a per-batch
    // RANDOM boundary offset - anti edge-sitting) and paired in shuffled order. Humans always pair with humans first.
    // Leftovers: if the entrant allowed it, a HOUSE BOT (bankroll-funded) fights it, else full refund.
    // House bot power = player's team power x houseEdgeBps (public, shown by quoteEntry) => house wins ~60% by the
    // same deterministic battle rules; Sovereign/edge teams face proportionally stronger bots.
    struct Entry { bytes32 agent; address wallet; uint256[3] team; uint256[3] snap; uint64 epoch; uint64 day; uint32 bracket; uint8 state; /*0 queued 1 paired 2 refunded*/ uint256 fee; uint256 power; bool allowHouse; uint64 at; }
    mapping(uint256 => Entry) internal _e; uint256 public entryCount;
    mapping(uint256 => uint256[]) internal _batch;                        // epoch => entry ids
    mapping(uint256 => uint256) public batchLeft;                         // not yet drawn (0 after init+drain)
    mapping(uint256 => bool) public batchInit; mapping(uint256 => bool) public batchDone;
    mapping(uint256 => uint256) public roundSeed;                         // epoch => seed
    mapping(uint256 => mapping(uint256 => uint256)) public waitingIn;      // epoch => group key => entry id
    mapping(uint256 => uint256[]) internal _waitKeys;
    mapping(uint256 => uint256) internal _leftCursor;
    mapping(uint256 => uint256) public matchSeed;                        // match id => battle seed
    mapping(uint256 => uint256[2]) public entriesOfMatch;
    mapping(uint256 => uint256[3]) internal _botChar; mapping(uint256 => uint256[3]) internal _botBps; // house side of a bot match
    mapping(bytes32 => uint256[]) internal _entriesBy;
    function entriesOfAgent(bytes32 a) external view returns (uint256[] memory) { return _entriesBy[a]; }
    /// @notice Match id an entry ended up in (0 = none yet / refunded).
    mapping(uint256 => uint256) public matchOfEntry;
    mapping(uint256 => bool) public isHouseMatch; mapping(uint256 => bool) public houseIsA;
    address public constant HOUSE = address(0x40005E); bytes32 public constant HOUSE_KEY = keccak256("AgentWorld.HouseBot");
    uint256 public houseBankroll; uint256 public houseEdgeBps = 10_300; /* calibrated: house wins ~60% (sim) */ bool public houseOn = true;
    uint256 internal constant ENTRY_BASE = 1 << 200;
    uint64 public refundAfter = 1 hours;                                 // seed never arrived
    uint16[6] public feeLadderBps = [uint16(10000), 15000, 20000, 30000, 40000, 60000];
    uint256 public bracketsPerBand = 4;
    event Queued(uint256 indexed entryId, bytes32 indexed agent, address wallet, uint256[3] team, uint256 bracket, uint256 epoch, uint256 fee, bool allowHouse);
    event Refunded(uint256 indexed entryId, uint256 amount);
    event HouseMatch(uint256 indexed matchId, uint256 indexed entryId, uint256 botPower, uint256[3] chars, uint256[3] bps);
    event HouseFunded(uint256 amount, uint256 bankroll);

    function feeOfBracket(uint256 b) public view returns (uint256) {
        uint256 band = b / bracketsPerBand; if (band > 5) band = 5; return entryFeeWei * feeLadderBps[band] / 10_000;
    }
    /// @notice What enter(team) costs w now, and the House Bot power it would face if no human is available.
    function quoteEntry(uint256[3] calldata team, address w) external view returns (uint256 power, uint256 bracket, uint256 fee) {
        (power, bracket) = teamPower(team, w); fee = feeOfBracket(bracket);
    }
    function houseBotPower(uint256 power) public view returns (uint256) { return power * houseEdgeBps / 10_000; }

    /// @notice Queue a 1-3 robot team (allowHouse = accept a House Bot, power x houseEdgeBps, if no human is found).
    function enter(uint256[3] calldata team, bool allowHouse) external payable nonReentrant whenNotPaused returns (uint256 id) {
        (bool ok, bytes32 a) = eligibility.agentKey(msg.sender, "");
        if (!ok) { if (!openToWallets) revert NotAgent(); a = keccak256(abi.encode("wallet", msg.sender)); }
        for (uint256 i; i < 3; i++) if (team[i] != 0) _light(msg.sender, team[i]); // codex: lit from the fielded team
        id = ++entryCount; Entry storage e = _e[id];
        { (uint256 bracket, uint256[3] memory snap, uint256 p) = _checkTeam(team);
          e.fee = feeOfBracket(bracket); e.snap = snap; e.power = p; e.bracket = uint32(bracket); }
        if (msg.value != e.fee) revert WrongValue();
        uint256 ep = randomness.register(ENTRY_BASE + id);
        e.agent = a; e.wallet = msg.sender; e.team = team; e.epoch = uint64(ep); e.day = uint64(block.timestamp / 1 days);
        e.allowHouse = allowHouse; e.at = uint64(block.timestamp);
        _batch[ep].push(id); _entriesBy[a].push(id);
        emit Queued(id, a, msg.sender, team, e.bracket, ep, e.fee, allowHouse);
    }
    /// @notice Entrant may cancel (full refund) while its batch is still open (seed not requested => nothing revealed).
    function cancel(uint256 x) external nonReentrant {
        Entry storage e = _e[x]; if (e.wallet != msg.sender) revert NotYours(); if (e.state != 0) revert BadState();
        if (e.epoch != randomness.currentEpoch()) revert TooEarly();
        e.state = 2; pending[e.wallet] += e.fee; emit Refunded(x, e.fee); // stays in _batch; skipped at resolve
    }
    /// @notice Group key = fee band (fixed) x bracket with a per-batch random boundary offset (anti edge-sitting).
    function groupOf(uint256 p, uint32 fixedBracket, uint256 seed) public view returns (uint256) {
        uint256 band = fixedBracket / bracketsPerBand; uint256 r = bracketRatioBps; if (!bracketsEnabled || r == 0) return band << 32; // OFF (launch default): random pairing across all power inside the fee tier
        uint256 u = uint256(keccak256(abi.encode(seed, "offset"))) % 10_000;
        uint256 t = 1000 + 1000 * (r - 10_000) / 10_000 * u / 10_000; uint256 b; // first boundary shifted by u in [0,1) step
        while (p >= t) { t = t * r / 10_000; b++; }
        return (band << 32) | b;
    }
    /// @notice Anyone, after the batch seed: process up to maxSteps entries (results identical however it is chunked).
    function resolve(uint256 epoch, uint256 maxSteps) external nonReentrant whenNotPaused returns (uint256 made) {
        uint256[] storage pl = _batch[epoch]; if (pl.length == 0 || batchDone[epoch]) revert Nothing();
        if (!batchInit[epoch]) {
            if (!randomness.isReady(address(this), ENTRY_BASE + pl[0])) revert NotReady();
            batchInit[epoch] = true; batchLeft[epoch] = pl.length;
            roundSeed[epoch] = randomness.randomOf(address(this), ENTRY_BASE + pl[0]);
        }
        uint256 seed = roundSeed[epoch]; uint256 n = batchLeft[epoch]; uint256 steps;
        while (steps < maxSteps && n > 0) {
            steps++; uint256 x = _draw(pl, seed, n--);
            Entry storage ex = _e[x]; if (ex.state != 0) continue;
            uint256 k = groupOf(ex.power, ex.bracket, seed); uint256 w = waitingIn[epoch][k];
            if (w == 0) { waitingIn[epoch][k] = x; _waitKeys[epoch].push(k); continue; }
            waitingIn[epoch][k] = 0;
            if (_e[w].agent == ex.agent) { _refund(w); _refund(x); continue; } // never fight yourself
            _pair(w, x, seed); made++;
        }
        batchLeft[epoch] = n;
        if (n == 0) { // leftovers: House Bot (if allowed + bankroll) else refund
            uint256[] storage ks = _waitKeys[epoch]; uint256 i = _leftCursor[epoch];
            for (; i < ks.length && steps < maxSteps; i++) {
                steps++; uint256 x = waitingIn[epoch][ks[i]]; if (x == 0 || _e[x].state != 0) continue;
                waitingIn[epoch][ks[i]] = 0;
                if (houseOn && _e[x].allowHouse && houseBankroll >= _e[x].fee) { _pairHouse(x, seed); made++; } else _refund(x);
            }
            _leftCursor[epoch] = i; if (i == ks.length) batchDone[epoch] = true;
        }
    }
    function _draw(uint256[] storage pl, uint256 seed, uint256 n) internal returns (uint256 v) {
        uint256 i = uint256(keccak256(abi.encode(seed, n))) % n; v = pl[i]; pl[i] = pl[n - 1]; pl[n - 1] = v;
    }
    function _refund(uint256 x) internal { Entry storage e = _e[x]; e.state = 2; pending[e.wallet] += e.fee; emit Refunded(x, e.fee); }
    function _newMatch(Entry storage ex, uint256 x) internal returns (uint256 id, Match storage m) {
        ex.state = 1; id = ++matchCount; m = _m[id];
        m.agentA = ex.agent; m.walletA = ex.wallet; m.teamA = ex.team; m.createdAt = uint64(block.timestamp); m.state = 1;
        _snapG[id][0] = ex.snap; bracketOf[id] = ex.bracket; entriesOfMatch[id][0] = x; matchOfEntry[x] = id; _byAgent[ex.agent].push(id);
    }
    function _pair(uint256 x, uint256 y, uint256 seed) internal {
        Entry storage ex = _e[x]; Entry storage ey = _e[y]; (uint256 id, Match storage m) = _newMatch(ex, x);
        ey.state = 1; m.agentB = ey.agent; m.walletB = ey.wallet; m.teamB = ey.team; _snapG[id][1] = ey.snap; entriesOfMatch[id][1] = y; matchOfEntry[y] = id;
        matchSeed[id] = uint256(keccak256(abi.encode(seed, id))); _byAgent[ey.agent].push(id);
        uint256 tot = ex.fee + ey.fee; uint256 dev = tot * DEV_BPS / 10_000; m.prize = tot - dev;
        _count(ex.agent, ex.wallet, ex.day, ex.fee); _count(ey.agent, ey.wallet, ey.day, ey.fee);
        _send(treasury, dev); emit Paired(id, ex.epoch);
    }
    /// House Bot: mirror of the player's team (same robots, same Sovereign flag), every unit's hp & atk x sqrt(houseEdgeBps),
    /// so bot power = player power x houseEdgeBps exactly (public rule, same BattleSim, no RNG bias).
    function _pairHouse(uint256 x, uint256 seed) internal {
        Entry storage ex = _e[x]; (uint256 id, Match storage m) = _newMatch(ex, x);
        m.agentB = HOUSE_KEY; m.walletB = HOUSE; isHouseMatch[id] = true;
        uint256 rs = uint256(keccak256(abi.encode(seed, id, "house"))); matchSeed[id] = uint256(keccak256(abi.encode(seed, id)));
        uint256 sq = _sqrt(houseEdgeBps * 10_000); uint256[3] memory c; uint256[3] memory g; // MIRROR team, each unit x sqrt(edge) on hp&atk
        for (uint256 i; i < 3; i++) {
            if (ex.team[i] == 0) { c[i] = BattleSim.EMPTY; continue; }
            c[i] = charOf(ex.team[i]); uint256 ub = unitBps(ex.team[i], ex.snap[i]);
            g[i] = ((10_000 + (ub & 0xffffffff)) * sq / 10_000 - 10_000) | (ub >> 32 << 32); // mirror incl. player's codex bonus; keeps Sovereign flag
        }
        if (rs & 1 == 1) { // seeded coin flip: bot is side A (acts first on speed ties) half the time
            houseIsA[id] = true; m.agentB = ex.agent; m.walletB = ex.wallet; m.teamB = ex.team; _snapG[id][1] = ex.snap;
            m.agentA = HOUSE_KEY; m.walletA = HOUSE; delete m.teamA; delete _snapG[id][0];
        }
        _botChar[id] = c; _botBps[id] = g;
        uint256 cut = ex.fee * DEV_BPS / 10_000; m.prize = 2 * (ex.fee - cut); uint256 dev = cut; // winner 0.7 of each side
        houseBankroll -= ex.fee - cut; // house side's 30% cut stays in the bankroll (self-funding); player's 30% -> treasury
        _count(ex.agent, ex.wallet, ex.day, ex.fee); // House battles count toward the player's 10 (user default)
        _send(treasury, dev); emit Paired(id, ex.epoch); emit HouseMatch(id, x, houseBotPower(ex.power), c, g);
    }
    function _sqrt(uint256 a) internal pure returns (uint256 z) { if (a == 0) return 0; z = a; uint256 y = (a + 1) / 2; while (y < z) { z = y; y = (a / y + y) / 2; } }
    /// @notice 2026-11-04: treasury (the bankroll funder) may fund directly; owner kept for ops. Adds funds only.
    function fundHouse() external payable { if (msg.sender != owner() && msg.sender != treasury) revert NotYours(); houseBankroll += msg.value; emit HouseFunded(msg.value, houseBankroll); }
    function withdrawHouse(uint256 v) external onlyOwner nonReentrant { houseBankroll -= v; _send(treasury, v); }
    function setHouse(bool on, uint256 edgeBps) external onlyOwner { if (edgeBps < 10_000 || edgeBps > 13_000) revert WrongValue(); houseOn = on; houseEdgeBps = edgeBps; }
    function botTeam(uint256 id) external view returns (uint256[3] memory chars, uint256[3] memory bps) { return (_botChar[id], _botBps[id]); }
    /// LOTTERY: only paired battles count (refunded entries never do).
    /// A frozen day ignores later resolves. Cutoff is the lottery commit, which is before that day's seed exists.
    function _count(bytes32 a, address w, uint256 day, uint256 fee) internal {
        if (dayFrozen[day]) return;
        revenueOnDay[day] += fee;
        if (++entriesOnDay[a][day] == LOTTERY_BATTLES) { _eligible[day].push(a); eligibleWallet[day][a] = w; }
    }
    /// @notice Entry owner: refund if its batch seed has not arrived within refundAfter.
    function refundStale(uint256 x) external nonReentrant {
        Entry storage e = _e[x]; if (e.wallet != msg.sender) revert NotYours(); if (e.state != 0) revert BadState();
        if (randomness.isReady(address(this), ENTRY_BASE + x)) revert TooEarly();
        if (block.timestamp < uint256(e.at) + refundAfter) revert TooEarly();
        _refund(x);
    }
    function getEntry(uint256 x) external view returns (Entry memory) { return _e[x]; }
    function batchOf(uint256 epoch) external view returns (uint256[] memory) { return _batch[epoch]; }

    /// @notice Anyone may settle a paired match; the winner gets the pot fixed at pairing (30% dev already paid).
    function settle(uint256 id) public nonReentrant whenNotPaused {
        Match storage m = _m[id]; if (m.state != 1) revert BadState();
        uint256 r = matchSeed[id];
        (uint256[6] memory c, uint256[6] memory g) = _units(id);
        (uint8 w,,) = BattleSim.runLinked(c, g, r);
        emit BattleInputs(id, c, g, r);
        bool aWins = w == 0;
        m.winner = aWins ? 1 : 2; m.state = 2;
        address wn = aWins ? m.walletA : m.walletB; if (wn == HOUSE) houseBankroll += m.prize; else pending[wn] += m.prize;
        emit Settled(id, m.winner, m.prize, 0);
    }
    /// @notice Settle any paired matches then withdraw everything owed to msg.sender (one call for agents).
    function settleAndClaim(uint256[] calldata ids) external returns (uint256 amt) {
        for (uint256 i; i < ids.length; i++) if (_m[ids[i]].state == 1) settle(ids[i]);
        if (pending[msg.sender] > 0) amt = _claim();
    }
    function claim() external returns (uint256) { return _claim(); }
    function _claim() internal nonReentrant returns (uint256 amt) {
        amt = pending[msg.sender]; if (amt == 0) revert Nothing(); pending[msg.sender] = 0;
        _send(msg.sender, amt); emit Claimed(msg.sender, amt);
    }
    function setFeeLadder(uint16[6] calldata l, uint256 perBand) external onlyOwner {
        if (perBand == 0) revert WrongValue();
        for (uint256 i; i < 6; i++) if (l[i] < 10_000 || l[i] > 100_000 || (i > 0 && l[i] < l[i - 1])) revert WrongValue();
        feeLadderBps = l; bracketsPerBand = perBand;
    }

    /// @notice Character index (0..46, battle_ui/roster.js order: 0..9 official o01..o10, 10..29 base robots r01..r20).
    function charOf(uint256 id) public view returns (uint256) {
        if (id >= OFFICIAL_START && id <= OFFICIAL_END) return id - OFFICIAL_START;
        if (id >= SPECIAL_START) { uint256 sc = robots.specialCharOf(id); if (sc == 0) revert BadTeam(); return sc; } // special heroes 30..46
        if (address(tierTable) != address(0)) { (uint8 rb,) = tierTable.unitOf(robots.metadataIndex(id)); return 10 + rb; }
        return 10 + (robots.metadataIndex(id) - 1) % 37; // legacy (tier table not set)
    }
    /// @notice Frame-tier power multiplier (bps). Official heroes have their own (strongest) stats: 1.0x.
    function tierMultOf(uint256 id) public view returns (uint256) {
        if ((id >= OFFICIAL_START && id <= OFFICIAL_END) || id >= SPECIAL_START || address(tierTable) == address(0)) return 10_000; // official + special: own stats
        (,, uint256 mb) = tierTable.multOf(robots.metadataIndex(id)); return mb;
    }
    /// @notice Combined bonus fed to BattleSim (hp & atk x (1+bps)): tier multiplier x (1 + gear, capped +20% in Gear).
    /// gearBps layout: bits 0-31 gear bps, bit 32 Sovereign flag, bits 33-38 gear v2 4pc/UR ids, bits 48-63 set power bps
    /// (matchmaking only, from Gear), bits 64+ codex bps (wallet's codex level at entry).
    function unitBps(uint256 id, uint256 gearBps) public view returns (uint256) {
        return (tierMultOf(id) * (10_000 + (gearBps & 0xffffffff)) / 10_000 * (10_000 + (gearBps >> 64)) / 10_000 - 10_000) | gearBps & 0xffffffff00000000; // keep bits 32-63: Sovereign flag + gear v2 set/UR ids + set power
    }
    // ---------- CODEX (2026-10-30, final: CURRENT HOLDING). A hero kind counts only while the wallet still holds the
    // token that lit it (or another of that kind re-lit via lightCodex). Selling / transferring / burning (incl. craft burn)
    // unlights it automatically: points are always computed live from ownership. The value at Arena entry is snapshotted
    // for that battle and used for matchmaking power AND the House Bot mirror (same number), so a borrowed hero helps at
    // most the battles entered while holding it.
    // Points: N-LR regular 1, Elite 2, Mythic 3, Legend 5, Official 5, Genesis frame 3, season kinds set once (1-5).
    // Bonus (ATK & HP, whole fielded team): >=5 pts +1%, >=12 +2%, >=20 +3% (all 20 regular), >=45 +4%, >=80 +5% (max).
    uint256 public constant GENESIS_KIND = 255;
    mapping(address => uint256) public codexWord;                       // lit kinds (bit k), may include stale bits
    mapping(address => mapping(uint256 => uint256)) public codexToken;  // kind => proof token id
    mapping(uint256 => uint8) public seasonKindPoints;
    event CodexLit(address indexed w, uint256 kind, uint256 tokenId);
    function kindPoints(uint256 k) public view returns (uint256) {
        if (k < 10 || k == 45 || k == 46) return 5; if (k < 30) return 1; if (k < 35) return 3; if (k < 45) return 2;
        return k == GENESIS_KIND ? 3 : seasonKindPoints[k];
    }
    function setSeasonKindPoints(uint256 k, uint8 pts) external onlyOwner { if (k < 47 || k >= GENESIS_KIND || pts == 0 || pts > 5 || seasonKindPoints[k] != 0) revert WrongValue(); seasonKindPoints[k] = pts; }
    /// @notice True while w holds the proof token of kind k.
    function codexLit(address w, uint256 k) public view returns (bool) {
        if (codexWord[w] >> k & 1 == 0) return false;
        try robots.ownerOf(codexToken[w][k]) returns (address o) { return o == w; } catch { return false; }
    }
    function codexPoints(address w) public view returns (uint256 p) {
        uint256 x = codexWord[w]; for (uint256 k; x != 0; k++) { if (x & 1 == 1 && codexLit(w, k)) p += kindPoints(k); x >>= 1; }
    }
    function codexBps(address w) public view returns (uint256) {
        uint256 p = codexPoints(w); return p >= 80 ? 500 : p >= 45 ? 400 : p >= 20 ? 300 : p >= 12 ? 200 : p >= 5 ? 100 : 0;
    }
    /// @notice Anyone: (re)light kinds from tokens w holds now. Kinds whose proof token left w simply stop counting.
    function lightCodex(address w, uint256[] calldata ids) external { for (uint256 i; i < ids.length; i++) _light(w, ids[i]); }
    function _light(address w, uint256 id) internal {
        if (robots.ownerOf(id) != w) revert NotOwnerOfRobot();
        uint256 k; if (id >= 1_000_000) k = robots.seasonCharOf(id); else k = charOf(id);
        _lit(w, k, id);
        if (k >= 10 && k < 30 && address(tierTable) != address(0)) { (, uint8 t,) = tierTable.multOf(robots.metadataIndex(id)); if (t == 7) _lit(w, GENESIS_KIND, id); }
    }
    function _lit(address w, uint256 k, uint256 id) internal {
        if (k > 255 || kindPoints(k) == 0 || codexLit(w, k)) return; // season kind without points yet: light later
        codexWord[w] |= 1 << k; codexToken[w][k] = id; emit CodexLit(w, k, id);
    }
    /// @notice Unit power = hp*atk*(300+def)/30000 (effective HP x attack) scaled by (1+bps)^2. Team power = sum.
    /// Speed only changes turn order (every unit acts once per round), so it is not in the rating.
    function unitPower(uint256 id, uint256 gearBps) public view returns (uint256) {
        uint256 ch = charOf(id); (uint256 hp, uint256 atk, uint256 def,) = BattleSim.stats(ch);
        uint256 ub = unitBps(id, gearBps); uint256 mm = 10_000 + (ub & 0xffffffff); if (ub & 1 << 32 != 0) def *= 2;
        hp = hp * atk * (300 + def) / 30_000 * mm / 10_000 * mm / 10_000 * skillPowerBps(ch) / 10_000 * (10_000 + (ub >> 48 & 0xffff)) / 10_000; // skill + gear v2 set/UR priced in
        return ub & 1 << 32 != 0 ? hp * SOVEREIGN_CRESCENT_POWER_BPS / 10_000 : hp; // Crescent ult priced in (sim: agent/sovereign_power_derive.mjs)
    }
    uint256 public constant SOVEREIGN_CRESCENT_POWER_BPS = 18_000;
    uint256 public constant SPECIAL_START = 20_001;
    /// @notice Signature-skill power factor per character (bps, uint16 BE), derived by agent/skill_power_derive.mjs:
    /// 3x hero with its skill vs 3x same hero on the old universal kit, hp&atk scale at 50% wins, squared.
    bytes internal constant SKILL_POWER = hex"27742bc02b5c2c24290429042a9426ac2a9429cc307026482904290427d82260238c2580271022603a3422c427d827d8283c26ac27d822c429cc277426ac28a02bc027d82774277426ac25e426ac27d829cc277427742db427d828a02c88";
    function skillPowerBps(uint256 c) public pure returns (uint256) { bytes memory s = SKILL_POWER; return uint256(uint8(s[c * 2])) << 8 | uint8(s[c * 2 + 1]); }
    /// @notice Bracket = number of x(bracketRatioBps) steps above 1000 power (0 for <1000). Only equal brackets are paired.
    function bracketOfPower(uint256 p) public view returns (uint256 b) {
        uint256 r = bracketRatioBps; if (r == 0) return 0; // 0 = single open queue (e.g. low population)
        uint256 t = 1000; while (p >= t) { t = t * r / 10_000; b++; }
    }
    uint256 public bracketRatioBps = 13_000;
    /// @notice Launch default OFF: pairing ignores power brackets (fee tier only). ON = bracket + random-offset grouping.
    bool public bracketsEnabled;
    event BracketsEnabled(bool on);
    function setBracketsEnabled(bool on) external onlyOwner { bracketsEnabled = on; emit BracketsEnabled(on); }
    /// @notice 0 = one queue for everyone; otherwise bracket width ratio (>= 1.1x, <= 3x).
    function setBracketRatio(uint256 r) external onlyOwner { if (r != 0 && (r < 11_000 || r > 30_000)) revert WrongValue(); bracketRatioBps = r; }
    function teamPower(uint256[3] calldata team, address w) public view returns (uint256 p, uint256 bracket) {
        for (uint256 i; i < 3; i++) if (team[i] != 0) p += unitPower(team[i], _gearOf(team[i], w));
        bracket = bracketOfPower(p);
    }
    function _checkTeam(uint256[3] calldata team) internal view returns (uint256 bracket, uint256[3] memory snap, uint256 p) {
        if (team[0] == 0 || (team[1] == 0 && team[2] != 0)) revert BadTeam(); // 1-3 robots, empties (0) at the end
        uint256 off; uint256 cb = codexBps(msg.sender);
        for (uint256 i; i < 3; i++) {
            if (team[i] == 0) continue;
            if (robots.ownerOf(team[i]) != msg.sender) revert NotOwnerOfRobot();
            if (robots.craftLocked(team[i])) revert CraftPending(); // input of a pending Forge craft
            for (uint256 j; j < i; j++) if (team[j] == team[i]) revert DuplicateRobot();
            if (team[i] >= OFFICIAL_START && team[i] <= OFFICIAL_END) off++;
            snap[i] = gear.gearPowerBps(team[i]) | cb << 64; p += unitPower(team[i], snap[i]);
        }
        if (off > 1) revert TwoOfficials();
        bracket = bracketOfPower(p);
    }
    /// @notice Gear bonus snapshotted at entry; counts only if the robot is still held by the entrant at settle.
    /// Burned tokens make ownerOf revert. That is "not held": the character still fights and gear is removed,
    /// which is the same rule as a transfer. Settlement must still pay.
    function _held(uint256 id, address w) internal view returns (bool held) {
        (bool ok, bytes memory data) = address(robots).staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
        if (!ok || data.length < 32) return false;
        held = abi.decode(data, (address)) == w;
    }
    function _gearOf(uint256 id, address w) internal view returns (uint256) { return (_held(id, w) ? gear.gearPowerBps(id) : 0) | codexBps(w) << 64; }
    function _units(uint256 mid) internal view returns (uint256[6] memory c, uint256[6] memory g) {
        Match storage m = _m[mid];
        for (uint256 i; i < 3; i++) {
            (c[i], g[i]) = _slot(m.teamA[i], m.walletA, _snapG[mid][0][i]);
            if (!isHouseMatch[mid]) { (c[i + 3], g[i + 3]) = _slot(m.teamB[i], m.walletB, _snapG[mid][1][i]); continue; }
            uint256 h = houseIsA[mid] ? i : i + 3; uint256 pl = houseIsA[mid] ? i + 3 : i;
            c[h] = _botChar[mid][i]; g[h] = c[h] == BattleSim.EMPTY ? 0 : _botBps[mid][i];
            (c[pl], g[pl]) = houseIsA[mid] ? _slot(m.teamB[i], m.walletB, _snapG[mid][1][i]) : _slot(m.teamA[i], m.walletA, _snapG[mid][0][i]);
        }
    }
    function _slot(uint256 id, address w, uint256 snap) internal view returns (uint256 c, uint256 g) {
        if (id == 0) return (BattleSim.EMPTY, 0);
        c = charOf(id); g = unitBps(id, _held(id, w) ? snap : snap >> 64 << 64); // codex bonus stays, gear needs the robot held
    }
    /// @notice Inputs the replay needs to reproduce a match exactly (chars, gear, seed). Ownership is read live:
    /// a transfer or a burn removes the gear bonus and does not revert. Call it in the settle block for that view.
    function battleInputs(uint256 id) external view returns (uint256[6] memory c, uint256[6] memory g) { return _units(id); }
    /// @notice Pure preview of the shared algorithm (used by replay cross-checks and agents).
    function simulate(uint256[6] calldata c, uint256[6] calldata g, uint256 seed) external pure returns (uint8 winner, uint256 rounds, uint256 actions) {
        return BattleSim.runLinked(c, g, seed);
    }
    function charStats(uint256 c) external pure returns (uint256 hp, uint256 atk, uint256 def, uint256 spd) { return BattleSim.stats(c); }

    // --- public views (no wallet needed) ---
    function getMatch(uint256 id) external view returns (Match memory) { return _m[id]; }
    function matchesOfAgent(bytes32 agent) external view returns (uint256[] memory) { return _byAgent[agent]; }
    /// @notice Player key: Agent ID key, or keccak("wallet", addr) for a manual wallet.
    function agentKeyOf(address w) external view returns (bool ok, bytes32 key) {
        (ok, key) = eligibility.agentKey(w, ""); if (!ok) key = keccak256(abi.encode("wallet", w));
    }
    // --- LOTTERY hooks (read by AgentWorldLottery; identical for Agent IDs and wallets) ---
    uint256 public constant LOTTERY_BATTLES = 10;
    mapping(uint256 => uint256) public revenueOnDay;
    mapping(uint256 => bytes32[]) internal _eligible;
    mapping(uint256 => mapping(bytes32 => address)) public eligibleWallet; // wallet that played the 10th battle
    mapping(uint256 => bool) public dayFrozen;
    address public lottery;
    event DayFrozen(uint256 indexed day);
    function eligibleCount(uint256 day) external view returns (uint256) { return _eligible[day].length; }
    function eligibleAt(uint256 day, uint256 i) external view returns (bytes32 key, address wallet) { key = _eligible[day][i]; wallet = eligibleWallet[day][key]; }
    function setLottery(address a) external onlyOwner { if (a == address(0)) revert ZeroAddress(); lottery = a; }
    /// @notice Lottery commit. O(1). Later resolves no longer change this day's revenue or eligible list.
    function freezeDay(uint256 day) external {
        if (msg.sender != lottery) revert NotLottery();
        dayFrozen[day] = true; emit DayFrozen(day);
    }
    bool public openToWallets = true;
    function setOpenToWallets(bool on) external onlyOwner { openToWallets = on; }
    function setTierTable(IAgentWorldTierTable t) external onlyOwner { tierTable = t; }


    function _send(address to, uint256 v) internal { if (v == 0) return; (bool s,) = payable(to).call{value: v}(""); if (!s) revert TransferFailed(); }
    function flushSeason() external nonReentrant { uint256 v = seasonPoolWei; seasonPoolWei = 0; _send(poolSink, v); }
    function setFee(uint256 w) external onlyOwner { if (w < 0.0001 ether || w > 0.05 ether) revert WrongValue(); entryFeeWei = w; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}

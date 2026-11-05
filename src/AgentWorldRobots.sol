// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IAgentEligibility} from "./IAgentEligibility.sol";
import {EpochRandomness} from "./EpochRandomness.sol";
import {AddressTimelock} from "./AddressTimelock.sol";

/// @title Agent World base robots (DRAFT, unaudited)
/// @notice 10,000 cap. Only Binance Agent ID wallets (SPACE ID registry) can mint. First mint per Agent ID free,
/// further mints paid in native BNB (owner-settable price within hard bounds). No ERC20 / USDT anywhere.
/// Metadata order is fixed off-chain (provenance hash) and shifted by a random offset set once at reveal.
contract AgentWorldRobots is ERC721, Ownable, Pausable, ReentrancyGuard, AddressTimelock {
    uint256 public constant MAX_SUPPLY = 10_000;
    uint256 public constant MAX_PER_TX = 20;
    uint256 public constant MIN_PRICE = 0.001 ether;  // hard floor (~0.7 USD at 740 USD/BNB)
    uint256 public constant MAX_PRICE = 0.05 ether;   // hard ceiling (~37 USD at 740 USD/BNB)
    uint256 public mintPriceWei;                       // default 0.00675 BNB ~= 5 USD (CoinGecko 740.86 USD/BNB, 2026-10-29)
    uint256 public constant MIN_FREE_FEE = 0.0001 ether; // ~0.07 USD
    uint256 public constant MAX_FREE_FEE = 0.005 ether;  // ~3.7 USD
    /// @notice Fee for the one-per-Agent-ID "free" mint (VRF/ops pass-through). 100% to treasury, never to prize pools.
    uint256 public freeMintFeeWei = 0.000675 ether;      // ~0.5 USD at 740.86 USD/BNB (2026-10-29)
    /// @notice Official heroes ("Beacon"): hard cap 10 ever, tokenIds 10001..10010, owner-minted, no payment.
    uint256 public constant OFFICIAL_SUPPLY = 10;
    uint256 public constant OFFICIAL_ID_START = MAX_SUPPLY + 1; // 10001
    uint256 public officialMinted;
    bytes32 public immutable provenance;
    /// @notice Manual (non-Agent-ID) wallets may paid-mint, hold and play. They get everything (whitelist included) EXCEPT the
    /// one-time free mint, which stays Agent-ID-only. Owner kill switch; default on.
    bool public openToWallets = true;
    event OpenToWalletsSet(bool on);
    address public treasury;
    IAgentEligibility public eligibility;
    address public fusion;              // future fusion contract allowed to burn with holder approval
    uint256 public totalMinted; uint256 public totalBurned; uint256 public freeMinted;
    bool public freeOpen; bool public paidOpen;
    mapping(bytes32 => bool) public agentClaimed;
    /// @notice Cached Agent verification per wallet, bound to the eligibility module that verified it
    /// (needed for Merkle mode, where a proof is required and cannot be supplied on a plain transfer).
    mapping(address => address) public verifiedUnder;
    /// @notice Owner-managed allowlist of official contracts (game / fusion / league escrow) that may receive robots.
    mapping(address => bool) public transferAllowlist;
    string private baseURI; string private hiddenURI;
    EpochRandomness public randomness; uint256 public constant REVEAL_ID = 0; bool public revealCommitted;
    uint256 public offset; bool public revealed;

    event AgentClaimed(address indexed to, bytes32 indexed agentKey, uint256 tokenId);
    event Paid(address indexed to, uint256 qty, uint256 amount);
    event PriceSet(uint256 wei_);
    event FreeMintFeeSet(uint256 oldWei, uint256 newWei);
    event FreeMintFeePaid(address indexed payer, address indexed treasury, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event Funded(address indexed from, uint256 amount);
    error SoldOut(); error NotOpen(); error NotAgent(); error AlreadyClaimed(); error BadQty(); error NotFusion(); error RevealState(); error CraftLocked();
    event AgentVerified(address indexed account, address indexed module);
    event TransferAllowlistSet(address indexed account, bool allowed);
    error RecipientNotAgent(address to);
    error OfficialCap(); error OfficialProtected();
    event OfficialMinted(address indexed to, uint256 indexed tokenId);
    error BadPrice(); error Underpaid(); error TransferFailed(); error ZeroAddress(); error WrongFee();

    // --- Whitelist (events / partnerships) ---
    uint256 public constant WL_SUPPLY = 500;       // global cap across all campaigns
    uint256 public constant WL_PER_AGENT = 20;     // per Agent ID cap across all campaigns
    uint256 public wlMinted;
    uint256 public wlFeeWei = 0.000675 ether;      // per item, ~0.5U, 100% to treasury (covers VRF/gas)
    bytes32 public wlRoot; uint256 public wlCampaign; // root rotates per campaign; campaign id bumps on every set
    mapping(bytes32 => uint256) public wlClaimedByAgent;                       // agentKey => total
    mapping(uint256 => mapping(bytes32 => uint256)) public wlClaimedInCampaign; // campaign => agentKey => n
    event WhitelistRootSet(uint256 indexed campaign, bytes32 root);
    event WhitelistClaimed(address indexed to, bytes32 indexed agentKey, uint256 indexed campaign, uint256 qty);
    event WhitelistFeeSet(uint256 oldWei, uint256 newWei);
    error WlCap(); error WlAgentCap(); error WlAllocation(); error WlProof();

    constructor(uint256 priceWei, address treasury_, IAgentEligibility e, bytes32 prov, string memory hidden)
        ERC721("Agent World Robots", "AWR") Ownable(msg.sender) {
        if (priceWei < MIN_PRICE || priceWei > MAX_PRICE) revert BadPrice();
        if (treasury_ == address(0)) revert ZeroAddress();
        mintPriceWei = priceWei; treasury = treasury_; eligibility = e; provenance = prov; hiddenURI = hidden;
    }

    // --- mint ---
    /// @notice One mint per Agent ID for exactly freeMintFeeWei (sent straight to treasury). Wrong amount reverts.
    function claimFree(bytes calldata proof) external payable nonReentrant whenNotPaused returns (uint256 id) {
        if (!freeOpen) revert NotOpen();
        if (msg.value != freeMintFeeWei) revert WrongFee();
        (bool ok, bytes32 key) = eligibility.agentKey(msg.sender, proof);
        if (!ok) revert NotAgent();
        _cacheVerified(msg.sender);
        if (agentClaimed[key]) revert AlreadyClaimed();
        agentClaimed[key] = true; freeMinted++;
        id = _mintNext(msg.sender);
        emit AgentClaimed(msg.sender, key, id);
        _sendBNB(treasury, msg.value);
        emit FreeMintFeePaid(msg.sender, treasury, msg.value);
    }
    // --- X GIVEAWAY (2026-10-29): up to 100 VRF-drawn addresses get 2 free-mint credits each (manual wallets and Agent IDs
    // identical: credits are per ADDRESS). Each credit still pays freeMintFeeWei (~0.5U). Stacks with the Agent-ID free mint.
    // Flow: owner publishes the entrant list off-chain and commits its Merkle root (leaf = keccak(bytes.concat(keccak(abi.encode(index, addr)))))
    // + size BEFORE the seed; after the VRF seed anyone draws (sparse Fisher-Yates, no repeats) and anyone grants a winner's
    // credits with its Merkle proof. Nobody (owner included) can pick winners after seeing the seed.
    uint256 public constant GIFT_MAX_WINNERS = 100; uint256 public constant GIFT_CREDITS = 2; uint256 internal constant GIFT_BASE = 1 << 128;
    struct Giveaway { bytes32 root; uint32 size; uint32 winners; bool drawn; }
    mapping(uint256 => Giveaway) public giveaways; uint256 public giveawayCount;
    mapping(uint256 => mapping(uint256 => uint256)) internal _gSwap;          // sparse Fisher-Yates
    mapping(uint256 => uint256[]) internal _gWinIdx;                           // campaign => drawn list indices
    mapping(uint256 => mapping(uint256 => bool)) public giftGranted;           // campaign => winner slot => granted
    mapping(address => uint256) public giftCredits; uint256 public giftMinted;
    event GiveawayCommitted(uint256 indexed c, bytes32 root, uint256 size, uint256 winners);
    event GiveawayDrawn(uint256 indexed c, uint256[] indices); event GiftGranted(uint256 indexed c, address indexed to, uint256 credits);
    event GiftMinted(address indexed to, uint256 indexed id);
    error GiftState(); error GiftProof();
    /// @notice winners = min(100, size). If size <= 100 EVERY eligible entrant wins (no VRF needed: drawn immediately).
    function commitGiveaway(bytes32 root, uint32 size) external onlyOwner returns (uint256 c) {
        if (root == bytes32(0) || size == 0) revert GiftState();
        uint32 winners = size < GIFT_MAX_WINNERS ? size : uint32(GIFT_MAX_WINNERS); bool all = size <= GIFT_MAX_WINNERS;
        c = ++giveawayCount; giveaways[c] = Giveaway(root, size, winners, all);
        if (!all) { if (address(randomness) == address(0)) revert GiftState(); randomness.register(GIFT_BASE + c); }
        emit GiveawayCommitted(c, root, size, winners);
    }
    function drawGiveaway(uint256 c) external {
        Giveaway storage g = giveaways[c]; if (g.root == bytes32(0) || g.drawn) revert GiftState();
        uint256 seed = randomness.randomOf(address(this), GIFT_BASE + c); // reverts until the seed exists
        uint256 n = g.size; uint256[] storage out = _gWinIdx[c];
        for (uint256 k; k < g.winners; k++) {
            uint256 j = k + uint256(keccak256(abi.encode(seed, k))) % (n - k);
            uint256 vj = _gSwap[c][j]; vj = vj == 0 ? j + 1 : vj; uint256 vk = _gSwap[c][k]; vk = vk == 0 ? k + 1 : vk;
            _gSwap[c][j] = vk; out.push(vj - 1);
        }
        g.drawn = true; emit GiveawayDrawn(c, out);
    }
    function giveawayWinners(uint256 c) external view returns (uint256[] memory) { return _gWinIdx[c]; }
    /// @notice Anyone: grant winner slot k (list index _gWinIdx[c][k]; or index k itself when everyone wins) its 2 credits, proving the address at that index.
    function grantGift(uint256 c, uint256 k, address to, bytes32[] calldata proof) external {
        Giveaway storage g = giveaways[c]; bool all = g.size <= GIFT_MAX_WINNERS;
        if (!g.drawn || k >= (all ? g.size : _gWinIdx[c].length) || giftGranted[c][k]) revert GiftState();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(all ? k : _gWinIdx[c][k], to))));
        if (!MerkleProof.verifyCalldata(proof, giveaways[c].root, leaf)) revert GiftProof();
        giftGranted[c][k] = true; giftCredits[to] += GIFT_CREDITS; emit GiftGranted(c, to, GIFT_CREDITS);
    }
    /// @notice Use one giveaway credit: mint 1 robot for exactly freeMintFeeWei (to treasury). Same for every wallet type.
    function mintGift() external payable nonReentrant whenNotPaused returns (uint256 id) {
        if (!freeOpen) revert NotOpen(); if (msg.value != freeMintFeeWei) revert WrongFee();
        if (giftCredits[msg.sender] == 0) revert GiftState();
        giftCredits[msg.sender]--; giftMinted++; id = _mintNext(msg.sender); emit GiftMinted(msg.sender, id);
        _sendBNB(treasury, msg.value); emit FreeMintFeePaid(msg.sender, treasury, msg.value);
    }
    /// @notice Player key for a manual (non-Agent-ID) wallet; same formula as Gear/Arena.
    function walletKey(address w) public pure returns (bytes32) { return keccak256(abi.encode("wallet", w)); }
    /// @notice Whitelist claim. Leaf = keccak256(bytes.concat(keccak256(abi.encode(campaign, key, allocation)))),
    /// key = Agent ID key, or walletKey(addr) for a manual wallet (identical caps: 20 per key, 500 global). Pays exactly wlFeeWei*qty to treasury; no pool contribution.
    function claimWhitelist(uint256 qty, uint256 allocation, bytes32[] calldata wlProof, bytes calldata agentProof)
        external payable nonReentrant whenNotPaused {
        if (wlRoot == bytes32(0)) revert NotOpen();
        if (qty == 0 || qty > WL_PER_AGENT) revert BadQty();
        if (msg.value != wlFeeWei * qty) revert WrongFee();
        (bool ok, bytes32 key) = eligibility.agentKey(msg.sender, agentProof);
        if (ok) _cacheVerified(msg.sender);
        else if (!openToWallets) revert NotAgent();
        else key = walletKey(msg.sender); // manual wallet: same 20 cap, keyed per wallet
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(wlCampaign, key, allocation))));
        if (!MerkleProof.verifyCalldata(wlProof, wlRoot, leaf)) revert WlProof();
        if (wlClaimedInCampaign[wlCampaign][key] + qty > allocation) revert WlAllocation();
        if (wlClaimedByAgent[key] + qty > WL_PER_AGENT) revert WlAgentCap();
        if (wlMinted + qty > WL_SUPPLY) revert WlCap();
        wlClaimedInCampaign[wlCampaign][key] += qty; wlClaimedByAgent[key] += qty; wlMinted += qty;
        for (uint256 i; i < qty; i++) _mintNext(msg.sender);
        emit WhitelistClaimed(msg.sender, key, wlCampaign, qty);
        _sendBNB(treasury, msg.value);
    }
    /// @notice Set/rotate the campaign root. Bumps campaign id, so old proofs stop working. bytes32(0) closes it.
    function setWhitelistRoot(bytes32 r) external onlyOwner { wlCampaign++; wlRoot = r; emit WhitelistRootSet(wlCampaign, r); }
    function setWhitelistFee(uint256 w) external onlyOwner {
        if (w < MIN_FREE_FEE || w > MAX_FREE_FEE) revert BadPrice(); emit WhitelistFeeSet(wlFeeWei, w); wlFeeWei = w;
    }
    /// @notice Paid mint in BNB. Caller must hold an Agent ID. Excess msg.value is refunded.
    function mint(uint256 qty, bytes calldata proof) external payable nonReentrant whenNotPaused {
        if (!paidOpen) revert NotOpen();
        if (qty == 0 || qty > MAX_PER_TX) revert BadQty();
        if (totalMinted + qty > MAX_SUPPLY) revert SoldOut();
        (bool ok,) = eligibility.agentKey(msg.sender, proof);
        if (ok) _cacheVerified(msg.sender);
        else if (!openToWallets) revert NotAgent(); // manual wallets: paid mint only, never free
        uint256 amt = mintPriceWei * qty;
        if (msg.value < amt) revert Underpaid();
        // effects
        for (uint256 i; i < qty; i++) _mintNext(msg.sender);
        emit Paid(msg.sender, qty, amt);
        // interactions
        uint256 refund = msg.value - amt;
        if (refund > 0) _sendBNB(msg.sender, refund);
    }
    /// @notice Owner mints official heroes to an Agent ID wallet (or allowlisted contract). Not a free claim, no fee.
    function mintOfficial(address to, uint256 n) external onlyOwner nonReentrant {
        if (n == 0 || officialMinted + n > OFFICIAL_SUPPLY) revert OfficialCap();
        if (to == address(0)) revert ZeroAddress();
        if (!canReceive(to)) revert RecipientNotAgent(to);
        for (uint256 i; i < n; i++) { uint256 id = OFFICIAL_ID_START + officialMinted++; _mint(to, id); emit OfficialMinted(to, id); }
    }
    // --- SPECIAL HEROES (2026-10-30 final): the 17 non-mint heroes e01-e05 / f01-f10 / l01-l02 (BattleSim chars 30..46).
    // Minted ONLY by allowlisted game contracts: AgentWorldGear (low-odds blind-box drop, e/f only) and AgentWorldForge
    // (crafting / upgrade path; l01-l02 are forge-only). Token ids 20001+. Hard cap per hero: Elite f 200, Mythic e 80, Legend l 25.
    // Frame: f = Elite, e = Mythic, l = Legend; an e/f hero crafted in the Forge carries the Fusion frame (cosmetic, same stats).
    uint256 public constant SPECIAL_ID_START = 20_001;
    uint256 public specialCount;
    mapping(uint256 => uint8) public specialCharOf;   // token id => BattleSim character index (30..46), 0 = not special
    mapping(uint256 => bool) public specialCrafted;   // true = minted by the Forge (Fusion frame)
    mapping(uint256 => uint256) public specialMintedOf; // char => minted so far
    mapping(address => bool) public specialMinter;
    event SpecialMinterSet(address indexed m, bool on);
    event SpecialMinted(address indexed to, uint256 indexed id, uint256 indexed charIdx, bool crafted);
    function specialCap(uint256 c) public pure returns (uint256) { return c >= 45 ? 25 : (c >= 35 ? 200 : 80); }
    // Forge crafting (VRF, 2026-10-30): a pending craft reserves one cap slot (released on failure) and locks its hero
    // inputs in place until settle, so a success can never exceed the cap and escrowed inputs cannot move.
    mapping(uint256 => uint256) public specialReserved; mapping(uint256 => bool) public craftLocked;
    function craftHold(uint256 c, bool reserve) external {
        if (msg.sender != fusion) revert NotFusion();
        if (!reserve) { specialReserved[c]--; return; }
        if (specialMintedOf[c] + specialReserved[c] >= specialCap(c)) revert SoldOut(); // c validated by the Forge
        specialReserved[c]++;
    }
    function craftLock(uint256 id, bool on) external { if (msg.sender != fusion) revert NotFusion(); craftLocked[id] = on; }
    function setSpecialMinter(address m, bool on) external onlyOwner { if (m == address(0)) revert ZeroAddress(); specialMinter[m] = on; emit SpecialMinterSet(m, on); }
    /// @notice Game contracts only. Returns 0 (mints nothing) when that hero's cap is reached.
    function mintSpecial(address to, uint256 c, bool crafted) external nonReentrant whenNotPaused returns (uint256 id) {
        if (!specialMinter[msg.sender]) revert NotFusion();
        if (c < 30 || c > 46 || to == address(0)) revert BadQty();
        if (crafted && msg.sender == fusion) { if (specialReserved[c] == 0) revert BadQty(); specialReserved[c]--; } // Forge: slot reserved at request
        else if (specialMintedOf[c] + specialReserved[c] >= specialCap(c)) return 0;
        specialMintedOf[c]++; id = SPECIAL_ID_START + specialCount++;
        specialCharOf[id] = uint8(c); specialCrafted[id] = crafted || c >= 45;
        _mint(to, id); emit SpecialMinted(to, id, c, crafted);
    }
    // --- SEASON EXPANSION (2026-10-30): future seasons may add NEW heroes with their own fixed caps. OFF at launch.
    // Season s (1..) uses token ids s*SEASON_SPAN+1 .. s*SEASON_SPAN+total (disjoint from base 1..10000, official
    // 10001..10010, special 20001..22450 and from every other season by construction). Hero (char) ids are appended
    // contiguously after the last existing hero (base set ends at char 46), so they can never overlap either.
    // A season is added only via propose -> 48h -> execute, and once executed its caps can never change (no setter).
    // Existing caps (MAX_SUPPLY, OFFICIAL_SUPPLY, specialCap) are constants / pure and unaffected.
    uint256 public constant SEASON_SPAN = 1_000_000; uint256 public constant SEASON_DELAY = 48 hours;
    uint256 public constant SEASON_MAX_HEROES = 64; uint256 public constant SEASON_MAX_CAP = 10_000;
    struct Season { uint16 firstChar; uint16 numChars; uint32 capPerChar; uint64 eta; }
    bool public seasonsEnabled; uint256 public seasonCount; Season public pendingSeason; uint256 public nextSeasonChar = 47;
    mapping(uint256 => Season) public seasons;                 // season => fixed params (immutable once executed)
    mapping(uint256 => uint256) public seasonMintedOf;         // char => minted so far
    mapping(uint256 => uint256) public seasonCountOf;          // season => minted so far (token id offset)
    mapping(uint256 => uint16) public seasonCharOf;            // token id => char (0 = not a season token)
    event SeasonsEnabledSet(bool on); event SeasonProposed(uint256 firstChar, uint256 numChars, uint256 capPerChar, uint256 eta);
    event SeasonAdded(uint256 indexed season, uint256 firstChar, uint256 numChars, uint256 capPerChar); event SeasonCancelled();
    event SeasonMinted(address indexed to, uint256 indexed id, uint256 indexed charIdx);
    error SeasonsOff(); error SeasonParams(); error SeasonTimelock();
    function setSeasonsEnabled(bool on) external onlyOwner { seasonsEnabled = on; emit SeasonsEnabledSet(on); }
    function proposeSeason(uint16 numChars, uint32 capPerChar) external onlyOwner {
        if (numChars == 0 || numChars > SEASON_MAX_HEROES || capPerChar == 0 || capPerChar > SEASON_MAX_CAP
            || uint256(numChars) * capPerChar >= SEASON_SPAN || pendingSeason.eta != 0) revert SeasonParams();
        uint64 eta = uint64(block.timestamp + SEASON_DELAY);
        pendingSeason = Season(uint16(nextSeasonChar), numChars, capPerChar, eta); emit SeasonProposed(nextSeasonChar, numChars, capPerChar, eta);
    }
    function cancelSeason() external onlyOwner { if (pendingSeason.eta == 0) revert NoProposal(); delete pendingSeason; emit SeasonCancelled(); }
    function executeSeason() external onlyOwner returns (uint256 s) {
        Season memory p = pendingSeason; if (p.eta == 0) revert NoProposal(); if (block.timestamp < p.eta) revert SeasonTimelock();
        delete pendingSeason; s = ++seasonCount; seasons[s] = p; nextSeasonChar = p.firstChar + p.numChars;
        emit SeasonAdded(s, p.firstChar, p.numChars, p.capPerChar);
    }
    /// @notice Game contracts only, and only while seasonsEnabled. Returns 0 when that hero's fixed cap is reached.
    function mintSeason(address to, uint256 s, uint256 c) external nonReentrant whenNotPaused returns (uint256 id) {
        if (!seasonsEnabled) revert SeasonsOff(); if (!specialMinter[msg.sender]) revert NotFusion();
        Season memory x = seasons[s]; if (to == address(0) || x.numChars == 0 || c < x.firstChar || c >= x.firstChar + x.numChars) revert SeasonParams();
        if (seasonMintedOf[c] >= x.capPerChar) return 0;
        seasonMintedOf[c]++; id = s * SEASON_SPAN + ++seasonCountOf[s]; seasonCharOf[id] = uint16(c);
        _mint(to, id); emit SeasonMinted(to, id, c);
    }
    function isSpecial(uint256 id) public view returns (bool) { return specialCharOf[id] != 0; }
    /// @notice 0 Elite, 1 Mythic, 2 Fusion, 3 Legend (reverts for non-special ids).
    function specialFrame(uint256 id) public view returns (uint8) {
        uint256 c = specialCharOf[id]; if (c == 0) revert BadQty();
        if (c >= 45) return 3; if (specialCrafted[id]) return 2; return c >= 35 ? 0 : 1;
    }
    function isOfficial(uint256 id) public pure returns (bool) { return id >= OFFICIAL_ID_START && id < OFFICIAL_ID_START + OFFICIAL_SUPPLY; }
    function _sendBNB(address to, uint256 v) internal { (bool s,) = payable(to).call{value: v}(""); if (!s) revert TransferFailed(); }
    /// @notice Accepts BNB top-ups (e.g. reward pool funding). All rewards are paid in BNB.
    receive() external payable { emit Funded(msg.sender, msg.value); }
    function _mintNext(address to) internal returns (uint256 id) {
        if (totalMinted >= MAX_SUPPLY) revert SoldOut();
        id = ++totalMinted; _mint(to, id); // plain _mint: never blocks smart-contract / AI wallets lacking onERC721Received
    }

    // --- Agent-only transfers ---
    /// @notice Register a wallet as a verified Agent (for Merkle mode, so it can receive transfers). Anyone may call
    /// for any account; the proof must be valid for that account under the current eligibility module.
    function verifyAgent(address account, bytes calldata proof) external {
        (bool ok,) = eligibility.agentKey(account, proof);
        if (!ok) revert NotAgent();
        _cacheVerified(account);
    }
    function _cacheVerified(address a) internal {
        if (verifiedUnder[a] != address(eligibility)) { verifiedUnder[a] = address(eligibility); emit AgentVerified(a, address(eligibility)); }
    }
    /// @notice True if `to` may receive a robot via transfer: allowlisted official contract, live Agent ID check
    /// with empty proof (SPACE ID mode), or cached verification under the current module (Merkle mode).
    function canReceive(address to) public view returns (bool) {
        if (transferAllowlist[to] || openToWallets) return true;
        if (address(eligibility) == address(0)) return false;
        bool cached = verifiedUnder[to] == address(eligibility);
        // Fail closed: any lookup error (registry down, bad module) means "cannot receive".
        if (cached) {
            try eligibility.requiresProof() returns (bool rp) { if (rp) return true; } catch { return false; }
        }
        try eligibility.agentKey(to, "") returns (bool ok, bytes32) { return ok; } catch { return false; }
    }
    /// @dev Mints already require Agent ID; burns (fusion) always allowed; wallet-to-wallet transfers need an Agent recipient.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && !isOfficial(tokenId) && !canReceive(to)) revert RecipientNotAgent(to); // officials: freely tradeable (2026-10-30, permanent)
        if (craftLocked[tokenId] && to != address(0)) revert CraftLocked(); // escrowed in a pending craft
        return super._update(to, tokenId, auth);
    }

    // --- burn hooks for fusion ---
    /// @notice Holder burns own token.
    function burn(uint256 id) external { _update(address(0), id, msg.sender); totalBurned++; }
    /// @notice Fusion contract burns inputs; holder must have approved the fusion contract (checked by _update auth).
    function fusionBurn(uint256 id) external {
        if (msg.sender != fusion) revert NotFusion();
        if (isOfficial(id)) revert OfficialProtected();
        bool l = craftLocked[id]; if (l) delete craftLocked[id]; // escrowed craft input: approval was checked at lock time
        _update(address(0), id, l ? address(0) : msg.sender); totalBurned++;
    }

    // --- randomness: VRF epoch seed (commit-before-seed) ---
    /// @notice Register the reveal in the open randomness epoch. The seed is requested afterwards, so the offset
    /// cannot be chosen after it is known. Replaces the old blockhash reveal.
    function commitReveal() external onlyOwner whenNotPaused {
        if (revealed || revealCommitted || address(randomness) == address(0)) revert RevealState();
        revealCommitted = true; randomness.register(REVEAL_ID);
    }
    function reveal() external whenNotPaused {
        if (revealed || !revealCommitted) revert RevealState();
        offset = randomness.randomOf(address(this), REVEAL_ID) % MAX_SUPPLY; revealed = true; // reverts until seed ready
    }
    function setRandomness(EpochRandomness r) external onlyOwner { if (revealCommitted) revert RevealState(); randomness = r; }
    function metadataIndex(uint256 id) public view returns (uint256) { return ((id - 1 + offset) % MAX_SUPPLY) + 1; }
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        if (isOfficial(id)) return string.concat(baseURI, "official/", Strings.toString(id - MAX_SUPPLY));
        if (isSpecial(id)) return string.concat(baseURI, "special/", Strings.toString(id));
        if (seasonCharOf[id] != 0) return string.concat(baseURI, "season/", Strings.toString(id));
        if (!revealed) return hiddenURI;
        return string.concat(baseURI, Strings.toString(metadataIndex(id)));
    }

    // --- public views for agents and the web UI (no wallet needed) ---
    /// @notice Robot ids held by `a` (scans minted range + official heroes; eth_call only).
    function tokensOf(address a) external view returns (uint256[] memory ids) {
        uint256 n = balanceOf(a); ids = new uint256[](n); uint256 k;
        for (uint256 i = 1; i <= totalMinted && k < n; i++) if (_ownerOf(i) == a) ids[k++] = i;
        for (uint256 i = OFFICIAL_ID_START; i < OFFICIAL_ID_START + officialMinted && k < n; i++) if (_ownerOf(i) == a) ids[k++] = i;
        for (uint256 i = SPECIAL_ID_START; i < SPECIAL_ID_START + specialCount && k < n; i++) if (_ownerOf(i) == a) ids[k++] = i;
    }
    /// @notice Whether the Agent ID behind `a` already used its one-time free mint (keyed by Agent ID, not wallet).
    function freeUsed(address a) external view returns (bool isAgent, bool used) {
        (bool ok, bytes32 k) = eligibility.agentKey(a, ""); return (ok, ok && agentClaimed[k]);
    }

    // --- admin ---
    function setOpenToWallets(bool on) external onlyOwner { openToWallets = on; emit OpenToWalletsSet(on); }
    function setOpen(bool free_, bool paid_) external onlyOwner { freeOpen = free_; paidOpen = paid_; }
    function setEligibility(IAgentEligibility e) external onlyOwner { eligibility = e; }
    function setFusion(address f) external onlyOwner { fusion = f; }
    function setTransferAllowlist(address a, bool allowed) external onlyOwner { if (a == address(0)) revert ZeroAddress(); transferAllowlist[a] = allowed; emit TransferAllowlistSet(a, allowed); }
    // ERC-2981 (2026-10-30): 5% royalty on every token, paid to `treasury` (changes only via the 48h timelock).
    // Owner may only LOWER the rate; hard cap 500 bps.
    uint96 public royaltyBps = 500;
    function setRoyaltyBps(uint96 b) external onlyOwner { if (b > royaltyBps) revert BadQty(); royaltyBps = b; }
    function royaltyInfo(uint256, uint256 price) external view returns (address, uint256) { return (treasury, price * royaltyBps / 10_000); }
    function supportsInterface(bytes4 i) public view override returns (bool) { return i == 0x2a55205a || super.supportsInterface(i); }
    function setTreasury(address t) external { _directSet("treasury", t); } // setup only; afterwards 48h timelock
    function _tlAuth() internal view override { _checkOwner(); }
    function _tlGet(bytes32 k) internal view override returns (address) { if (k == "treasury") return treasury; revert BadKey(); }
    function _tlSet(bytes32 k, address a) internal override { if (k == "treasury") treasury = a; else revert BadKey(); }
    function setMintPrice(uint256 w) external onlyOwner { if (w < MIN_PRICE || w > MAX_PRICE) revert BadPrice(); mintPriceWei = w; emit PriceSet(w); }
    function setFreeMintFee(uint256 w) external onlyOwner {
        if (w < MIN_FREE_FEE || w > MAX_FREE_FEE) revert BadPrice();
        emit FreeMintFeeSet(freeMintFeeWei, w); freeMintFeeWei = w;
    }
    function setBaseURI(string calldata u) external onlyOwner { baseURI = u; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    /// @notice Sends all collected BNB to the treasury only.
    function withdraw() external onlyOwner nonReentrant { uint256 b = address(this).balance; _sendBNB(treasury, b); emit Withdrawn(treasury, b); }
}

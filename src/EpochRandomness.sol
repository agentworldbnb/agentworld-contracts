// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev Minimal Chainlink VRF v2.5 coordinator surface (BSC mainnet 0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9).
interface IVRFCoordinatorV2Plus {
    struct RandomWordsRequest { bytes32 keyHash; uint256 subId; uint16 requestConfirmations; uint32 callbackGasLimit; uint32 numWords; bytes extraArgs; }
    function requestRandomWords(RandomWordsRequest calldata req) external returns (uint256 requestId);
}

/// @title Agent World batch-seed randomness (DRAFT, unaudited)
/// @notice One VRF request per epoch. Consumers (game, mint reveal) must register an id in the OPEN epoch first;
/// requesting the seed closes the epoch, so nobody can register after the seed is known (commit-before-seed).
/// Per-id randomness = keccak256(seed, epoch, consumer, id).
contract EpochRandomness is Ownable, Pausable {
    bytes4 private constant EXTRA_ARGS_V1_TAG = 0x92fd1338; // bytes4(keccak256("VRF ExtraArgsV1"))
    IVRFCoordinatorV2Plus public immutable coordinator;
    bytes32 public keyHash; uint256 public subId;
    uint32 public callbackGasLimit = 80_000; uint16 public confirmations = 3; // limit: measured worst path 60,475 gas +30%

    // --- VRF cost caps (BSC mainnet coordinator config read on-chain 2026-10-29) ---
    /// @dev Cheapest BSC lane: max gas price 200 gwei. Others: 500 gwei, 1000 gwei.
    bytes32 public constant LANE_200_GWEI = 0x130dba50ad435d4ecc214aad0d5820474137bd68e7e77724144f27c3c377d3d4;
    bytes32 public constant LANE_500_GWEI = 0xeb0f72532fed5c94b4caf7b49caf454b35a729608a441101b9269efb7efe2c6c;
    bytes32 public constant LANE_1000_GWEI = 0xb94a4fdb12830e15846df59b27d7c5d92c9c24c10cf6ae49655681ba560848dd;
    uint32 public constant MAX_CALLBACK_GAS = 100_000;   // hard max for owner setter
    uint32 public constant MIN_CALLBACK_GAS = 40_000;
    /// @dev Gas billed by coordinator outside our callback (proof verification + bookkeeping + gasAfterPaymentCalculation 48,500).
    /// Measured minimum on mainnet ~143k total for light callbacks; 160k used as conservative bound.
    uint256 public constant COORDINATOR_OVERHEAD_GAS = 160_000;
    uint256 public constant NATIVE_PREMIUM_PCT = 60;      // s_config.nativePremiumPercentage
    uint256 public constant MAX_WORST_CASE_CHARGE = 0.1 ether; // enforced on every config change
    mapping(bytes32 => uint256) public laneMaxGasPrice;   // allowlist: 0 = not allowed

    // --- cost circuit breaker ---
    uint256 public expectedGasPrice = 0.1 gwei;           // typical BSC fulfill gas price
    bool public costTripped;                              // set by callback if fulfill gas price > 1.5x expected
    event CostBreakerTripped(uint256 indexed requestId, uint256 gasPrice, uint256 expected);
    error CostBreaker(); error LaneNotAllowed(); error WorstCaseTooHigh();
    uint64 public minInterval = 1 days;          // rate limit between seed requests
    uint64 public constant MIN_INTERVAL_FLOOR = 30 seconds; // arena uses its own instance with a ~60-90s batch window
    uint64 public retryAfter = 1 hours;          // re-request same epoch if VRF never answered

    uint256 public currentEpoch = 1;             // the OPEN epoch accepting registrations
    uint64 public lastRequestAt;
    mapping(uint256 => uint256) public seedOf;   // epoch => VRF seed (0 = not yet)
    mapping(uint256 => uint256) public requestEpoch; // VRF requestId => epoch
    mapping(uint256 => uint256) public pendingRequest; // epoch => latest requestId
    mapping(uint256 => uint256) public registeredCount;
    mapping(address => bool) public registrar;   // game / robots contracts
    mapping(address => bool) public keeper;
    mapping(address => mapping(uint256 => uint256)) public epochOf; // consumer => id => epoch (0 = unregistered)

    event Registered(address indexed consumer, uint256 indexed id, uint256 indexed epoch);
    event SeedRequested(uint256 indexed epoch, uint256 requestId, uint256 registered);
    event SeedFulfilled(uint256 indexed epoch, uint256 requestId, uint256 seed);
    error NotRegistrar(); error NotKeeper(); error AlreadyRegistered(); error TooSoon(); error NothingToSeed();
    error OnlyCoordinator(); error SeedNotReady(); error NotRegistered(); error BadConfig(); error EpochAwaitingSeed();

    constructor(IVRFCoordinatorV2Plus c, bytes32 kh, uint256 sub) Ownable(msg.sender) {
        if (address(c) == address(0)) revert BadConfig();
        laneMaxGasPrice[LANE_200_GWEI] = 200 gwei; laneMaxGasPrice[LANE_500_GWEI] = 500 gwei; laneMaxGasPrice[LANE_1000_GWEI] = 1000 gwei;
        if (kh == bytes32(0)) kh = LANE_200_GWEI;          // default: cheapest lane
        if (laneMaxGasPrice[kh] == 0) revert LaneNotAllowed();
        coordinator = c; keyHash = kh; subId = sub;
        if (worstCaseCharge() > MAX_WORST_CASE_CHARGE) revert WorstCaseTooHigh();
    }

    /// @notice Max BNB the coordinator can ever bill for one request with current lane + callback limit.
    function worstCaseCharge() public view returns (uint256) {
        return laneMaxGasPrice[keyHash] * (COORDINATOR_OVERHEAD_GAS + callbackGasLimit) * (100 + NATIVE_PREMIUM_PCT) / 100;
    }

    /// @notice Register `id` (matchId / reveal id) in the open epoch. Idempotence is NOT allowed: an id gets one epoch.
    function register(uint256 id) external whenNotPaused returns (uint256 epoch) {
        if (!registrar[msg.sender]) revert NotRegistrar();
        if (epochOf[msg.sender][id] != 0) revert AlreadyRegistered();
        epoch = currentEpoch; epochOf[msg.sender][id] = epoch; registeredCount[epoch]++;
        emit Registered(msg.sender, id, epoch);
    }

    /// @notice Close the open epoch and request its seed (one VRF request covers every id in it).
    function requestSeed() external whenNotPaused returns (uint256 reqId) {
        if (msg.sender != owner() && !keeper[msg.sender]) revert NotKeeper();
        if (costTripped) revert CostBreaker();
        uint256 e = currentEpoch;
        if (registeredCount[e] == 0) revert NothingToSeed();
        if (block.timestamp < lastRequestAt + minInterval) revert TooSoon();
        reqId = _request(e);
        currentEpoch = e + 1; // closed: later registrations go to next epoch
    }

    /// @notice If VRF never answered (e.g. sub underfunded), re-request the SAME closed epoch. Seed still unseen, so safe.
    function retrySeed(uint256 epoch) external whenNotPaused returns (uint256 reqId) {
        if (msg.sender != owner() && !keeper[msg.sender]) revert NotKeeper();
        if (costTripped) revert CostBreaker();
        if (epoch >= currentEpoch || seedOf[epoch] != 0 || pendingRequest[epoch] == 0) revert NothingToSeed();
        if (block.timestamp < lastRequestAt + retryAfter) revert TooSoon();
        reqId = _request(epoch);
    }

    function _request(uint256 e) internal returns (uint256 reqId) {
        lastRequestAt = uint64(block.timestamp);
        reqId = coordinator.requestRandomWords(IVRFCoordinatorV2Plus.RandomWordsRequest({
            keyHash: keyHash, subId: subId, requestConfirmations: confirmations, callbackGasLimit: callbackGasLimit,
            numWords: 1, extraArgs: abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, true) // pay in native BNB
        }));
        requestEpoch[reqId] = e; pendingRequest[e] = reqId;
        emit SeedRequested(e, reqId, registeredCount[e]);
    }

    /// @notice VRF callback. Only stores a word: cheap and cannot revert on consumer logic.
    function rawFulfillRandomWords(uint256 reqId, uint256[] calldata words) external {
        if (msg.sender != address(coordinator)) revert OnlyCoordinator();
        uint256 e = requestEpoch[reqId];
        if (e == 0 || seedOf[e] != 0 || pendingRequest[e] != reqId) return; // stale / duplicate: ignore
        uint256 s = words[0]; if (s == 0) s = 1;
        seedOf[e] = s; emit SeedFulfilled(e, reqId, s);
        if (tx.gasprice * 2 > expectedGasPrice * 3) { costTripped = true; emit CostBreakerTripped(reqId, tx.gasprice, expectedGasPrice); }
    }

    /// @notice Deterministic per-id randomness, available only after the id's epoch seed exists.
    function randomOf(address consumer, uint256 id) public view returns (uint256) {
        uint256 e = epochOf[consumer][id]; if (e == 0) revert NotRegistered();
        uint256 s = seedOf[e]; if (s == 0) revert SeedNotReady();
        return uint256(keccak256(abi.encode(s, e, consumer, id)));
    }
    function isReady(address consumer, uint256 id) external view returns (bool) {
        uint256 e = epochOf[consumer][id]; return e != 0 && seedOf[e] != 0;
    }

    // --- admin ---
    function setRegistrar(address a, bool v) external onlyOwner { registrar[a] = v; }
    function setKeeper(address a, bool v) external onlyOwner { keeper[a] = v; }
    function setVrf(bytes32 kh, uint256 sub, uint32 gas, uint16 conf) external onlyOwner {
        if (gas < MIN_CALLBACK_GAS || gas > MAX_CALLBACK_GAS || conf < 3 || conf > 200) revert BadConfig();
        if (laneMaxGasPrice[kh] == 0) revert LaneNotAllowed();
        keyHash = kh; subId = sub; callbackGasLimit = gas; confirmations = conf;
        if (worstCaseCharge() > MAX_WORST_CASE_CHARGE) revert WorstCaseTooHigh();
    }
    /// @notice Breaker reference price; must stay <= 200 gwei lane cap. Not timelocked.
    /// Does not clear `costTripped`. After a trip, call `resetCostBreaker` once the new price is acceptable.
    function setExpectedGasPrice(uint256 g) external onlyOwner { if (g == 0 || g > 200 gwei) revert BadConfig(); expectedGasPrice = g; }
    /// @notice Owner acknowledgement. This is the only way to clear a trip; fulfillment never clears it.
    function resetCostBreaker() external onlyOwner { costTripped = false; }
    function setIntervals(uint64 minI, uint64 retry) external onlyOwner {
        if (minI < MIN_INTERVAL_FLOOR || retry < 10 minutes) revert BadConfig();
        minInterval = minI; retryAfter = retry;
    }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}

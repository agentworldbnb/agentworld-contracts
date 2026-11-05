// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAgentEligibility} from "./IAgentEligibility.sol";
import {EpochRandomness} from "./EpochRandomness.sol";

interface IRaffleRobots { function mintOfficial(address to, uint256 n) external; function officialMinted() external view returns (uint256); }

/// @title Agent World event raffle (DRAFT, unaudited) - free entry, VRF draw, prize = 1 official hero.
/// @notice Official heroes: exactly 10 ever (AgentWorldRobots.OFFICIAL_SUPPLY), never from mint/whitelist/box/forge;
/// only the owner distributes them for events. This raffle is one such event: entry is FREE (non-payable), one entry
/// per account (Agent ID key, or wallet key when openToWallets - same rule as the rest of the game), VRF picks 1 winner.
/// The owner then calls robots.mintOfficial(winner, 1) (or this contract does it via fulfil() if it was made owner-minter).
contract AgentWorldEventRaffle is Ownable {
    IAgentEligibility public eligibility; EpochRandomness public randomness;
    bool public openToWallets = true;
    struct Raffle { uint64 closesAt; uint8 state; /*0 none 1 open 2 committed 3 drawn*/ address winner; uint256 seed; }
    mapping(uint256 => Raffle) public raffles; uint256 public raffleCount;
    mapping(uint256 => address[]) internal _entrants;
    mapping(uint256 => mapping(bytes32 => bool)) public entered;
    uint256 internal constant ID_BASE = 1 << 220;
    event RaffleOpened(uint256 indexed id, uint64 closesAt); event Entered(uint256 indexed id, address indexed wallet, bytes32 key);
    event Committed(uint256 indexed id, uint256 epoch, uint256 entrants); event Drawn(uint256 indexed id, address winner, uint256 seed);
    error Closed(); error Already(); error NotAgent(); error BadState(); error NotReady(); error NoEntrants();

    constructor(IAgentEligibility e, EpochRandomness r) Ownable(msg.sender) { eligibility = e; randomness = r; }
    function open(uint64 closesAt) external onlyOwner returns (uint256 id) {
        if (closesAt <= block.timestamp) revert Closed();
        id = ++raffleCount; raffles[id].closesAt = closesAt; raffles[id].state = 1; emit RaffleOpened(id, closesAt);
    }
    /// @notice Free entry (no BNB accepted - function is non-payable). One per account.
    function enter(uint256 id) external {
        Raffle storage r = raffles[id]; if (r.state != 1 || block.timestamp >= r.closesAt) revert Closed();
        (bool ok, bytes32 k) = eligibility.agentKey(msg.sender, "");
        if (!ok) { if (!openToWallets) revert NotAgent(); k = keccak256(abi.encode("wallet", msg.sender)); }
        if (entered[id][k]) revert Already(); entered[id][k] = true; _entrants[id].push(msg.sender); emit Entered(id, msg.sender, k);
    }
    /// @notice Anyone, after close: register for the next VRF seed (entrant list frozen before the seed exists).
    function commit(uint256 id) external {
        Raffle storage r = raffles[id]; if (r.state != 1 || block.timestamp < r.closesAt) revert BadState();
        if (_entrants[id].length == 0) revert NoEntrants();
        r.state = 2; uint256 ep = randomness.register(ID_BASE + id); emit Committed(id, ep, _entrants[id].length);
    }
    function draw(uint256 id) external returns (address w) {
        Raffle storage r = raffles[id]; if (r.state != 2) revert BadState();
        if (!randomness.isReady(address(this), ID_BASE + id)) revert NotReady();
        uint256 s = randomness.randomOf(address(this), ID_BASE + id); w = _entrants[id][s % _entrants[id].length];
        r.state = 3; r.winner = w; r.seed = s; emit Drawn(id, w, s);
    }
    function entrantsOf(uint256 id) external view returns (address[] memory) { return _entrants[id]; }
    function setOpenToWallets(bool on) external onlyOwner { openToWallets = on; }
}

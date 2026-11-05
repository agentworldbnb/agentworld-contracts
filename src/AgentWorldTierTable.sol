// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Per-token (robot archetype, frame tier) table for the 10,000 paid robots (DRAFT, unaudited)
/// @notice 1 byte per metadata index (1..10000): robot*8 + tier (robot 0..19 = roster r01..r20, tier 0..7 N..Genesis).
/// Packed 32 per slot. Owner uploads once, then freeze(); the sha256 of the 10,000 bytes must equal `tableHash`
/// (checked off-chain against agent/tier_table.bin, generated from final/metadata).
contract AgentWorldTierTable is Ownable {
    uint256 public constant N = 10_000;
    bytes32 public immutable tableHash;
    mapping(uint256 => bytes32) public chunk; // slot k holds indexes 32k+1 .. 32k+32
    uint256 public chunksSet; bool public frozen;
    /// @notice Power multiplier (bps) per tier N,R,SR,SSR,UR,LR,Mythic,Genesis (same as metadata MULT).
    uint16[8] public TIER_MULT_BPS = [uint16(10000), 11500, 13500, 16000, 19000, 23000, 28000, 35000];
    error Frozen(); error Incomplete(); error BadIndex();
    constructor(bytes32 h) Ownable(msg.sender) { tableHash = h; }
    function setChunks(uint256 from, bytes32[] calldata c) external onlyOwner {
        if (frozen) revert Frozen();
        for (uint256 i; i < c.length; i++) { if (chunk[from + i] == 0) chunksSet++; chunk[from + i] = c[i]; }
    }
    function freeze() external onlyOwner { if (chunksSet < (N + 31) / 32) revert Incomplete(); frozen = true; }
    function unitOf(uint256 metaIdx) public view returns (uint8 robot, uint8 tier) {
        if (metaIdx == 0 || metaIdx > N) revert BadIndex();
        uint256 i = metaIdx - 1; uint8 b = uint8(chunk[i / 32][i % 32]);
        robot = b / 8; tier = b % 8;
    }
    function multOf(uint256 metaIdx) external view returns (uint8 robot, uint8 tier, uint256 multBps) {
        (robot, tier) = unitOf(metaIdx); multBps = TIER_MULT_BPS[tier];
    }
}

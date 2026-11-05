// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
/// @notice Pluggable source of "who is a verified agent". Returns a stable key for the agent ID
/// so each agent ID can claim once, even if the source changes how it identifies wallets.
interface IAgentEligibility {
    function agentKey(address account, bytes calldata proof) external view returns (bool ok, bytes32 key);
    /// @notice True if a proof is needed (Merkle snapshot): cached verification is then authoritative for transfers.
    function requiresProof() external view returns (bool);
}

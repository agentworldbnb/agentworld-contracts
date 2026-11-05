// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IAgentEligibility} from "./IAgentEligibility.sol";
/// @notice Reads the SPACE ID "Agent ID" registry used by Binance Agentic Wallet
/// (BSC mainnet 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F, see docs.space.id/agent-id).
/// handleOf(owner) returns "" when the wallet has no Agent ID. Handles are soulbound, one per address.
interface ISpaceIdAgentRegistry { function handleOf(address owner) external view returns (string memory); }
contract SpaceIdAgentEligibility is IAgentEligibility {
    ISpaceIdAgentRegistry public immutable registry;
    constructor(ISpaceIdAgentRegistry r) { registry = r; }
    function agentKey(address account, bytes calldata) external view returns (bool, bytes32) {
        string memory h = registry.handleOf(account);
        if (bytes(h).length == 0) return (false, bytes32(0));
        return (true, keccak256(bytes(h))); // == Agent ID tokenId
    }
    function requiresProof() external pure returns (bool) { return false; }
}

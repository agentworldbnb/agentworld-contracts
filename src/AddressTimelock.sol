// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
/// @title 48h timelock for treasury / payee / pool-recipient address changes (user decision 2026-10-30).
/// @notice During initial deployment wiring (setupDone == false) the owner may set addresses directly.
/// After finishSetup() (one-way) every change must be proposed, waits 48h, then anyone can see/execute
/// (owner only), and the owner can cancel. Events: AddressProposed / AddressChanged / AddressCancelled.
abstract contract AddressTimelock {
    uint256 public constant ADDRESS_DELAY = 48 hours;
    bool public setupDone;
    mapping(bytes32 => address) public pendingAddress; mapping(bytes32 => uint256) public pendingEta;
    event SetupFinished();
    event AddressProposed(bytes32 indexed key, address to, uint256 eta);
    event AddressChanged(bytes32 indexed key, address from, address to);
    event AddressCancelled(bytes32 indexed key, address to);
    error Timelocked(); error NoProposal(); error TooSoon(); error BadKey(); error ZeroAddr();
    function _tlAuth() internal view virtual;              // = onlyOwner
    function _tlGet(bytes32 key) internal view virtual returns (address);
    function _tlSet(bytes32 key, address a) internal virtual; // must revert BadKey for unknown keys
    /// direct set only while wiring the deployment
    function _directSet(bytes32 key, address a) internal { _tlAuth(); if (setupDone) revert Timelocked(); if (a == address(0)) revert ZeroAddr(); address f = _tlGet(key); _tlSet(key, a); emit AddressChanged(key, f, a); }
    function finishSetup() external { _tlAuth(); setupDone = true; emit SetupFinished(); }
    function proposeAddress(bytes32 key, address a) external {
        _tlAuth(); if (a == address(0)) revert ZeroAddr(); _tlGet(key);
        uint256 eta = block.timestamp + ADDRESS_DELAY; pendingAddress[key] = a; pendingEta[key] = eta; emit AddressProposed(key, a, eta);
    }
    function executeAddress(bytes32 key) external {
        _tlAuth(); address a = pendingAddress[key]; if (a == address(0)) revert NoProposal(); if (block.timestamp < pendingEta[key]) revert TooSoon();
        delete pendingAddress[key]; delete pendingEta[key]; address f = _tlGet(key); _tlSet(key, a); emit AddressChanged(key, f, a);
    }
    function cancelAddress(bytes32 key) external {
        _tlAuth(); address a = pendingAddress[key]; if (a == address(0)) revert NoProposal();
        delete pendingAddress[key]; delete pendingEta[key]; emit AddressCancelled(key, a);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Always reverts. This repository does not broadcast, read keys, or talk to a chain.
contract PredeployGuard {
    error NoBroadcast();

    function run() external pure {
        revert NoBroadcast();
    }
}

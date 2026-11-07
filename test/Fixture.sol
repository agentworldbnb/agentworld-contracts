// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVRFCoordinatorV2Plus, EpochRandomness} from "../src/EpochRandomness.sol";

interface Vm {
    function prank(address) external;
    function warp(uint256) external;
    function deal(address who, uint256 newBalance) external;
}

contract MockVRF is IVRFCoordinatorV2Plus {
    uint256 public nextId = 1;
    function requestRandomWords(RandomWordsRequest calldata) external returns (uint256 requestId) {
        requestId = nextId++;
    }
}

/// Shared VRF wiring. Tests supply the word; nothing talks to Chainlink.
abstract contract VrfEnv {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    MockVRF internal coord;
    EpochRandomness internal rnd;

    function _vrf() internal {
        coord = new MockVRF();
        rnd = new EpochRandomness(IVRFCoordinatorV2Plus(address(coord)), bytes32(0), 1);
        rnd.setIntervals(30, 10 minutes);
    }

    /// The contract refuses a seed request until minInterval has elapsed.
    /// Foundry starts at timestamp 1, which is inside that window.
    function _request() internal returns (uint256 req) {
        vm.warp(block.timestamp + rnd.minInterval());
        req = rnd.requestSeed();
    }

    function _seal(uint256 word) internal returns (uint256 epoch) {
        epoch = rnd.currentEpoch();
        uint256 req = _request();
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vm.prank(address(coord));
        rnd.rawFulfillRandomWords(req, words);
    }

    function _req(bool ok, string memory m) internal pure {
        require(ok, m);
    }
}

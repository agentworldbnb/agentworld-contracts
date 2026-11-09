// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VrfEnv, Vm} from "./Fixture.sol";
import {EpochRandomness} from "../src/EpochRandomness.sol";

/// The 1.5x gas-price guard stays. It does not clear itself.
contract CostBreakerTest is VrfEnv {
    function setUp() public {
        _vrf();
        rnd.setRegistrar(address(this), true);
    }

    function test_tripEventViewAndExplicitReset() public {
        _req(rnd.expectedGasPrice() == 0.1 gwei, "default price");
        _req(!rnd.costTripped(), "not tripped");
        rnd.register(1);
        vm.warp(block.timestamp + rnd.minInterval());
        uint256 req = rnd.requestSeed();
        uint256 closed = rnd.currentEpoch() - 1;
        vm.txGasPrice(1 gwei);
        vm.recordLogs();
        uint256[] memory words = new uint256[](1);
        words[0] = 7;
        vm.prank(address(coord));
        rnd.rawFulfillRandomWords(req, words);
        _req(rnd.seedOf(closed) != 0, "seed kept");
        _req(rnd.costTripped(), "view tripped");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("CostBreakerTripped(uint256,uint256,uint256)");
        bool saw;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(rnd) && logs[i].topics.length > 0 && logs[i].topics[0] == sig) saw = true;
        }
        _req(saw, "event");
        rnd.register(2);
        vm.warp(block.timestamp + rnd.minInterval());
        (bool stalled,) = address(rnd).call(abi.encodeCall(EpochRandomness.requestSeed, ()));
        _req(!stalled, "requests wait");
        rnd.setExpectedGasPrice(5 gwei);
        _req(rnd.costTripped(), "price change is not a reset");
        (bool still,) = address(rnd).call(abi.encodeCall(EpochRandomness.requestSeed, ()));
        _req(!still, "still waiting");
        (bool zero,) = address(rnd).call(abi.encodeCall(EpochRandomness.setExpectedGasPrice, (0)));
        (bool huge,) = address(rnd).call(abi.encodeCall(EpochRandomness.setExpectedGasPrice, (201 gwei)));
        _req(!zero && !huge, "price bounds");
        rnd.resetCostBreaker();
        _req(!rnd.costTripped(), "owner reset");
        rnd.requestSeed();
        _req(rnd.pendingRequest(rnd.currentEpoch() - 1) != 0, "requests resume");
    }
}

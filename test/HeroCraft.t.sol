// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VrfEnv} from "./Fixture.sol";
import {AgentWorldForge, IGearForge} from "../src/AgentWorldForge.sol";
import {AgentWorldGear, IRobots} from "../src/AgentWorldGear.sol";
import {AgentWorldRobots} from "../src/AgentWorldRobots.sol";
import {IAgentEligibility} from "../src/IAgentEligibility.sol";

contract CraftElig is IAgentEligibility {
    function agentKey(address, bytes calldata) external pure returns (bool, bytes32) { return (false, bytes32(0)); }
    function requiresProof() external pure returns (bool) { return false; }
}

/// Elite craft success and failure, plus the revert paths around mythic and legend.
contract HeroCraftTest is VrfEnv {
    address internal constant USER = address(0xA11CE);
    AgentWorldGear internal gear;
    AgentWorldRobots internal robots;
    AgentWorldForge internal forgeC;

    function setUp() public {
        _vrf();
        CraftElig elig = new CraftElig();
        robots = new AgentWorldRobots(0.001 ether, address(0x7771), elig, bytes32("c"), "h");
        robots.setOpen(false, true);
        uint256[3] memory prices = [uint256(0.0001 ether), 0.0001 ether, 0.0001 ether];
        gear = new AgentWorldGear(address(0x7771), address(0x51), elig, rnd, IRobots(address(robots)), prices);
        forgeC = new AgentWorldForge(IGearForge(address(gear)), rnd);
        gear.setForge(address(forgeC));
        robots.setFusion(address(forgeC));
        robots.setSpecialMinter(address(forgeC), true);
        rnd.setRegistrar(address(forgeC), true);
        vm.deal(USER, 2 ether);
    }

    function _ur(uint256 id) internal {
        vm.prank(address(forgeC));
        gear.forgeMint(USER, id);
    }

    function _fee(uint256 i) internal view returns (uint256) { return forgeC.craftFeeWei(i); }

    function _mats(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[3] memory m) {
        m[0] = a; m[1] = b; m[2] = c;
    }

    function _word(uint256 craftId, bool success, uint256 bps) internal view returns (uint256) {
        uint256 epoch = rnd.currentEpoch();
        uint256 rid = (2 << 128) + craftId;
        for (uint256 w = 1; w < 4000; w++) {
            uint256 r = uint256(keccak256(abi.encode(w, epoch, address(forgeC), rid)));
            if ((uint16(r % 10_000) < bps) == success) return w;
        }
        revert("craft seed");
    }

    function _elite(uint256 a, uint256 b, uint256 c) internal returns (uint256 id) {
        _ur(a); _ur(b); _ur(c);
        vm.prank(USER);
        uint256 cid = forgeC.craftElite{value: _fee(0)}(0, _mats(a, b, c));
        _seal(_word(cid, true, 8000));
        (, id) = forgeC.settleCraft(cid);
    }

    function test_eliteSuccessFailureAndReverts() public {
        uint256[3] memory sample = _mats(104, 109, 114);
        vm.prank(USER);
        (bool badTier,) = address(forgeC).call(abi.encodeCall(AgentWorldForge.craftElite, (uint8(10), sample)));
        _req(!badTier, "target");
        _ur(104); _ur(109); _ur(114);
        vm.prank(USER);
        (bool cheap,) = address(forgeC).call{value: _fee(0) - 1}(abi.encodeCall(AgentWorldForge.craftElite, (uint8(0), sample)));
        _req(!cheap, "fee");
        uint256[3] memory mixed = _mats(100, 109, 114);
        _ur(100);
        vm.prank(USER);
        (bool notUr,) = address(forgeC).call{value: _fee(0)}(abi.encodeCall(AgentWorldForge.craftElite, (uint8(0), mixed)));
        _req(!notUr, "not ur");

        vm.prank(USER);
        uint256 okId = forgeC.craftElite{value: _fee(0)}(0, sample);
        (bool early,) = address(forgeC).call(abi.encodeCall(AgentWorldForge.settleCraft, (okId)));
        _req(!early, "seed missing");
        _seal(_word(okId, true, 8000));
        (bool made, uint256 robotId) = forgeC.settleCraft(okId);
        _req(made && robots.ownerOf(robotId) == USER && robots.specialCharOf(robotId) == 35, "elite minted");
        (bool twice,) = address(forgeC).call(abi.encodeCall(AgentWorldForge.settleCraft, (okId)));
        _req(!twice, "settled");

        uint256[3] memory failMats = _mats(119, 124, 129);
        _ur(119); _ur(124); _ur(129);
        vm.prank(USER);
        uint256 badId = forgeC.craftElite{value: _fee(0)}(1, failMats);
        _seal(_word(badId, false, 8000));
        (bool failed, uint256 none) = forgeC.settleCraft(badId);
        _req(!failed && none == 0, "no hero");
        _req(gear.balanceOf(USER, 119) + gear.balanceOf(USER, 124) + gear.balanceOf(USER, 129) == 1, "one gear back");
    }

    function test_mythicSucceedsAndLegendRejectsElites() public {
        uint256 a = _elite(134, 139, 144);
        uint256 b = _elite(149, 154, 159);
        uint256[2] memory same = [a, a];
        vm.prank(USER);
        (bool dup,) = address(forgeC).call{value: _fee(1)}(abi.encodeCall(AgentWorldForge.craftMythic, (uint8(0), same)));
        _req(!dup, "same hero");
        uint256[2] memory elites = [a, b];
        vm.prank(USER);
        (bool legend,) = address(forgeC).call{value: _fee(2)}(abi.encodeCall(AgentWorldForge.craftLegend, (uint8(0), elites)));
        _req(!legend, "legend wants mythics");
        vm.prank(USER);
        (bool locked,) = address(forgeC).call{value: _fee(1)}(abi.encodeCall(AgentWorldForge.craftMythic, (uint8(0), elites)));
        _req(!locked, "approval");
        vm.prank(USER);
        robots.setApprovalForAll(address(forgeC), true);
        vm.prank(USER);
        uint256 id = forgeC.craftMythic{value: _fee(1)}(uint8(0), elites);
        _seal(_word(id, true, 6000));
        (bool made, uint256 hero) = forgeC.settleCraft(id);
        _req(made && robots.specialCharOf(hero) == 30, "mythic");
        // ownerOf is inherited from ERC721, so encodeCall cannot see it on AgentWorldRobots.
        bool burned;
        try robots.ownerOf(a) returns (address) { burned = true; } catch { burned = false; }
        _req(!burned, "elite burned");
    }
}

# Agent World Contracts

Verified source code of the Agent World mainnet contracts on BNB Smart Chain (chain ID 56).

- Website: https://agentworldbnb.com
- Game: https://agentworldbnb.com/play/
- Player guide: https://agentworldbnb.com/guide/
- X: https://x.com/AgentWorldBNB

This repository only mirrors the source files that are publicly verified for the deployed contracts. Every file under `src/` and `lib/` was downloaded unchanged from Sourcify (full match) and is the same code verified on BscScan. Compiler: Solidity `0.8.37+commit.f401782d`.

## Mainnet contracts

| Contract | Source | Address | BscScan | Sourcify |
|---|---|---|---|---|
| Robots (hero NFT) | `src/AgentWorldRobots.sol` | `0x931B026F06D9229a25409dD02C99B8517437cb8c` | [BscScan](https://bscscan.com/address/0x931B026F06D9229a25409dD02C99B8517437cb8c#code) | [Sourcify](https://repo.sourcify.dev/56/0x931B026F06D9229a25409dD02C99B8517437cb8c) |
| Gear (gear & blind boxes) | `src/AgentWorldGear.sol` | `0x1836e1A6c86F6EE21aD50ecde8A70f636Af22ABe` | [BscScan](https://bscscan.com/address/0x1836e1A6c86F6EE21aD50ecde8A70f636Af22ABe#code) | [Sourcify](https://repo.sourcify.dev/56/0x1836e1A6c86F6EE21aD50ecde8A70f636Af22ABe) |
| Arena | `src/AgentWorldArena.sol` | `0x3cAfF32C56b5Cb4e8f82427908Ad8Bd2eFBD164C` | [BscScan](https://bscscan.com/address/0x3cAfF32C56b5Cb4e8f82427908Ad8Bd2eFBD164C#code) | [Sourcify](https://repo.sourcify.dev/56/0x3cAfF32C56b5Cb4e8f82427908Ad8Bd2eFBD164C) |
| Resonance Forge | `src/AgentWorldForge.sol` | `0xC35709f1f3Fb5338621d41D06232f7D1c3338079` | [BscScan](https://bscscan.com/address/0xC35709f1f3Fb5338621d41D06232f7D1c3338079#code) | [Sourcify](https://repo.sourcify.dev/56/0xC35709f1f3Fb5338621d41D06232f7D1c3338079) |
| Lottery | `src/AgentWorldLottery.sol` | `0x7394Ee31A71B459EEE135DbBd62E54054A1c0B4f` | [BscScan](https://bscscan.com/address/0x7394Ee31A71B459EEE135DbBd62E54054A1c0B4f#code) | [Sourcify](https://repo.sourcify.dev/56/0x7394Ee31A71B459EEE135DbBd62E54054A1c0B4f) |
| Event Raffle | `src/AgentWorldEventRaffle.sol` | `0x8C9Ef6591d9c4FA9F6153A77e766c4275D37629D` | [BscScan](https://bscscan.com/address/0x8C9Ef6591d9c4FA9F6153A77e766c4275D37629D#code) | [Sourcify](https://repo.sourcify.dev/56/0x8C9Ef6591d9c4FA9F6153A77e766c4275D37629D) |
| Randomness (Chainlink VRF) | `src/EpochRandomness.sol` | `0xBe5844A71d5d2F99632FAd9a18AAB5A5B44c888C` | [BscScan](https://bscscan.com/address/0xBe5844A71d5d2F99632FAd9a18AAB5A5B44c888C#code) | [Sourcify](https://repo.sourcify.dev/56/0xBe5844A71d5d2F99632FAd9a18AAB5A5B44c888C) |
| Arena Randomness (Chainlink VRF) | `src/EpochRandomness.sol` | `0x58f1691c815121E607eaA60e8e9C859A62B2A0A7` | [BscScan](https://bscscan.com/address/0x58f1691c815121E607eaA60e8e9C859A62B2A0A7#code) | [Sourcify](https://repo.sourcify.dev/56/0x58f1691c815121E607eaA60e8e9C859A62B2A0A7) |
| Agent ID Eligibility | `src/SpaceIdAgentEligibility.sol` | `0x6c30D8DceD6383f7a7C5C2421e81e9030D0FbEB9` | [BscScan](https://bscscan.com/address/0x6c30D8DceD6383f7a7C5C2421e81e9030D0FbEB9#code) | [Sourcify](https://repo.sourcify.dev/56/0x6c30D8DceD6383f7a7C5C2421e81e9030D0FbEB9) |
| Tier Table | `src/AgentWorldTierTable.sol` | `0x933a507b3d98E65f88610A9fB9b462701E519016` | [BscScan](https://bscscan.com/address/0x933a507b3d98E65f88610A9fB9b462701E519016#code) | [Sourcify](https://repo.sourcify.dev/56/0x933a507b3d98E65f88610A9fB9b462701E519016) |

The same address list is published by the game at https://agentworldbnb.com/collection/addresses.json

## Layout

- `src/` Agent World contracts
- `lib/openzeppelin-contracts/` OpenZeppelin dependencies exactly as verified (MIT, © OpenZeppelin)

## License

MIT, as declared by the SPDX header of every source file. See `LICENSE`.

---

# Agent World 合約（繁體中文）

Agent World 在 BNB Smart Chain（chain ID 56）主網合約的已驗證原始碼。

- 官網：https://agentworldbnb.com
- 遊戲：https://agentworldbnb.com/play/
- 玩家攻略：https://agentworldbnb.com/guide/
- X：https://x.com/AgentWorldBNB

這個 repo 只收錄已部署合約公開驗證過的原始碼。`src/` 與 `lib/` 下每個檔案都直接從 Sourcify（full match）下載、未經修改，與 BscScan 上驗證的程式碼相同。編譯器：Solidity `0.8.37+commit.f401782d`。

## 主網合約

| 合約 | 原始碼 | 地址 | BscScan | Sourcify |
|---|---|---|---|---|
| Robots (hero NFT) | `src/AgentWorldRobots.sol` | `0x931B026F06D9229a25409dD02C99B8517437cb8c` | [BscScan](https://bscscan.com/address/0x931B026F06D9229a25409dD02C99B8517437cb8c#code) | [Sourcify](https://repo.sourcify.dev/56/0x931B026F06D9229a25409dD02C99B8517437cb8c) |
| Gear (gear & blind boxes) | `src/AgentWorldGear.sol` | `0x1836e1A6c86F6EE21aD50ecde8A70f636Af22ABe` | [BscScan](https://bscscan.com/address/0x1836e1A6c86F6EE21aD50ecde8A70f636Af22ABe#code) | [Sourcify](https://repo.sourcify.dev/56/0x1836e1A6c86F6EE21aD50ecde8A70f636Af22ABe) |
| Arena | `src/AgentWorldArena.sol` | `0x3cAfF32C56b5Cb4e8f82427908Ad8Bd2eFBD164C` | [BscScan](https://bscscan.com/address/0x3cAfF32C56b5Cb4e8f82427908Ad8Bd2eFBD164C#code) | [Sourcify](https://repo.sourcify.dev/56/0x3cAfF32C56b5Cb4e8f82427908Ad8Bd2eFBD164C) |
| Resonance Forge | `src/AgentWorldForge.sol` | `0xC35709f1f3Fb5338621d41D06232f7D1c3338079` | [BscScan](https://bscscan.com/address/0xC35709f1f3Fb5338621d41D06232f7D1c3338079#code) | [Sourcify](https://repo.sourcify.dev/56/0xC35709f1f3Fb5338621d41D06232f7D1c3338079) |
| Lottery | `src/AgentWorldLottery.sol` | `0x7394Ee31A71B459EEE135DbBd62E54054A1c0B4f` | [BscScan](https://bscscan.com/address/0x7394Ee31A71B459EEE135DbBd62E54054A1c0B4f#code) | [Sourcify](https://repo.sourcify.dev/56/0x7394Ee31A71B459EEE135DbBd62E54054A1c0B4f) |
| Event Raffle | `src/AgentWorldEventRaffle.sol` | `0x8C9Ef6591d9c4FA9F6153A77e766c4275D37629D` | [BscScan](https://bscscan.com/address/0x8C9Ef6591d9c4FA9F6153A77e766c4275D37629D#code) | [Sourcify](https://repo.sourcify.dev/56/0x8C9Ef6591d9c4FA9F6153A77e766c4275D37629D) |
| Randomness (Chainlink VRF) | `src/EpochRandomness.sol` | `0xBe5844A71d5d2F99632FAd9a18AAB5A5B44c888C` | [BscScan](https://bscscan.com/address/0xBe5844A71d5d2F99632FAd9a18AAB5A5B44c888C#code) | [Sourcify](https://repo.sourcify.dev/56/0xBe5844A71d5d2F99632FAd9a18AAB5A5B44c888C) |
| Arena Randomness (Chainlink VRF) | `src/EpochRandomness.sol` | `0x58f1691c815121E607eaA60e8e9C859A62B2A0A7` | [BscScan](https://bscscan.com/address/0x58f1691c815121E607eaA60e8e9C859A62B2A0A7#code) | [Sourcify](https://repo.sourcify.dev/56/0x58f1691c815121E607eaA60e8e9C859A62B2A0A7) |
| Agent ID Eligibility | `src/SpaceIdAgentEligibility.sol` | `0x6c30D8DceD6383f7a7C5C2421e81e9030D0FbEB9` | [BscScan](https://bscscan.com/address/0x6c30D8DceD6383f7a7C5C2421e81e9030D0FbEB9#code) | [Sourcify](https://repo.sourcify.dev/56/0x6c30D8DceD6383f7a7C5C2421e81e9030D0FbEB9) |
| Tier Table | `src/AgentWorldTierTable.sol` | `0x933a507b3d98E65f88610A9fB9b462701E519016` | [BscScan](https://bscscan.com/address/0x933a507b3d98E65f88610A9fB9b462701E519016#code) | [Sourcify](https://repo.sourcify.dev/56/0x933a507b3d98E65f88610A9fB9b462701E519016) |

遊戲官網也公開同一份地址清單：https://agentworldbnb.com/collection/addresses.json

## 授權

MIT，依每個原始碼檔案的 SPDX 標頭。詳見 `LICENSE`。

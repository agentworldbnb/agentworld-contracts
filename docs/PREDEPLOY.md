# 部署前核對（不廣播、不讀私鑰、不連主網）

這份文件只描述操作順序。它不會送交易。`script/PredeployGuard.sol` 的 `run()` 一律 revert。`script/verify-offline.sh` 在隔離條件缺任何一項時直接結束，不會啟動 forge，也不會安裝軟體。

開盲盒與付費對戰的前提：隔離環境裡的 `forge test`、`forge build --sizes` 與 gas 報告都對「將要部署的那個 commit」實際通過。換過編譯設定或程式之後，舊 run 不算數。

## 產品規則（已定，不要改）

- SSR 保底仍是 40，UR 保底仍是 200。
- 保底依購買順序結算，不依開盒順序。
- 種子晚到只會等待。不會因為超過任何時間而退出保底或改成自然稀有度。
- 該盒以及同一帳號排在它後面的保底盒，在種子寫入並依序 `materialize` 之前不能開。

## 離線驗證

編譯器使用倉庫 README 已寫明的 Solidity `0.8.37+commit.f401782d`。Foundry 這個倉庫沒有釘版本；請用你已經信任的 forge 二進位，不要由 `script/verify-offline.sh` 下載。`foundry.toml` 設了 `offline = true`，forge 不該自行抓 solc。

工具要先放在 PATH：`forge`、`solc`（版本字串含 `0.8.37`）、`timeout`、`unshare`、`stat`。程序還要能新建 cgroup，並在 `unshare -Urmn --mount-proc` 裡掛上新的 `/proc`。缺一項就停。

通過檢查之後，同一個腳本才會在唯讀原始碼、獨立 scratch、空環境、無外網、以及 cpu／memory／pids／io／ulimit／10 分鐘牆鐘限制內依序執行：

```sh
forge test -vv
forge build --sizes
forge test -vv --gas-report
```

Gear、Arena、Robots、Forge、Lottery 的 deployed runtime 若超過 24576 bytes，不要部署。

已在 GitHub 標準 `ubuntu-24.04` 的受限容器跑過的只有 commit `7abbb445c02069a673402149e365bec6fc4d3da2`，run https://github.com/agentworldbnb/agentworld-contracts/actions/runs/42408360323 ：17 個測試通過，runtime Gear 23825、Arena 21474、Robots 21190。那次之後的 commit 要重跑同一支 `contract-verify`，不能沿用這組數字。

比對鏈上 bytecode 時，用同一組設定產出標準 JSON（`script/compiler-profile.json`：via-ir、optimizer runs 1、`bytecodeHash: none`、不要 CBOR metadata）。部署前把 `forge inspect <Name> deployedBytecode` 的結果存下來；部署後用唯讀 `eth_getCode` 比對，不一致就停，不要 `unpause`。這個倉庫不代送那筆唯讀請求。

## 要新部署的合約與沿用的合約

新部署：Arena、Lottery、Gear、Forge。這四個的建構子或不可變欄位互相綁死，不能只換其中一個就接到舊的那三個。

沿用（地址以 README 表為準；部署前由擁有者用自己的唯讀方式再看一次公開 getter，不要依這份文件猜鏈上儲存）：

| 角色 | README 記載的原始碼 | README 記載的地址 |
|---|---|---|
| Robots | `src/AgentWorldRobots.sol` | `0x931B026F06D9229a25409dD02C99B8517437cb8c` |
| 遊戲用 Randomness | `src/EpochRandomness.sol` | `0xBe5844A71d5d2F99632FAd9a18AAB5A5B44c888C` |
| Arena 用 Randomness | `src/EpochRandomness.sol` | `0x58f1691c815121E607eaA60e8e9C859A62B2A0A7` |
| Eligibility | `src/SpaceIdAgentEligibility.sol` | `0x6c30D8DceD6383f7a7C5C2421e81e9030D0FbEB9` |

待讀、不要猜：上述合約目前的 owner、`registrar`、`keeper`、`setupDone`、`revealed`、`fusion`、`specialMinter`、`lottery`（舊 Arena 沒有這個欄位）、池子餘額、未結算對戰數、未開盲盒數、抽獎 `status`。這些都是鏈上儲存，本倉庫沒有。

## 接線順序

新合約的 `setupDone` 在 `finishSetup()` 之前才允許直接改國庫與池子地址。接完必須呼叫 `finishSetup()`，否則 owner 仍可立刻改收款地址。Arena 與 Lottery 沒有這道 timelock：Arena 的 treasury 與 poolSink 寫在建構子，Lottery 的 arena 與 randomness 也寫在建構子。

1. 部署 Gear，建構子指向沿用的 eligibility、遊戲用 randomness、沿用的 Robots，以及新的 treasury／poolSink。價格沿用現行程式的上下限。
2. 部署 Forge，建構子指向新 Gear 與同一個遊戲用 randomness。接著 `Forge.setRobots` 指向沿用的 Robots。若仍要圖鑑，`Forge.setCodex` 指向新 Arena（Arena 有 `lightCodex`）。
3. 部署 Arena，建構子指向沿用的 eligibility、Arena 專用 randomness、沿用的 Robots、新 Gear。`Gear.setArena` 指向新 Arena。`Gear.setForge` 指向新 Forge。
4. 部署 Lottery，建構子指向新 Arena 與遊戲用 randomness。`Arena.setLottery` 指向新 Lottery。沒有這一步，`commit` 會 revert。
5. 在 `finishSetup()` 之前設定 Gear 的 treasury、poolSink、seasonSink，以及 Robots 上仍需要的 treasury。然後兩邊都 `finishSetup()`。
6. Randomness `setRegistrar`：遊戲用那份加上新 Gear、新 Forge、新 Lottery。Arena 用那份加上新 Arena。不要取消舊合約的 registrar，直到舊盒子與舊對戰都處理完。
7. Robots `setFusion(新 Forge)`，`setSpecialMinter(新 Gear, true)`，`setSpecialMinter(新 Forge, true)`。確認舊 Gear／舊 Forge 是否仍要保留 minter，依「舊盒還要不要開」決定，不要在沒讀鏈上狀態前關掉。

## 舊合約裡的錢與權益

- 舊 Arena 沒有把未結算獎金搬到新合約的函式。還沒 `settle` 的場若機器人已被燒，舊程式仍會 revert，這份修正幫不到那些場。還沒燒的場仍可在舊 Arena `settle` 再 `claim`。`pause` 會擋住 `settle`，但已經記入 `pending` 的 `claim` 沒有 `whenNotPaused`。切換前先讓該結的場結完，並用 `withdrawHouse` 把 House bankroll 送到舊 treasury，再由 treasury 執行新 Arena 的 `fundHouse`。金額以當時的 `houseBankroll()` 與 `pending` 為準，不要手填。
- 舊 Gear 的未開盒子留在舊合約，保底規則仍是舊的開盒順序。新 Gear 的佇列是空的，不會繼承舊盒子。玩家要開舊盒就繼續對舊 Gear 呼叫 `open`。切換前對舊 Gear `flushPools`，把已入帳的每日池與賽季池送出。
- 舊 Lottery 沒有管理員提款。還沒抽的天只能在舊合約 `draw`／`claim`。放棄舊合約會把餘額留在那裡。新 Lottery 從餘額 0 開始，直到新的 pool sink 開始把 BNB 送進來。
- 新 Forge 看不到舊 Gear 的碎片與裝備。碎片留在舊 Gear 的帳號 key 上，只能對舊 Forge 使用。

## 介面相容

函式簽名沒有刪除既有的 `open`、`buy`、`enter`、`settle`、`claim`、`commit`、`draw`。行為有變：

- `Gear.open` 在前面還有未結算保底盒時會 revert `PityPending`；超過 32 盒時單次 `open` 會整筆回滾，必須先呼叫新增的 `materialize(bytes32,uint256)`。
- `Gear.openMany` 會跳過種子未到或保底尚未輪到的 id，不再假設「種子到了就一定開得成」。
- `Lottery.freeBalance()` 簽名不變，但會再扣掉 `reserved`。
- `Lottery.commit` 會呼叫 Arena 的新函式 `freezeDay`。舊 Arena 沒有這個函式，不能把新 Lottery 指到舊 Arena。
- 新增且前端／keeper 會看到的狀態：`pityCursor`、`rarityReady`、`rolledRarity`、`pityQueueLength`、`dayFrozen`、`lottery`、`reserved`、`committedCount`、`committedPot`。

## 2026-11-08 20:15 操作者提供的唯讀快照

這些數字不是這個 commit 重新讀鏈的結果。部署腳本不得使用它們當交易參數，也不得因此去暫停或搬錢。

- owner `0xb507910F661226232c2511937806B1c732dA59b4`
- Robots 的 paid/free 已關。Gear、Arena、Lottery 的 `paused` 為 false。舊 Gear 的暫停由操作者另外處理，這個倉庫不送那筆交易。
- mint、未開盒、未結算對戰、抽獎欠款都是 0。
- Arena 餘額與 house bankroll 都是 0.2872 BNB。這筆留在舊 Arena，直到操作者自己 `settle`／`claim` 或 `withdrawHouse`。不要在文件或腳本裡寫死這個金額去轉帳。
- TierTable `frozen` 且 `chunksSet` 313。它已部署，新 Arena 用 `setTierTable` 指過去。`AddressTimelock` 是 abstract，不會單獨部署。

## 前端

玩法頁不在這個倉庫。目前公開站點是：

- https://agentworldbnb.com/play/boxes/ 會載入 `/play/boxes.js`
- https://agentworldbnb.com/play/common.js 會抓 `/play/abis.json`
- https://agentworldbnb.com/play/abis.json 的 Gear／Arena／Lottery ABI 沒有 `materialize`、`pityCursor`、`pityQueueLength`、`freezeDay`、`dayFrozen`、`reserved`、`committedPot`、`committedCount`

新合約上線前要改的是那個站點的 `play/abis.json`，以及 `play/boxes.js` 在 `PityPending`、暫停和「種子未到」時的提示。不要把舊 Gear 的購買按鈕指到還沒 `unpause` 的新地址。這個倉庫不能發布該網站。

前端、網站與 keeper 不在這個倉庫。驗收未過，不要開放盲盒，也不要開放付費對戰（新 Arena、新 Gear 維持 `pause`）。

## Lint

run 42408360323 有 233 則 forge lint。分類如下，沒有把它們整批改掉：

- `calls-loop` 55、`require-revert-in-loop` 40：鑄造、結算與保底迴圈本來就有上限（例如每筆最多 32 步、每交易最多 20 隻）。不是未綁定迴圈。
- `reentrancy-events` 32、`reentrancy-no-eth` 3：外部呼叫在事件之前。Arena／Gear／Lottery 的付款入口有 `nonReentrant`，而且先改餘額再送 BNB。同一合約再進會 revert。這不保護跨到另一個合約的唯讀或獨立帳本。
- `reentrancy-eth` 1（`AgentWorldArena._send`）：BNB 只在 `pending`、`seasonPoolWei` 或 `houseBankroll` 已扣掉之後送出，外層有 `nonReentrant`。
- `arbitrary-send-eth` 4：收款人是 treasury、pool sink，或已經記入 `pending` 的玩家，不是呼叫者隨手指定的地址。
- `divide-before-multiply` 11：戰力與括號計算的既有順序。改順序會改變配對，不是這次要動的規則。
- `type-based-tautology` 1：`setFeeLadder` 的 `uint16 > 100_000` 永遠不成立。已改成只保留 uint16 真正做得到的下限與遞增檢查，最高仍是 65535 bps，沒有放進 100000。
- `unsafe-oz-erc721-mint` 4：故意用 `_mint`，讓沒有 `onERC721Received` 的代理錢包也能收。不要改成 `_safeMint`。
- `missing-events-*` 18、`unsafe-typecast` 18、`uninitialized-local` 15、`unused-return` 12、`block-timestamp` 10、`missing-zero-check` 3、`non-reentrant-not-first` 3、`environment-read-across-mutation` 3：沒有發現會重複付款或改保底的路徑。補 event 會增加 bytecode，Gear 當時只剩 751 bytes，所以沒有為了消警告去改。

## 驗收門檻

1. GitHub `contract-verify` 對「將要部署的 commit」成功。`script/verify-offline.sh` 只在本機隔離齊全時才會跑，缺 cgroup 就停，不能代替那支 workflow。
2. `forge build --sizes` 顯示 Gear、Arena、Robots、Forge、Lottery 的 runtime 都未超過 24576 bytes。
3. `test/LaunchPath.t.sol` 在同一支 `forge test` 裡通過。它檢查買盒後種子未到不能開、依購買順序開盒與裝備、對戰結算只付一次、付款回呼不能再買或再領、抽獎 claim 不能重入，以及 `code.length <= 24576`。這不是主網交易。
4. 用測試錢包在你自己的測試環境再走一次真實前端。不要對 README 的主網地址做。
5. 通過後才 `unpause` 新 Gear 與新 Arena，並把前端指到新地址。舊 Arena 的 0.2872 BNB 仍留在舊合約，直到操作者自己處理。

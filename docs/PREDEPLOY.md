# 部署前核對（不廣播、不讀私鑰、不連主網）

這份文件只描述操作順序。它不會送交易。`script/PredeployGuard.sol` 的 `run()` 一律 revert。`script/verify-offline.sh` 在隔離條件缺任何一項時直接結束，不會啟動 forge，也不會安裝軟體。

開盲盒與付費對戰的前提：下面的離線測試、bytecode 大小與 gas 報告都已在隔離環境實際通過。靜態閱讀不算通過。

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

Gear 的 deployed bytecode 若超過 24576 bytes，不要部署，盲盒維持關閉。這次環境沒有 forge／solc，也建不起 cgroup 與隔離的 `/proc`，所以以上三項都還沒跑。

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

前端、網站與 keeper 不在這個倉庫。它們的 ABI 與地址是否已改，無法從這裡確認，部署前要另做端到端驗收。驗收未過，不要開放盲盒，也不要開放付費對戰（新 Arena、新 Gear 維持 `pause`）。

## 驗收門檻

1. `script/verify-offline.sh` 印出 `ISOLATED_FORGE_OK`。
2. `forge build --sizes` 顯示 Gear、Arena、Forge、Lottery 都未超過 24576 bytes。
3. 用測試錢包在你自己的測試環境走完：買盒、等種子、`materialize`、`open`、付費 `enter`、`resolve`、燒或轉出後 `settle`／`claim`、`commit`／`draw`。這一步不在本倉庫的離線測試裡，也不要對 README 的主網地址做。
4. 通過後才 `unpause` 新 Gear 與新 Arena，並把前端指到新地址。

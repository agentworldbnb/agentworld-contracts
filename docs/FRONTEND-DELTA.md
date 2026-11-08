# 前端差額（不是網站、不是編譯產物）

來源 commit：`1452f3674dbdb178322d13fbe87f2f8095be0039`。這份說明和 `docs/frontend-delta-abi.json` 是從該 commit 的原始碼整理的函式簽名。它不是 `solc` 或 `forge inspect abi` 的輸出。隔離 run 42499943486 驗證的是測試與 runtime，沒有產生完整 ABI 檔。真正替換 https://agentworldbnb.com/play/abis.json 之前，仍要用同一組編譯設定在隔離環境跑 `forge inspect <Name> abi`，再和這份片段核對。不要把本倉庫部署成網站。

正式前端來源尚未放進這個工作區。目前公開頁面會載入：

- https://agentworldbnb.com/play/boxes.js
- https://agentworldbnb.com/play/common.js （抓 `/play/abis.json`）
- https://agentworldbnb.com/play/abis.json

那份線上 ABI 沒有下面這些名字。拿到前端原始碼後，要改的是產生 `play/abis.json` 的位置，以及 `boxes.js`、抽獎頁、競技場頁的狀態提示。

## 買盒與開盒

保底仍是 40 次 SSR、200 次 UR。順序是購買順序，不是開盒順序。種子晚到只會等，不會過期。

1. `buy` / `buyMany` 只建立盒子並向 Randomness 登記。此時 `rarityReady(id)` 是 false。
2. 用 `accountKey(buyer)` 取得 `bytes32`。`pityQueueLength(agent)` 是這個帳號排進保底的盒數。碎片兌換盒不在這個長度裡。
3. `pityCursor(agent)` 是下一個尚未結算的位置。`cursor == length` 表示這條佇列都結完了。
4. 種子未到：`open` revert `NotReady`。`openMany` 跳過該 id，回傳成功開出的數量，可能是 0。
5. 種子到了但前面還有沒結算的盒子：`open` 會先 `materialize` 最多 32 步。32 步後那個 id 仍沒好，整筆 revert `PityPending`。前端應改呼叫 `materialize(agent, 32)`，可重複，直到 `pityCursor` 前進到該盒，再 `open`。
6. `materialize` 不鑄裝備。它停在第一個種子還沒到的盒子，不把後面的盒子提前結算。
7. `rolledRarity(id)` 只有在 `rarityReady(id)` 為 true 之後才是已固定的稀有度。`PityFinalized` 的 `pity == true` 表示這次用了保底，而不是自然擲出。
8. `paused()` 為 true，或錯誤 `EnforcedPause`：不要把購買按鈕留在可點狀態。已暫停時 `open` 也會停。

## 抽獎

`commit(day)` 只在 `day + 2 <= today()` 時成功，否則 `DayNotOver`。它會呼叫 Arena 的 `freezeDay(day)`。呼叫者必須是 Arena 的 `lottery()`，否則 Arena revert `NotLottery`。

`dayFrozen(day) == true` 之後，當天新的對戰不再增加 `revenueOnDay` 或合格名單。`committedCount(day)` 與 `committedPot(day)` 是 commit 當下鎖住的人數與獎池。`reserved` 是已鎖、尚未 draw 的 BNB。`freeBalance()` 等於餘額減 `owed` 再減 `reserved`。

人數是 0 時，`commit` 把 `status` 設成 2，不增加 `reserved`。有人時 `status` 先是 1，`draw` 成功後變成 2。`draw` 在種子未到時 revert `NotReady`。`claim` 沒有 `whenNotPaused`，暫停後已記入 `pending` 的獎金仍可領。

# MuseDock 路線圖

這份檔案是「不用每次下指令」的依據。每次自動推進時，先讀這裡，挑一項做完，回來更新它。

**目前版本：v0.18**

---

## 0. 「完美」的操作性定義

不是感覺良好，是六條可以逐項打勾的：

| # | 標準 | 怎麼驗 |
|---|---|---|
| 1 | **沒有靜默失敗** | 每個 `catch` / `try?` 都有對應日誌；使用者可見的失敗一定有提示 |
| 2 | **不可逆損毀全部堵住** | 資料寫入只有一條路徑、有備份；刪除操作可回復或二次確認 |
| 3 | **使用者可見行為有回歸測試** | 貼上、切換、釋放／重建、儲存損壞各有自測入口，且能在 90 秒內跑完 |
| 4 | **零編譯警告** | `./build.sh 2>&1 \| grep warning` 為空 |
| 5 | **單一檔案 < 1500 行** | `wc -l main.swift` |
| 6 | **文件與行為一致** | README / UPDATE / CHANGELOG / DEVELOPER 的版本號、指令、行號對得上 |

第 1、2 條是 v0.18 補上的（日誌落盤、壞檔唯讀），已經達成。
第 3 條部分達成（缺匯入、頭像、多實例的回歸）。
第 4、5、6 條還沒。

---

## 1. 待辦（按優先級）

### P1 — 做完能明顯減少未來的麻煩

#### 1.1 匯入前預檢重複帳號

- **現狀**：`duplicateMap()` 已經存在，但只在匯入／登入完成後才標 ⚠︎，使用者可能已經建出兩張同帳號的卡片。
- **做法**：選擇 Chrome Profile 的那一步（`scanChrome` → 匯入動作之前）先跑一次指紋比對；若該 Profile 的
  cookie 對應到既有帳號，直接提示「這個 Profile 已經匯入成『甲』」，並提供「仍要新增」。
- **完成定義**：同一 Profile 二次匯入時，在寫入任何資料前就出現提示；`MUSE_CHROME_LIST` 輸出多一欄
  `already=<slot>`；文件更新 §4.x。
- **風險**：指紋需要載入頁面才有，匯入前只有 cookie。可以先比 `profileDir`（來源目錄唯一），
  成本幾乎為零，且能覆蓋絕大多數重複匯入。

#### 1.2 熱鍵可自訂

- **現狀**：固定 `⇧⌘1–9`，且編號固定不重排；只有三個帳號時 4–9 是空的。
- **做法**：`Account` 加 `keySlot: Int`（`decodeIfPresent`，預設等於 `slot`）；設定視窗（或選單 →
  「設定快速鍵…」）用 `NSEvent` 錄製；存進 `accounts.json`；衝突時提示。
- **完成定義**：能改單一帳號的熱鍵並持久化；改了之後 `⇧⌘n` 立即生效（不必重啟）；
  `MUSE_KEYTEST` 擴一段驗證「改完後舊鍵失效、新鍵有效」。
- **注意**：`slot` 是身分（刪除不重用），`keySlot` 是快捷鍵（可重排）。**不要把兩者合併**。

#### 1.3 拆 `main.swift`（3284 行）

- **現狀**：單檔包含模型、Store、UI、WebView 控制、診斷入口。
- **做法**：只做機械搬移，不改邏輯。建議順序：`Store.swift`（含 Account、AvatarStore）→
  `WebView.swift`（WKWebView 建立、探測、抽幀）→ `ChromeImport.swift` → `Diagnostics.swift`。
  `build.sh` 的檔案清單同步。
- **完成定義**：`main.swift` < 1500 行；`./build.sh` 零 error；三個自測全 PASS；
  `git diff --stat` 顯示為純搬移（每個檔案的新增行數 ≈ 被刪的行數）。
- **為什麼放 P1 而不是更早**：這是最容易在不知不覺中引入回歸的一步。v0.18 之前沒有日誌，
  拆壞了看不出來；現在有了，但仍要一次只搬一個模組、搬完立刻跑自測。

### P2 — 有空再做

#### 2.1 清掉編譯警告

`Log.setup()` 裡 `_ = try? handle?.seekToEndOfFile()` 的 `try?` 是多餘的（`seekToEndOfFile` 不拋）。
另有幾處 `ImplicitStrongCapture`。目標是第 4 條標準。

#### 2.2 日誌裡的對話標題

`FP` / `FINGERPRINT` 會把左側欄前幾筆對話標題寫進日誌。本機檔案無妨，但若要請人貼日誌排查，
可以只留雜湊。低優先。

#### 2.3 選單列顯示當前帳號

選單列圖示旁顯示 `⇧2` 之類的編號，減少「我現在在哪個帳號」的判斷成本。純 UI，成本小。

### 已否掉（不要做）

| 項目 | 理由 |
|---|---|
| 記憶體壓力自適應（`os_proc_available_memory()`） | 沙箱裡 `ps` 被拒，改完無法用數據證明有效。現有「閒置 10 分鐘」夠 |
| 頭像背景補抓 | 每個帳號多一次頁面訪問，與省資源目標直接衝突 |
| 給 `accounts.json` 加 `schemaVersion` | 格式一改，舊版讀到新檔會走「損壞」分支，等於讓回滾失效。要加必須同時兼容新舊兩版，成本遠大於收益 |
| 自動修復損壞的 JSON | 猜錯會把資料改得更壞。備份 + 讓使用者自己處理是唯一可接受的預設 |

---

## 2. 每次自動推進的規則

1. **一次只做一項**，從 P1 依序往下；做完把該項移到「已完成」，寫上 commit 與版本號。
2. **動手前先跑基線**：`MUSE_STORE_BROKEN_TEST`、`MUSE_STORE_SELFTEST`、`MUSE_KEYTEST` 三項都要 PASS。
   基線不過就先修基線，不要在其上疊新功能。
3. **動手後跑同一組**，全 PASS 才算完成；任何一項 FAIL 就回退該項改動（`git checkout -- <檔案>`）。
4. **文件同步**：`docs/DEVELOPER.md`（相關章節 + 坑，若踩到新的）、`docs/CHANGELOG-vX.md`、
   `docs/UPDATE-vX.md`、README 的版本與索引。
5. **發版**：`./tools/release.sh <新版本> --test`。小版本遞增（0.18 → 0.19）。
6. **卡住就停**：需要使用者決策（例如要不要改檔案格式）或需要真實帳號操作時，寫進第 3 節並結束，
   不要自己猜。

### 快速基線指令

```bash
cd ~/MuseDock

# 1) 壞檔保護
rm -rf /tmp/md-broken && mkdir -p /tmp/md-broken
printf '{"oops": 1}\n' > /tmp/md-broken/accounts.json
MUSE_STATE_DIR=/tmp/md-broken MUSE_STORE_BROKEN_TEST=1 \
  ./MuseDock.app/Contents/MacOS/MuseDock | grep -E "result=|STORE_"

# 2) 首次啟動 + 原子寫
rm -rf /tmp/md-fresh && mkdir -p /tmp/md-fresh
MUSE_STATE_DIR=/tmp/md-fresh MUSE_STORE_SELFTEST=1 \
  ./MuseDock.app/Contents/MacOS/MuseDock | grep "STORE_SELFTEST done"

# 3) 鍵盤路徑（16 秒；--test 發版時也會跑）
rm -rf /tmp/md-key && mkdir -p /tmp/md-key
MUSE_STATE_DIR=/tmp/md-key MUSE_KEYTEST=1 MUSE_DEMO=1 MUSE_START_SLOT=1 \
  ./MuseDock.app/Contents/MacOS/MuseDock | grep "PASTETEST"

# 4) 日誌有沒有異常（應該什麼都不印）
grep -E "STORE_BROKEN|STORE_FROZEN|REFUSE|FP_KEEP|STORE_CONFLICT" \
  ~/Library/Logs/MuseDock.log | tail -20
```

---

## 3. 卡住／待決策

| 日期 | 事項 | 需要誰決定 |
|---|---|---|
| — | （目前沒有） | — |

---

## 4. 已完成

| 版本 | 項目 |
|---|---|
| 0.18 | 儲存加固（壞檔備份 + 唯讀 + GUI 提示）、日誌落盤、`tools/update.sh`、`tools/release.sh`、`MUSE_STORE_BROKEN_TEST` |
| 0.17 | 輸入焦點與貼上路徑（`pasteIntoPage`、`scheduleComposerFocus`） |
| 0.16 | 「編輯」選單、交還第一響應者 |
| 0.15 | 卡片頭像（亮度掃包圍盒自適應裁切） |
| 0.14 | 省資源模式（閒置 10 分鐘釋放 WebView） |
| 0.13 | 單一實例鎖（`flock`） |
| 0.12 | 登入狀態即時化 |

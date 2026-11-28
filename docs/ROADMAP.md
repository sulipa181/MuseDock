# MuseDock 路線圖

這份檔案是「不用每次下指令」的依據。每次自動推進時，先讀這裡，挑一項做完，回來更新它。

**目前版本：v0.20**

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
第 3 條部分達成（貼上、切換、釋放／重建、儲存損壞、匯入預檢有自測入口；缺頭像、多實例的回歸）。
第 4、5、6 條還沒。

---

## 1. 待辦（按優先級）

### P1 — 做完能明顯減少未來的麻煩

#### 1.1 匯入前預檢重複帳號 ✅ v0.19

已做完，細節見 §4 與 `docs/CHANGELOG-v0.19.md`。留下的痕跡：
`ownerOf(profileDir:)`、`confirmReimport()`、`MUSE_CHROME_LIST` 的 `already=<slot>`、`MUSE_IMPORT_PRECHECK`。

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

#### 2.4 `storeID` 不是 UUID 就硬崩

- **現狀**：`webView(for:)` 是 `UUID(uuidString: acc.storeID)!`。手改 `accounts.json`、或從別處抄帳號
  寫成 `"S1"`，啟動即在 `select()` 崩掉（SIGTRAP），日誌只留一行 `IDLE_TIMER`，看起來像「啟動即死」。
- **做法**：解不出 UUID 時不要崩——`Store.load()` 階段就把壞的 storeID 換成新 UUID（並備份原檔），
  或至少 `webView(for:)` 給一個臨時 store 讓畫面能開，同時 `emit("STORE_BAD_UUID …")`。
- **完成定義**：手動把某個帳號的 `storeID` 改成 `"S1"` 後啟動不崩、日誌有一行說明、
  `MUSE_STORE_BADID_TEST` 自測 PASS。**要動 `Store.load`，屬資料層，做之前先確認 §0 第 2 條不被破壞。**
- **由來**：2026-11-28 手動預演每週流程時，用合成 `accounts.json` 造測試資料踩到（見 DEVELOPER 坑 21）。

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
5. **發版**：`./tools/release.sh <新版本> --test`。小版本遞增（0.20 → 0.21）。
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

# 3) 鍵盤路徑（約 10 秒；--test 發版時也會跑）
#    v0.19 起跑完自己結束（PASS→0 / FAIL→1），所以管線會正常返回；
#    自測也不再要求視窗是 key window，看到 dispatched=false key=false 才是真的壞。
rm -rf /tmp/md-key && mkdir -p /tmp/md-key
MUSE_STATE_DIR=/tmp/md-key MUSE_KEYTEST=1 MUSE_DEMO=1 MUSE_START_SLOT=1 \
  ./MuseDock.app/Contents/MacOS/MuseDock | grep -E "PASTETEST|KEYTEST done"

# 4) 日誌有沒有異常（應該什麼都不印）
grep -E "STORE_BROKEN|STORE_FROZEN|REFUSE|FP_KEEP|STORE_CONFLICT" \
  ~/Library/Logs/MuseDock.log | tail -20
```

動到匯入相關的程式碼時，多跑這一條（只讀，不寫資料）：

```bash
MUSE_IMPORT_PRECHECK="Profile 11" ./MuseDock.app/Contents/MacOS/MuseDock | grep PRECHECK
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
| 0.20 | 修正 v0.19 匯入預檢的時機：預檢提前到目標解析之前，「建立新帳號」不再被誤問「已匯入過」；`ownerOf` 忽略空 `profileDir` |
| 0.19 | 匯入前預檢重複帳號（`ownerOf(profileDir:)` + `confirmReimport` + `MUSE_CHROME_LIST already=<slot>` + `MUSE_IMPORT_PRECHECK`）；基線修復（`activateApp()` 走 macOS 14+ API、`PASTETEST` 不再依賴 key window、`MUSE_KEYTEST` 跑完自結束） |
| 0.18 | 儲存加固（壞檔備份 + 唯讀 + GUI 提示）、日誌落盤、`tools/update.sh`、`tools/release.sh`、`MUSE_STORE_BROKEN_TEST` |
| 0.17 | 輸入焦點與貼上路徑（`pasteIntoPage`、`scheduleComposerFocus`） |
| 0.16 | 「編輯」選單、交還第一響應者 |
| 0.15 | 卡片頭像（亮度掃包圍盒自適應裁切） |
| 0.14 | 省資源模式（閒置 10 分鐘釋放 WebView） |
| 0.13 | 單一實例鎖（`flock`） |
| 0.12 | 登入狀態即時化 |

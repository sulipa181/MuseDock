# 變更說明：v0.11 → v0.12

- 日期：2026-11-27
- 範圍：`main.swift`、`build.sh`、`docs/DEVELOPER.md`（新增本文）
- 是否影響既有資料：**不影響**。`accounts.json` 未新增或移除欄位，舊檔可直接沿用
- 是否需重新登入：**不需要**。`storeID` 與 WebKit 資料目錄皆未動
- 版本號：`CFBundleShortVersionString` 0.11 → **0.12**

---

## 1. 一頁摘要

| # | 改動 | 類型 | 使用者感知 |
|---|---|---|---|
| 1 | 登入狀態即時化（`scheduleLoginProbe`） | 新功能 | 圓點會自己變對，不用手動重整才知道 cookie 過期 |
| 2 | 開機自動啟動（`SMAppService`） | 新功能 | 選單多一個可勾選項，登入系統就常駐選單列 |
| 3 | 刪帳號時連 WebKit 資料目錄一起清（`purgeWebsiteDataDir`） | 修正 | 不再留下幾百 KB～幾 MB 的孤兒目錄 |
| 4 | `wipe`（清除網站資料）同樣補刀 | 修正 | 清完是真的乾淨，不會殘留快取 |
| 5 | 刪除／清除邏輯抽成 `performDelete` / `wipeAccount` | 重構 | 無感知，但 UI 與 CLI 走同一條程式碼 |
| 6 | `DEVELOPER.md` §4.4 補程式碼骨架、修三處過期行號 | 文件 | 無感知 |

一句話：**v0.11 把資料清乾淨，v0.12 讓狀態自己對；順手補齊交接文件。**

---

## 2. 逐項說明

### 2.1 登入狀態即時化

**問題**：`loggedIn` 原本只在「匯入當下」寫一次。cookie 過期、Muse 改 session 策略之後，
側邊欄的綠點還是綠的，要手動清除網站資料才發現「其實早就登出了」。

**改法**：新增 `scheduleLoginProbe(for:force:)`（`main.swift:865`），三個時機觸發——
切換帳號（`select`）、頁面載入完成（`didFinish`）、視窗從隱藏恢復（`showWindow`）。
延遲 6 秒後在頁面內執行 `loginProbeJS`，以 `/api/me` 狀態碼 + DOM 是否有輸入框雙重判定，
狀態真的有變才寫檔並重繪。

**關鍵約束**（不是隨便加的，每一條都對應一個實際踩到的問題）：

| 約束 | 原因 |
|---|---|
| 只探 `index == current` | 隱藏的 `WKWebView` 不 hydrate，DOM 沒有輸入框，會被誤判成登出 |
| 只探 `window.isVisible` | 同上；視窗在背景時量測結果不可信 |
| 延遲 6 秒 | SPA 首屏畫完才有輸入框，太早量會 consistently 判成未登入 |
| 節流 180 秒 | 切來切去會連打三次 API，且沒有必要 |
| `loginProbeBusy` 防重入 | 延遲期間可能被 `didFinish` 重複觸發，會同時跑多支 `fetch` |
| 用 `storeID` 重查 index | 6 秒內可能已刪帳號，閉包裡捕獲的 `index` 會位移 |

**已知代價**：只探當前帳號，所以「沒切過去的帳號」圓點仍是舊值，切過去 6 秒內才校正。
這是刻意的取捨——全面探測就得對每個隱藏頁強制 hydrate，記憶體與 API 成本都不划算。

### 2.2 開機自動啟動

**改法**：`SMAppService.mainApp.register()/unregister()`（macOS 13+ 官方 API，不需 helper）。
選單與選單列各有一個勾選項，狀態以 `SMAppService.mainApp.status` 為準（不是自己存旗標）。

**注意**：未註冊時 `status` 是 `.notFound` 而不是 `.notRegistered`，判斷「是否已啟用」一律用
`== .enabled`；若系統要求批准，`status` 會是 `.requiresApproval`，此時選單文字改為
「開機時自動啟動（需在系統設定允許）」，並在狀態列提示去「系統設定 › 一般 › 登入項目」允許。

**前置條件**：App 必須在 `/Applications`（`build.sh` 會自動 `cp -R` 過去），
在 `/tmp` 或 `build` 目錄直接跑會 `register()` 失敗。

### 2.3 刪除帳號一併清資料目錄

**問題**：`removeData(ofTypes: .allWebsiteDataTypes)` 只清 WebKit「認得」的那幾類
（cookie / localStorage / IndexedDB / ServiceWorker 註冊），
`NetworkCache`、`AlternativeServices`、`MediaKeys`、`HSTS`、`ResourceLoadStatistics`
全都留在 `~/Library/WebKit/<bundle-id>/WebsiteDataStore/<storeID>/` 裡，變成孤兒目錄。

**改法**：新增 `Store.purgeWebsiteDataDir(for:completion:)`——
`removeData` 完成後（或 6 秒逾時）在背景佇列直接砍目錄，刪不掉就重試 4 次 ×0.4 秒
（WebKit 可能還握著句柄）。刪除前用 `du -sh` 記下大小，事後在狀態列顯示「釋放 25M」。

**實測**：

| 情境 | 清前 | `removeData` 後 | 補刀後 |
|---|---|---|---|
| 刪除帳號（7.0M 帳號） | 7.0M | 596K | 目錄消失 |
| wipe（7.7M 臨時帳號） | 7.7M | 1.0M | 目錄消失，重建為空 |

**重構**：UI 的 `deleteAccount()` / `wipe()` 只留對話框，實際動作抽到
`performDelete(at:onPurged:)` 與 `wipeAccount(at:done:)`，CLI 的
`MUSE_DROP_SLOT` / `MUSE_WIPE_SLOT` 走同一條路徑——所以自測驗過的行為就是使用者按下去的行為。

`performDelete` 的 `onPurged` 回呼是給 CLI 用的：清完才 `exit(0)`，否則行程先退出，刪除不一定跑完。

### 2.4 文件更新

| 位置 | 內容 |
|---|---|
| §4.4 新增「程式碼骨架」 | `scheduleLoginProbe` 全文（含 ①–⑥ 六段註解）、`loginProbeJS`、三個呼叫點、三個改動地雷 |
| §1 專案結構 | `main.swift` 行數 1794 → **2072** |
| §3 / §4.2 | 過期行號修正：`struct Account` `:7`→`:8`、`select(i)` `:826`→`:953` |

文件 416 行 → 521 行。

---

## 3. 行為差異（使用者視角）

| 場景 | v0.11 | v0.12 |
|---|---|---|
| cookie 過期 | 綠點一直綠，要自己發現 | 6 秒內變灰，狀態列提示「登入已失效（cookie 可能過期）」 |
| 刪除帳號 | 卡片消失，磁碟留 596K 快取 | 卡片消失，目錄整個刪掉，狀態列顯示釋放多少 |
| 清除網站資料 | 殘留 1.0M | 目錄消失，重新載入等於全新身分 |
| 重開機 | 要自己開 App | 勾了「開機時自動啟動」就自動常駐選單列 |
| 選單列帳號清單 | 狀態可能過期 | 每次展開重建，永遠是最新狀態 |

---

## 4. 驗證方式

```bash
cd ~/MuseDock && ./build.sh          # 應無警告、輸出 0.12

# 登入狀態即時化：應印 LOGIN_PROBE ... changed=false（狀態沒變就不寫檔）
MUSE_SHOW=1 MUSE_START_SLOT=1 /Applications/MuseDock.app/Contents/MacOS/MuseDock | grep LOGIN_PROBE

# 開機自啟
MUSE_AUTOSTART=status /Applications/MuseDock.app/Contents/MacOS/MuseDock   # → AUTOSTART cmd=status status=enabled|notFound
MUSE_AUTOSTART=on     /Applications/MuseDock.app/Contents/MacOS/MuseDock   # → status=enabled

# 刪除清目錄（請用測試帳號，不可逆）
MUSE_DROP_SLOT=9 /Applications/MuseDock.app/Contents/MacOS/MuseDock | grep -E "DROP|PURGE"
ls ~/Library/WebKit/local.sulipa.musedock/WebsiteDataStore/ | grep <storeID>   # 應無輸出
```

本次已實測：編譯通過、三個帳號（甲⇧1 / 乙⇧2 / 丙⇧3）登入狀態正確、
刪除與 wipe 的目錄都真的消失、`MUSE_CLOSE_TEST` 關窗後仍 `STILL_RUNNING`。

---

## 5. 風險與回滾

| 風險 | 說明 | 緩解 |
|---|---|---|
| 探測誤判成登出 | 已用「可見 + 當前 + 延遲 6 秒 + `/api/me` + 輸入框」五重條件壓低 | 只寫 `loggedIn` 這個顯示欄位，不動 cookie；誤判不影響實際登入 |
| 目錄刪除不可逆 | `purgeWebsiteDataDir` 直接 `FileManager.removeItem` | 只在使用者明確確認「刪除帳號」或「清除網站資料」後執行；CLI 入口限維護用 |
| 開機自啟殘留 | 直接刪掉 App 不會自動註銷登入項目 | 先關閉勾選再刪；或到「系統設定 › 一般 › 登入項目」移除 |
| 無版本控制 | 專案不在 git 下，改壞了沒有 `git checkout` | 改動前保留上一版 `MuseDock.app`；建議 `git init` + 每次 `build.sh` 後 commit |

**回滾方式**：`accounts.json` 未變更結構，換回舊 `MuseDock.app` 即可，
但舊版不會清理已存在的孤兒目錄（需手動刪）。

---

## 6. 仍未處理（下一版候選）

1. **省資源模式**：切走的帳號釋放 `WKWebView`（保留 `WKWebsiteDataStore`），建議做成「閒置 N 分鐘才釋放」
2. **Muse 真實頭像**：`img[src*="avatar"]` 抓得到，可快取
3. **熱鍵可自訂**：目前固定 `⇧⌘1–9`
4. **單一實例鎖**：`flock` 或 `NSRunningApplication` 檢查，避免兩個行程搶 `accounts.json`
5. **匯入前預檢重複**：指紋命中時直接問「要保留哪一個」

記憶體現況：本體 69MB + GPU 50MB + Networking 18MB + WebContent 116MB ≈ **253MB**（三帳號、
只有當前頁活躍），所以第 1 項不急，第 4 項風險最低、最值得先做。

---

## 附錄：給使用者的三行說明

> 側邊欄的綠點現在會自己更新了，cookie 過期會馬上變灰並提示。
> 刪除帳號或清除資料時，會連快取目錄一起清掉，不再佔用磁碟。
> 選單列可以勾「開機時自動啟動」，登入系統就在背景待命。

# 變更說明：v0.13 → v0.14

- 日期：2026-11-27
- 範圍：`main.swift`（`idleReleaseAfter` / `startIdleTimer` / `releaseIdleWebViews` / `releaseWebView` / `runIdleTest`）、`build.sh`（版本號）、`docs/DEVELOPER.md`（新增 §4.9）
- 是否影響既有資料：**不影響**。`storeID`、WebKit 資料目錄、`accounts.json` 都沒動
- 是否需重新登入：**不需要**。釋放的是 WebView，不是身分
- 版本號：`CFBundleShortVersionString` 0.13 → **0.14**

---

## 1. 一頁摘要

| 改動 | 使用者感知 |
|---|---|
| 切走的帳號閒置 10 分鐘後釋放 `WKWebView` | 記憶體下降；切回該帳號要重新載入頁面（約 2–4 秒），但**不用重新登入** |
| 當前帳號永不釋放 | 正在看的頁面不會突然重載 |
| 釋放時清掉 `loginProbeAt` / `fpAt` | 切回來 6 秒內就會重新校正登入圓點（不清的話會被 180 秒節流擋住） |

一句話：**帳號可以有很多個，同時活著的不需要那麼多。**

---

## 2. 為什麼是「閒置 10 分鐘」而不是「切走就放」

實測使用習慣是「1 → 2 → 1」這種來回對照（同一個問題丟給不同帳號看回覆）。若切走即釋放：

- 每次切換都要重新載入 Muse 的 SPA，2–4 秒白畫面
- 指紋與登入探測都要重跑，圓點會閃一下才對
- WebKit 的 WebContent 行程本來就有暖機成本，頻繁建銷反而更耗 CPU

10 分鐘的依據：來回對照通常在幾十秒到兩分鐘內完成；超過 10 分鐘還在同一個帳號上，
剩下的帳號大概率這一段時間都不會用到。門檻集中在一個地方，可用環境變數覆寫：

```swift
var idleReleaseAfter: TimeInterval {
    Double(ProcessInfo.processInfo.environment["MUSE_IDLE_RELEASE_SEC"] ?? "") ?? 600
}
```

---

## 3. 實作

```
select(i)  → lastActiveAt[storeID] = now

Timer（releaseAfter/5，預設 600s → 每 60s；tolerance 20%）
 └ releaseIdleWebViews()
      ├ keep = 當前帳號（永不釋放）
      ├ 先收成陣列再走訪（邊走訪邊改字典不安全）
      └ idle ≥ 門檻 → releaseWebView(storeID:)

releaseWebView(storeID:)
 ├ webViews.removeValue()            ← 掉最後一個強引用
 ├ stopLoading()、navigationDelegate = nil、removeFromSuperview()
 ├ loginProbeAt / fpAt 清掉
 └ print("RELEASE name=… idle=Ns remain=N")
```

**關鍵細節**：`storeID` 不變、`WKWebsiteDataStore(forIdentifier:)` 不動，
所以重建的 WebView 讀的是同一份磁碟 cookie。切回來只是「重新整理」，不是「重新登入」。

計時器 tick 取門檻的 1/5：預設 10 分鐘 → 每分鐘掃一次（夠即時、又不吵）；
自測設 10 秒 → 每 2 秒掃一次，不必等一分鐘才知道生效。

---

## 4. 驗證

新增自測入口 `MUSE_IDLE_TEST=1`：開 1 號 → 切 2 號 → 等門檻 → 檢查 1 號被釋放 →
再切回 1 號 → 檢查登入探測仍回報已登入。

```console
$ MUSE_IDLE_TEST=1 MUSE_IDLE_RELEASE_SEC=10 /Applications/MuseDock.app/Contents/MacOS/MuseDock
IDLE_TIMER tick=2s releaseAfter=10s
IDLE_TEST step1 select=甲
LOGIN_PROBE name=甲 loggedIn=true api=200 changed=false
IDLE_TEST step2 switch=乙 webViews=1
WEBVIEW rebuilt name=乙 total=2
RELEASE name=甲 idle=15s remain=1
IDLE_TEST result1 PASS（閒置者已釋放）
WEBVIEW rebuilt name=甲 total=2
IDLE_TEST rehydrate select=甲 webViews=2
RELEASE name=乙 idle=14s remain=1
LOGIN_PROBE name=甲 loggedIn=true api=200 changed=false
IDLE_TEST result2 PASS（重建後仍登入）
```

`result2` 證明的是「cookie 還在」：重建後的頁面 `fetch('/api/me')` 回 200、DOM 有輸入框，
所以判為已登入——整個過程沒有任何匯入動作。

### 一個自測踩到的坑

第一版 `result2` 是 FAIL，原因是 `scheduleLoginProbe` 的 180 秒節流：
`loginProbeAt[storeID]` 還留著釋放前的時間戳，重建後的新頁面被判「剛探過」直接跳過，
所以 18 秒內一條 `LOGIN_PROBE` 都沒有。修法是在 `releaseWebView` 裡清掉這兩個時間戳
（新頁面本來就該重新量）。

### 關於記憶體數字

沒有給具體 MB：這台環境的 `ps` 被沙箱擋掉（`operation not permitted: ps`），
抓不到 RSS；`pgrep` 數 WebContent 又會把其他 App 的算進來。所以這裡只保證行為
（WebView 有被釋放、切回仍登入），數字請在本機用「活動監視器」對照：
v0.12 實測單一 WebContent 約 116MB，三個閒置帳號理論上可省 300MB 量級。

---

## 5. 行為差異

| 場景 | v0.13 | v0.14 |
|---|---|---|
| 四個帳號各開一次就放著 | 四份 WebContent 常駐 | 只剩當前那份，其餘 10 分鐘後釋放 |
| 1 → 2 → 1 快速切換 | 立即顯示（SPA 狀態保留） | 立即顯示（10 分鐘內不會被釋放） |
| 閒置 20 分鐘後切回舊帳號 | 立即顯示 | 重新載入 2–4 秒，仍為已登入 |
| 閒置帳號的登入圓點 | 舊值 | 切回後 6 秒內校正（節流已重置） |

---

## 6. 限制

| 項目 | 說明 |
|---|---|
| 門檻固定 | 10 分鐘寫死（可用 `MUSE_IDLE_RELEASE_SEC` 覆寫），沒有依記憶體壓力自適應 |
| 沒有「立即釋放」 | 想馬上省記憶體只能關掉 App 或等門檻；之後可加選單項 |
| 回到舊帳號要等載入 | 2–4 秒白畫面；換來的是不再同時養四份 WebContent |
| WebKit 可能暫留行程 | `WKWebView` dealloc 後 WebContent 由 WebKit 決定何時真正回收，通常數秒內 |

**回滾**：換回 v0.13 的 `MuseDock.app` 即可；`accounts.json` 結構與資料目錄都沒變。

---

## 7. 仍未處理

1. **Muse 真實頭像**：`img[src*="avatar"]` 可抓
2. **熱鍵可自訂**：目前固定 `⇧⌘1–9`
3. **匯入前預檢重複**：指紋命中時直接問「要保留哪一個」
4. **記憶體壓力自適應**：依 `os_proc_available_memory()` 動態收緊門檻

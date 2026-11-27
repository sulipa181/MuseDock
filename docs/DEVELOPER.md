# MuseDock 開發說明（v0.14）

一個 macOS 原生的小工具，把多個 Muse（muse.ai）帳號集中在同一個視窗裡切換，
每個帳號各自擁有**完全隔離的 Cookie / 網站資料**，互不干擾。

- 形態：單一 `NSApplication`，純程式碼建 UI（無 Xcode 專案、無 storyboard、無第三方套件）
- 語言／工具鏈：Swift 6（`swiftc` 直編）、AppKit、WebKit、Carbon（全域熱鍵）、SQLite3（讀 Chrome cookie）
- 產物：`MuseDock.app`（ad-hoc 簽章，本機執行）
- 平台：macOS 14+ / arm64
- 目前版本：`CFBundleShortVersionString 0.14`

**目錄**：[1 專案結構](#1-專案結構)｜[2 架構總覽](#2-架構總覽)｜[3 資料模型](#3-資料模型)｜[4 核心流程](#4-核心流程)｜[5 UI 規格](#5-ui-規格)｜[6 選單列常駐](#6-選單列常駐)｜[7 踩過的坑](#7-踩過的坑改動前務必看)｜[8 診斷入口](#8-診斷與自測入口)｜[9 已知限制](#9-已知限制--技術債)｜[10 下一步](#10-建議下一步)｜[11 版本沿革](#11-版本沿革)｜[12 檢查清單](#12-接手檢查清單)

---

## 1. 專案結構

```
~/MuseDock/
├── main.swift            2471 行   全部 UI + Controller + 診斷入口
├── ChromeCookies.swift    313 行   Chrome Profile 掃描與 cookie 解密
├── build.sh                53 行   編譯、打包 Info.plist、簽章、同步到 /Applications
├── AppIcon.icns / .png            程式化繪製的圖示（10 個尺寸）
├── tools/
│   ├── draw_icon.py       181 行   PIL 4096px 超取樣繪製圖示
│   └── make_sheet.py       48 行   多張截圖拼版（僅開發用）
├── docs/screenshot-demo.png       示範截圖（用 MUSE_STATE_DIR 跑假資料產生）
└── docs/
    ├── DEVELOPER.md               本文件
    ├── CHANGELOG-v0.12.md         v0.11 → v0.12 變更說明（交接用）
    ├── CHANGELOG-v0.13.md         v0.12 → v0.13 變更說明（單一實例鎖）
    └── CHANGELOG-v0.14.md         v0.13 → v0.14 變更說明（省資源模式）
```

執行期資料（不在 repo 內）：

```
~/Library/Application Support/MuseDock/accounts.json    ← 唯一的狀態檔
~/Library/WebKit/local.sulipa.musedock/WebsiteDataStore/<storeID>/   ← WebKit 依 storeID 自動管理
```

### 建置

```bash
cd ~/MuseDock && ./build.sh
```

做的事：`rm -rf MuseDock.app` → 編譯 `main.swift ChromeCookies.swift` → 寫 `Info.plist`
→ 打包 `AppIcon.icns` → `codesign -s -`（ad-hoc，失敗不中斷）→ `cp -R` 到 `/Applications`。

編譯旗標（改動前先看）：

```bash
swiftc -O -target arm64-apple-macos14.0 \
  -framework AppKit -framework WebKit \
  -lsqlite3 \
  -o MuseDock.app/Contents/MacOS/MuseDock main.swift ChromeCookies.swift
```

> 只依賴 Command Line Tools，不需要 Xcode。`-lsqlite3` 是給 `ChromeCookies` 用的。

---

## 2. 架構總覽

```
                    ┌──────────────────────────────┐
                    │ NSStatusItem (menu bar)      │
                    └──────────────┬───────────────┘
                                   │ pick account / show / import
┌──────────────────┐   click     ┌─▼─────────────────────────────┐
│ SidebarView      │────────────▶│ Controller                    │
│ fixed 280 pt     │  hotkey     │  accounts: [Account]          │
│ AccountCard ...  │◀────────────│  current: Int                 │
└──────────────────┘  rebuild    │  webViews[storeID: WKWebView] │
                                 └───────────────┬───────────────┘
                                                 │ select(i)
                                                 ▼
                                 ┌───────────────▼───────────────┐
                                 │  contentHost (right pane)     │
                                 │  one WKWebView at a time      │
                                 └───────────────┬───────────────┘
                                                 │ per-account store
                                                 ▼
                            WKWebsiteDataStore(forIdentifier: storeID)
                            cookie / localStorage / IndexedDB 完全隔離
```

### 關鍵設計決定

| 決定 | 原因 |
|---|---|
| 用 `WKWebsiteDataStore(forIdentifier:)` 而非 `WKProcessPool` 或分開 App | 這是 WebKit 官方支援的「多身分」方式，同一行程內可開多份完全隔離的儲存，不必複製 App 或切換系統使用者 |
| 每個帳號一個 `WKWebView`，只把當前那個塞進 `contentHost`；切走的閒置 10 分鐘後釋放（v0.14） | 切換要快（保留 SPA 狀態、不必重載），但四個帳號各養一個 WebContent 太貴，所以用「閒置才回收」折中 |
| 側邊欄固定 280pt，用 Auto Layout 硬約束 | `NSSplitView.setPosition` 在視窗尚未顯示時無效，曾導致側邊欄只有 100pt |
| 藍色按鈕 `AccentButton` 自繪 | `NSButton.bezelColor` 在部分外觀下渲染成灰色 |
| 「已登入」以 `/api/me` 狀態碼 + 是否有輸入框判斷 | 頁面出現 "Sign in" 字樣在登入後也存在，會誤判 |
| 全域熱鍵走 Carbon `RegisterEventHotKey` | 不需要「輔助使用」權限，也不必裝事件監聽 |

---

## 3. 資料模型

### `struct Account`（`main.swift:8`）

| 欄位 | 型別 | 說明 |
|---|---|---|
| `name` | String | 顯示名稱，也是比對 Chrome Profile 的鍵 |
| `email` | String | **Chrome 的 Google 帳號**（不是 Muse 帳號，Muse 前端不暴露），無值時為 `"未登入"` |
| `storeID` | String(UUID) | 隔離儲存的識別碼，`WKWebsiteDataStore(forIdentifier:)` 的 key，**一旦建立不可變** |
| `group` | String | `"主力"` / `"備用"`，只影響排序 |
| `slot` | Int | 固定編號（1 起），決定徽章 `⇧3` 與熱鍵 `⇧⌘3`；**刪除後不重用** |
| `loggedIn` | Bool | 由載入探測回寫，非使用者手動設定 |
| `profileDir` | String | 來源 Chrome Profile 目錄（如 `Profile 11`），空字串＝非 Chrome 匯入 |
| `fingerprint` | String | 樣本雜湊 `v1|<筆數>|<hash>`，僅用於變更偵測與診斷 |
| `fpItems` | [String] | 左側欄對話標題樣本（≤24 筆），重複偵測的實際依據 |

### 持久化與相容性

- 位置：`~/Library/Application Support/MuseDock/accounts.json`（`Store`）
- **所有欄位都用 `decodeIfPresent` + 預設值**，新增欄位不會讓舊檔解不開（這點請維持）
- `Store.load()` 會補 `slot <= 0` 的舊資料，用「現有最大值 + 1」往後遞增
- `slot` 只增不減：刪除 4 號後再新增，會拿到 5 號，避免熱鍵與肌肉記憶錯亂
- 不要手動改 `storeID`：改了等於換一個空白身分，登入態會「消失」

### 寫入安全性（v0.13）

`Store.save()` 不是裸的 `data.write`，三件事一起做：

| 措施 | 為什麼 |
|---|---|
| `options: .atomic`（同目錄暫存檔 → rename） | 中途被 `kill` 不會留下半截 JSON；讀取端只會看到「舊的完整檔」或「新的完整檔」 |
| `flock(LOCK_EX)` on `accounts.lock` | 跨行程序列化寫入；`load()` 持 `LOCK_SH`，避開 rename 的瞬間 |
| 寫前比對內容指紋（`lastDigest`，FNV-1a 64） | 檔案若被別的行程改過，先印 `STORE_CONFLICT` 再覆寫——蓋是蓋，但留下痕跡，不會變成「帳號無聲消失」 |

實測（`MUSE_STORE_SELFTEST=1` 寫 200 次，外部每 1ms 解析一次，共 1468 次取樣）：0 次讀到空檔或半截 JSON。

> `accounts.lock` 與 `instance.lock` 是兩個不同層級的鎖：前者只管「這幾毫秒的檔案讀寫」，
> 後者管「整個 App 只能有一個」。前者不能取代後者——它防不了邏輯層的 lost update。

---

## 4. 核心流程

### 4.1 啟動

```
init()
 ├ Store.load()                      讀 accounts.json（首次執行寫入 4 筆種子資料）
 ├ 建 NSWindow(1240×840) + 側邊欄 + contentHost
 ├ syncChromeIdentity()              用 Chrome Profile 補 profileDir / email（只補空的）
 ├ rebuildCards()                    建卡片（依 visualOrder：主力在前）
 ├ buildMenu() / setupStatusItem()   主選單 + 選單列圖示
 ├ reportDuplicates()                有重複就在狀態列提示
 └ select(MUSE_START_SLOT 或 0)      載入第一個帳號；無帳號則顯示空狀態
```

### 4.2 切換帳號

`select(i)`（`main.swift:962`）是唯一入口，三種觸發都收斂到這裡：

1. 點卡片 → `AccountCard.onClick`
2. 全域熱鍵 → `selectHotKey(n)` → 以 `slot == n` 反查 index
3. 選單列／主選單 → `statusPick` / `switchTo`

流程：更新 `current` → 重設卡片選取態 → 移除 `contentHost` 子視圖 → 放入該帳號的
`WKWebView`（沒有就建）→ 若尚未載入則 `load(muse.ai)` → 更新標題與狀態列 → 排程指紋取樣。

> 熱鍵與 `slot` 綁定，不是陣列索引，所以刪帳號、換分組都不會改變 ⇧⌘n 的意義。

### 4.3 從 Chrome 匯入（主要登入路徑）

```
使用者：側邊欄 ⋯ → 從 Chrome 匯入 → 選 Profile
   ↓
importChromeProfile(_:)                      main.swift
   ├ ChromeCookies.profiles()   讀 Local State 列出所有 Profile（名稱/email/上次使用/muse cookie 數）
   ├ 目標帳號：名稱完全相同 → 直接用；否則忽略大小寫；再否則彈窗問「匯入當前 / 建立新帳號 / 取消」
   ├ 背景執行緒：ChromeCookies.cookies(for: dir)   解密出 [HTTPCookie]
   └ 主執行緒：install(cookies:into:source:email:profileDir:)
          ├ 逐筆寫入該帳號的 WKWebsiteDataStore.httpCookieStore
          ├ loggedIn = true、補 email、補 profileDir
          ├ Store.save() → rebuildCards() → select(idx)
          └ 重新載入 muse.ai（探測後回寫真實登入狀態）
```

備援路徑：`從 cookies.txt 匯入…`（Netscape 格式，`CookieParser.parse(netscape:)`），
給沒有 Chrome 的機器或手動匯出用。

### 4.4 登入狀態判定（v0.12 起即時化）

兩條路徑共用同一支判定邏輯，差別只在「誰觸發、要不要截圖退出」：

| 路徑 | 觸發 | 用途 |
|---|---|---|
| `scheduleLoginProbe(for:)` | `didFinish`／`select()`／`showWindow()`，延遲 6 秒 | 平常使用時即時更新圓點 |
| 匯入探測（`PROBE_MODE`） | `MUSE_IMPORT_FILE`／`MUSE_CHROME_APPLY`，延遲 `MUSE_PROBE_WAIT` | 匯入後驗證，順便截圖、必要時自動一鍵登入 |

判定 JS：

```
fetch('/api/me' → '/api/user' → '/api/session', {credentials:'include'})
├ 401 或回應含 Authentication required → 未登入
└ 否則再確認 DOM 有輸入框（傳送訊息 / Send message）→ 已登入
```

回寫 `accounts.json` 的 `loggedIn` → `rebuildCards()` 更新圓點；
若翻成未登入且是當前帳號，狀態列顯示「⚠︎ X 的登入已失效（cookie 可能過期）」。

**為什麼只探當前、可見的那個帳號**（`index == current && window.isVisible`）：

- 隱藏的 `WKWebView` 不 hydrate（§7 坑 1），DOM 沒有輸入框 → 會被誤判成登出
- 一次只探一個，省掉三個 `fetch` 同時打 API

節流 180 秒（`loginProbeInterval`），`force: true` 可繞過；`loginProbeBusy` 防重入。

#### 程式碼骨架（`main.swift:851–912`）

```swift
// 狀態（Controller 成員）
var loginProbeBusy: Set<String> = []      // 探測中的 storeID，防重入
var loginProbeAt: [String: Date] = [:]    // 各 storeID 上次探測時間，節流用
let loginProbeInterval: TimeInterval = 180

/// 探測某個帳號現在的登入狀態，並回寫 loggedIn。
/// 只在「當前、且視窗可見」的帳號上跑：隱藏時 Next.js 不 hydrate，
/// DOM 沒有輸入框會被誤判成登出。
func scheduleLoginProbe(for index: Int, force: Bool = false) {

    // ① 五道前置檢查，任一不過就安靜返回（不報錯、不提示）
    guard accounts.indices.contains(index), index == current else { return }  // 只探當前帳號
    guard window.isVisible else { return }                                    // 視窗不可見不探（坑 1）
    let acc = accounts[index]
    guard let w = webViews[acc.storeID],                                     // 必須已有 WebView
          w.url?.host?.contains("muse.ai") == true else { return }
    guard !loginProbeBusy.contains(acc.storeID) else { return }              // 防重入
    if !force, let t = loginProbeAt[acc.storeID],
       Date().timeIntervalSince(t) < loginProbeInterval { return }            // 180s 節流

    // ② 先上鎖再排程：鎖在「開始探測」時就標記，不是等延遲結束才標
    loginProbeBusy.insert(acc.storeID)
    loginProbeAt[acc.storeID] = Date()
    let storeID = acc.storeID

    // ③ 延遲 6 秒，等 SPA 把側邊欄與輸入框畫完
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak w] in
        guard let self, let w, w.url?.host?.contains("muse.ai") == true else {
            self?.loginProbeBusy.remove(storeID)   // 提早失敗也要解鎖，否則這帳號永久卡住
            return
        }

        // ④ 在頁面上下文執行 loginProbeJS，回傳 JSON 字串
        w.callAsyncJavaScript(self.loginProbeJS, arguments: [:], in: nil, in: .page) { r in
            self.loginProbeBusy.remove(storeID)     // 無論成敗都解鎖

            // ⑤ 解析結果。注意：用 storeID 重新查 index，不信任傳入的 index
            //    （6 秒 + 網路時間內可能已刪帳號，陣列已位移）
            guard case .success(let v) = r, let text = v as? String,
                  let data = text.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let idx = self.accounts.firstIndex(where: { $0.storeID == storeID })
            else { return }

            let loggedIn = (obj["loggedIn"] as? Bool) ?? false
            let api      = (obj["api"] as? Int) ?? 0
            let changed  = self.accounts[idx].loggedIn != loggedIn
            print("LOGIN_PROBE name=\(self.accounts[idx].name) loggedIn=\(loggedIn) api=\(api) changed=\(changed)")

            // ⑥ 只有狀態真的翻了才寫檔 + 重繪，避免每 3 分鐘無謂 I/O
            guard changed else { return }
            self.accounts[idx].loggedIn = loggedIn
            Store.save(self.accounts)
            self.rebuildCards()
            if idx == self.current {
                self.statusLabel.stringValue = loggedIn
                    ? "\(self.accounts[idx].name) 已登入"
                    : "⚠︎ \(self.accounts[idx].name) 的登入已失效（cookie 可能過期）"
            }
        }
    }
}
```

判定腳本（`loginProbeJS`，省略 try/catch 細節）：

```javascript
return await (async () => {
  let apiStatus = 0, apiBody = '';
  for (const p of ['/api/me', '/api/user', '/api/session']) {
    try {
      const r = await fetch(p, {credentials: 'include'});
      apiStatus = r.status;
      const t = await r.text();
      if (r.status !== 404) { apiBody = p + ' => ' + t.slice(0, 160); break; }
    } catch (e) { apiBody = 'err ' + e.message; }
  }
  const b = document.body;
  const html = b ? b.innerHTML : '';
  const hasSend = /傳送訊息|Send message|Send a message/i.test(html);
  const loggedIn = apiStatus !== 401 && !/Authentication required/.test(apiBody) && hasSend;
  return JSON.stringify({ loggedIn, api: apiStatus, hasSend,
                          visibility: document.visibilityState, url: location.href, apiBody });
})();
```

呼叫點（三處，皆不帶 `force`）：

| 位置 | 時機 |
|---|---|
| `select(_:)` 結尾 | 切換到某帳號後 |
| `webView(_:didFinish:)` | 頁面每次載入完成（含重新載入、登入後跳轉） |
| `showWindow()` | 視窗從隱藏恢復可見時補一次 |

`force: true` 目前只有自測腳本會用（要立刻校正而不等 180 秒）。

**改動時的三個地雷**：

1. 別把上鎖（`loginProbeBusy.insert`）搬到延遲區塊裡——延遲期間仍可能被其他事件重複呼叫，會同時跑好幾支 `fetch`。
2. 任何提前 `return` 的路徑都要 `loginProbeBusy.remove(storeID)`，漏一個就讓該帳號永久不再探測（不是崩，是「圓點從此不動」，很難查）。
3. 回寫時一定要用 `storeID` 重查 index，不要用閉包捕獲的 `index`。

### 4.5 重複帳號偵測（v0.10）

同一個 Muse 帳號被兩個 Chrome Profile 登入是很常見的（實際遇過 1 號與 4 號）。
Muse 前端拿不到帳號 email，session token 每次登入都不同，**唯一可靠的識別是對話列表**。

```
select / didFinish
   └ scheduleFingerprint(for: attempt:)
        ├ 條件：已登入、有 WebView、同 storeID 3 分鐘內不重算、不重入
        ├ 延遲 7 秒（等 SPA 把側邊欄畫完）→ 執行 fingerprintJS
        │    取左側欄（x<400）可見節點的文字，去重、排序、取前 24 筆
        │    過濾結構字：主要聊天室 / 頻道 / 副聊天室 / 傳送訊息 / 新增 / 搜尋 …
        │    回傳 { n, hash, items, all }
        ├ n < 2 → 視為樣本不足，重試一次（可能還在載入）
        └ 寫入 fpItems / fingerprint → rebuildCards() → reportDuplicates()
```

比對（`Account.sameAccount(as:)`）：

| 情況 | 判定 |
|---|---|
| 兩邊都 ≥ 3 筆 | 共同標題 ≥ 3 **且** 共同數 / 較少方筆數 ≥ 0.6 |
| 只有 2 筆 | 必須完全一致（樣本少時寧可漏判） |

命中後的呈現：

- 卡片右上角橙色 `⚠︎`，tooltip「與 1 號（甲）是同一個 Muse 帳號」
- 選單列下拉與主選單該項後綴「⚠︎ 同 1 號」
- 狀態列「⚠︎ 偵測到重複帳號：3 號（丙）與 1 號相同」

`duplicateMap()` 以 `slot` 小的為基準，只標後面那個；回傳 `[重複者 index: 原帳號 index]`。

> 限制：指紋需要頁面真的渲染過（見坑 1），所以只有「被打開過的帳號」才有樣本。
> 樣本會持久化，第二次啟動即可比對。

### 4.6 刪除帳號

`deleteAccount()` 只負責對話框，確認後呼叫 `performDelete(at:)`（自測入口 `MUSE_DROP_SLOT` 也走這條）：

```
performDelete(at: index)
  ├ beforeSize = du -sh 資料目錄            ← 用來在狀態列顯示釋放多少
  ├ 丟掉 WebView（stopLoading + removeFromSuperview）
  ├ removeData(ofTypes: .allWebsiteDataTypes)   ← WebKit 清 cookie/localStorage/IndexedDB
  │    └ 完成後（或 6 秒逾時）→ Store.purgeWebsiteDataDir(for: storeID)
  │         └ 砍 ~/Library/WebKit/<bundle-id>/WebsiteDataStore/<storeID>/
  │              刪不掉就重試 4 次 ×0.4s（WebKit 可能還握著句柄）
  ├ 從陣列移除 → 重繪 → 修正 current → 選下一個
  └ 狀態列：已刪除 X（編號保留不重用），釋放 25M
```

**為什麼要補刀**：`removeData(.allWebsiteDataTypes)` 只清 cookie / localStorage / IndexedDB /
ServiceWorker 註冊那幾類，`NetworkCache`、`AlternativeServices`、`MediaKeys`、`HSTS`、
`ResourceLoadStatistics` 都留在目錄裡。實測一個 7.0M 的帳號 `removeData` 後仍殘留 596K，
補刀後目錄才真的消失。

`performDelete` 的 `onPurged` 回呼讓 CLI 能在清完之後才 `exit(0)`（否則行程先退出，刪除不一定跑完）。

### 4.7 清除網站資料（`wipe`）

`wipe()` 只是對話框入口，實際邏輯在 `wipeAccount(at:done:)`（自測入口 `MUSE_WIPE_SLOT` 共用）：

```
wipeAccount(at: index)
  ├ removeData(.allWebsiteDataTypes)          ← 同上，只清 WebKit 認得的那幾類
  ├ 丟掉 WebView → loggedIn = false → 存檔 → 重繪
  ├ Store.purgeWebsiteDataDir(for: storeID)   ← 補刀，跟刪帳號用同一支
  └ select(index) 重建一個乾淨的 WebView（WebKit 會重新開一個空目錄）
```

與 `performDelete` 的差別只有「帳號是否留下」：wipe 保留卡片與編號，清完自動重新載入（等於在 App 內登出）。
實測臨時帳號：7.7M → `removeData` 後 1.0M → 補刀後目錄消失，重建的 WebView 從零開始。

---

### 4.8 單一實例鎖（v0.13）

**問題**：連點兩次、或「終端機跑一支自測 + App 已經開著」，會有兩個行程同時讀寫
`accounts.json`。`Store.save()` 是整檔覆寫，後寫的把先寫的蓋掉——不是鎖檔，是**直接少帳號**
（卡片消失、對應的 WebKit 目錄變孤兒）。

**做法**：`flock(LOCK_EX | LOCK_NB)` 鎖住 `~/Library/Application Support/MuseDock/instance.lock`。

```
行程啟動
 ├ 判斷模式
 │   ├ 一般啟動    → 搶排他鎖
 │   ├ 寫入型 CLI  → 搶排他鎖（DROP_SLOT / WIPE_SLOT / IMPORT_FILE / CHROME_APPLY）
 │   └ 唯讀 CLI    → 不搶（SNAPSHOT / STATUS_TEST / CLOSE_TEST / CHROME_LIST / CHROME_IMPORT / WHO / AUTOSTART）
 ├ 搶到 → fd 保持開啟，印 INSTANCE_LOCK acquired pid=…
 └ 沒搶到
     ├ 一般啟動  → 發通知叫回既有視窗 → activate → exit(0)，印 SINGLE_INSTANCE already running pid=…
     └ 寫入型 CLI → exit(3)，印 REFUSE …（不與執行中的實例並存）
```

為什麼用 `flock`，而不是 pid 檔或 `NSRunningApplication`：

| 方案 | 問題 |
|---|---|
| pid 檔 + `kill(pid, 0)` | `kill -9`、斷電後留下殘留檔；pid 還可能被新行程重用 → 誤判「已在執行」，只能手動刪檔 |
| 只查 `NSRunningApplication` | 兩個行程「同時」啟動時雙方都還沒註冊完，都查不到對方，兩個都活著（典型 TOCTOU） |
| `flock` | 仲裁在 kernel：`close(fd)` 或行程結束（含 crash／`kill -9`）自動釋放，無殘留、無競態 |

`NSRunningApplication` 仍有用，但只用來做「叫醒既有實例」的體驗（`activate`），不用來判斷該不該啟動。

**唯讀 CLI 為什麼放行**：開發時常一邊開著 App 一邊 `MUSE_SNAPSHOT` 截圖、`MUSE_STATUS_TEST`
看選單結構；若一律擋掉就得每次先關 App。這些模式只讀 `accounts.json`，不會寫回。

**為什麼要發通知，不能只 `activate`**：常駐模式下關窗只是 `orderOut`，App 沒有可見視窗，
單純 `activate` 拉不回來。所以第二個行程先發 `local.sulipa.musedock.show`
（`DistributedNotificationCenter`），由執行中的實例呼叫 `showWindow()`，再 `activate`。

**第二層保護在 `Store` 裡**：即使實例鎖被繞過（例如把 App 複製成兩個不同 bundle id），
`save()` 仍會持 `accounts.lock`、用原子寫入，並在指紋不符時印 `STORE_CONFLICT`。
分工是：實例鎖負責「正常路徑上不該出現第二個」，檔案鎖負責「真的出現第二個時，
至少不要寫出壞檔，而且要留下痕跡」。

### 4.9 省資源模式（v0.14）

**問題**：每個帳號一個 `WKWebView` 意味著每個帳號一份 WebContent 子行程。四個帳號就是四份，
即使三個都在背景發呆。這是整個 App 最大的記憶體支出來源。

**取捨**：切走的帳號不能立刻釋放——使用者常常「1 → 2 → 1」來回看，
每次都重建就要重新載入 SPA（好幾秒）。所以做成**閒置 10 分鐘才釋放**。

```
select(i)
 └ lastActiveAt[storeID] = now          ← 標記「這個帳號在用」

Timer（每 releaseAfter/5 秒，預設 10 分鐘 → 每 60 秒）
 └ releaseIdleWebViews()
      ├ keep = 當前帳號（永不釋放，即使閒置）
      ├ 對其他每個 webViews：idle = now - lastActiveAt[storeID]
      └ idle >= idleReleaseAfter → releaseWebView(storeID:)

releaseWebView(storeID:)
 ├ webViews.removeValue(storeID)        ← 掉最後一個強引用，WKWebView 才會 dealloc
 ├ stopLoading() / navigationDelegate = nil / removeFromSuperview()
 ├ loginProbeAt / fpAt 清掉            ← 新頁面是全新載入，舊節流不該延用
 └ print("RELEASE name=… idle=Ns remain=N")
```

**釋放的是 WebView，不是身分**：`storeID` 不動，`WKWebsiteDataStore(forIdentifier:)` 指到的
磁碟目錄也不動。切回來時 `webView(for:)` 依同一個 `storeID` 重建 WebView，cookie 還在，
等於只是「重新整理頁面」，不會被登出。

**為什麼要清 `loginProbeAt` / `fpAt`**：這兩個是節流用的時間戳。釋放後重建的頁面其實是全新載入，
如果延用舊時間戳，登入探測會被 180 秒節流擋掉，卡片圓點會停在釋放前的狀態——自測時就踩到這個，
症狀是「重建後 18 秒內沒有任何 LOGIN_PROBE」。

**沒有做的事**：手動「立即釋放」按鈕、以及依記憶體壓力自動調整門檻。
10 分鐘是固定值，可用 `MUSE_IDLE_RELEASE_SEC` 覆寫（自測用）。

---

## 5. UI 規格

| 元素 | 規格 |
|---|---|
| 視窗 | 1240×840，最小 900×600，`fullSizeContentView` + 透明標題列；`isReleasedWhenClosed = false` |
| 側邊欄 | 固定 280pt，右側 1px hairline 分隔線 |
| 卡片 | 高 64pt、圓角 10、選取時 accent 13% 底 + 0.75 邊框、hover 7% 灰 |
| 卡片內容 | 32pt 首字母圓頭像（`Palette` 6 色盤，djb2 由名稱取色）／名稱 14 semibold／`⇧n` 徽章／狀態點 5pt／副標題 11pt |
| 副標題 | `Profile 11 · user@example.com`；無來源則只顯示 email；都沒有則 `已登入 · cookie 匯入` / `未登入` |
| 群組標題 | 10.5 semibold、tertiary、字距 0.6 |
| 顏色 | `Theme.dynamic(light:dark:)`，跟隨系統外觀；`Theme.accent`、`Theme.hairline` |
| 字型 | 系統字（預設），中文靠系統 PingFang |

> 截圖用離屏渲染時不能指定 `PingFang` 字型名稱（在 CLI 環境取不到），要用 `Hiragino Sans GB.ttc`。

---

## 6. 選單列常駐

- `NSStatusItem`，圖示 `rectangle.stack.fill`（template，深淺色自動反白）
- 選單用 `NSMenuDelegate.menuNeedsUpdate` **每次展開重建**，所以登入狀態、重複標記永遠是最新的
- 內容：當前帳號／帳號清單（綠灰點 + ◉ + ⚠︎）／隱藏視窗／重新載入／從 Chrome 匯入／新增帳號／開機時自動啟動／結束
- 生命週期：
  - `applicationShouldTerminateAfterLastWindowClosed → false`
  - `window.isReleasedWhenClosed = false`
  - 關窗只是 `orderOut`，行程續留；Dock 點擊、選單列、熱鍵都能叫回
  - 完全退出：⌘Q 或選單「結束 MuseDock」

---

## 7. 踩過的坑（改動前務必看）

1. **`WKWebView` 不可見就不 hydrate**：視窗沒 `orderFrontRegardless()` 時 Next.js 不渲染，
   截圖全黑、`visibility: hidden`、`innerText` 為空。所有要讀 DOM 的自測都必須先讓視窗真正顯示。
2. **`NSSplitView.setPosition` 在視窗顯示前無效**：側邊欄會維持 100pt。改用固定寬度約束。
3. **`NSButton.bezelColor` 藍色渲染成灰色**：自繪 `AccentButton`。
4. **Chrome cookie 金鑰**：`PBKDF2-HMAC-SHA1(password, "saltysalt", 1003, 16)`，
   password 要取 `Chrome Safe Storage` 的**原始字串**（不可 base64 解碼）。IV 是 16 個空格。
5. **Chrome 130+ 的 cookie 前綴**：解密後前 32 bytes 是 `sha256(host)`，要剝掉；`v10`/`v11` 前綴要先去掉。
6. **一鍵登入按鈕**：只 `element.click()` 沒用，必須派發
   `pointerdown → mousedown → pointerup → mouseup → click` 完整序列；且要用「文字精確為登入、寬度最接近整卡」的按鈕，否則會點到頁首。
7. **Chrome Profile 名稱撞名**：`Default` 叫 "Sulipa"、`Profile 2` 叫 "sulipa"。
   `ChromeCookies.profile(matching:in:)` 規則是**先精確、再忽略大小寫**，不要改回單純 lowercase 比對。
8. **取得金鑰的方式**：用 `/usr/bin/security find-generic-password`（已授權的系統工具），
   不要用 `SecItemCopyMatching`，後者會反覆彈鑰匙串視窗。
9. **登入判定不要看頁面文字**："Sign in" 在登入後仍有；一律以 `/api/me` 狀態碼為準。
10. **沙箱內啟動 Chrome 會失敗**：只有使用者雙擊才能開 Chrome；匯入只需讀檔案，不受影響。
11. **單一實例鎖的 fd 要活到行程結束**：`InstanceLock.acquire()` 回傳的 fd 一旦 `close()` 就等於放鎖；
    別把它包進 `defer` 或區域變數作用域，也別「用完就關」。另外鎖檔本身留著沒關係（內容是 pid，僅供提示），
    **判斷是否持鎖只看 `flock` 的回傳值，不要看檔案存不存在**。

---

## 8. 診斷與自測入口

全部透過環境變數驅動，直接跑 `MuseDock.app/Contents/MacOS/MuseDock` 即可（不需要 UI 操作）：

| 變數 | 作用 |
|---|---|
| `MUSE_SNAPSHOT=1` | 離屏渲染主視窗深／淺色 PNG 到 `/tmp/musedock_window_{dark,light}.png` |
| `MUSE_STATUS_TEST=1` | 印出選單列的選單結構後結束 |
| `MUSE_CLOSE_TEST=1` | 關窗後檢查行程是否存活，印 `AFTER_CLOSE` / `STILL_RUNNING` |
| `MUSE_CHROME_LIST=1` | 列出掃描到的 Chrome Profile |
| `MUSE_CHROME_IMPORT="Profile 11"` | 只解密並印出 cookie 筆數與 `hatch*` / `sess*` 的值前 12 字（不寫入） |
| `MUSE_CHROME_APPLY="Profile 11"` | 完整走「匯入 → 載入 → 探測登入」 |
| `MUSE_IMPORT_FILE` + `MUSE_IMPORT_ACCOUNT` | 從 Netscape cookies.txt 匯入到指定 slot |
| `MUSE_WHO=<slot>` | 載入該帳號並輸出頁面診斷（email 候選、localStorage、指紋樣本）＋截圖 `/tmp/who_N.png` |
| `MUSE_DROP_SLOT=<slot>` | 移除帳號並清空隔離儲存＋資料目錄（維護用，走 `performDelete`） |
| `MUSE_WIPE_SLOT=<slot>` | 清除該帳號的網站資料＋資料目錄，保留帳號（維護用，走 `wipeAccount`） |
| `MUSE_STATE_DIR=<路徑>` | 把 `accounts.json`、`instance.lock` 導到指定目錄；做示範／截圖時不碰真實帳號，兩邊的單一實例鎖也互不影響 |
| `MUSE_DEMO=1` | 示範模式：跳過登入探測與指紋取樣，讓假資料的圓點維持原樣（配合 `MUSE_STATE_DIR` 使用） |
| `MUSE_AVATAR_PROBE=<slot>` | 診斷：載入該帳號後 dump 所有 `img`（含祖先鏈、尺寸、`data-*`）、背景圖、`[class*=avatar]` 容器，並把 `<video>` 抽一幀轉 dataURL（頭像排查用） |
| `MUSE_AVATAR_CLICK=<css>` | 搭配上者：先點擊指定元素（例如 `[data-hatch-avatar-interaction]`）再 dump，用於展開選單後取內容 |
| `MUSE_IDLE_RELEASE_SEC=<秒>` | 閒置釋放門檻，預設 600（10 分鐘）；設小一點方便測 |
| `MUSE_IDLE_TEST=1` | 自測：開 1 號 → 切 2 號 → 等釋放 → 切回 1 號驗證仍登入，印 `result1` / `result2` |
| `MUSE_STORE_SELFTEST=1` | 連續 200 次原子寫入 `accounts.json`（內容不變），並故意注入一次外部改動以驗證 `STORE_CONFLICT`；搭配外部輪詢腳本可確認讀不到半截檔 |
| `MUSE_AUTOSTART=status\|on\|off` | 查詢／設定開機自動啟動（`SMAppService`），印出 status 後退出 |
| `MUSE_START_SLOT=<slot>` | 啟動時直接選定該帳號 |
| `MUSE_AUTOLOGIN=1` | 探測時自動點「一鍵登入」卡片 |
| `MUSE_SHOW=1` | 讓視窗真正顯示（headless 探測必加） |
| `MUSE_PROBE_WAIT=<秒>` | 探測前等待時間（預設 8，建議 16） |
| `MUSE_UA=<字串>` | 覆寫 User-Agent |

範例：

```bash
pkill -f MuseDock; sleep 1
MUSE_SHOW=1 MUSE_CHROME_APPLY="Profile 15" MUSE_PROBE_WAIT=16 \
  /Applications/MuseDock.app/Contents/MacOS/MuseDock | grep -E "CHROME_APPLY|LOGIN|SNAP"
```

---

## 9. 已知限制 / 技術債

| 項目 | 現況 | 影響 |
|---|---|---|
| 記憶體 | 每個帳號一個 `WKWebView`，切走的閒置 10 分鐘後釋放（v0.14） | 閒置期間仍佔一份 WebContent；回到該帳號要重新載入頁面（約 2–4 秒） |
| 指紋覆蓋率 | 只有被打開過的帳號有樣本 | 冷啟動時未必能立刻標出重複 |
| 登入狀態 | 只探當前且可見的帳號（隱藏頁不 hydrate） | 沒切過去的帳號圓點仍是舊值，切過去 6 秒內校正 |
| Muse 真實 email | 前端不暴露（DOM/localStorage/IndexedDB/`api/me` 都沒有） | 卡片只能顯示 Chrome 的 Google 帳號 |
| 平台 | arm64 / macOS 14+ 硬編碼 | 換 Intel 需改 `-target` |
| 簽章 | ad-hoc，無公證 | 換機器首次開啟需右鍵「打開」 |
| 測試 | 無單元測試，只有 CLI 自測入口 | 改動靠人工驗證 |
| 多實例 | v0.13 起用 `flock`（`instance.lock`）擋住；寫入型 CLI 直接拒絕 | 已解決。仍需注意：同一份 `accounts.json` 不要用兩個不同路徑的 App 同時開 |

---

## 10. 建議下一步

1. **頭像換成 Muse 真實大頭貼**：頁面 `img[src*="avatar"]` 抓得到（診斷腳本已在抓），存起來當快取
2. **熱鍵可自訂**：目前固定 `⇧⌘1–9`，可能與其他 App 衝突
3. **匯入前預檢重複**：匯入後若指紋命中，直接在對話框問「要保留哪一個」
4. **記憶體壓力自適應**：目前門檻固定 10 分鐘，可改成依 `os_proc_available_memory()` 動態收緊

---

## 11. 版本沿革

| 版本 | 內容 |
|---|---|
| 0.1–0.6 | WebKit 多身分容器、側邊欄卡片、分組、固定編號、刪除帳號 |
| 0.7 | 登入判定改 `/api/me`、一鍵登入自動點、四帳號匯入完成 |
| 0.8 | 程式化繪製 App 圖示（三張斜疊卡片 + 對話氣泡） |
| 0.9 | App 內建 Chrome Profile 匯入（`ChromeCookies.swift`）、卡片顯示 email、選單列常駐 |
| 0.10 | 卡片標明來源（`Profile N · email`）、對話列表指紋 + 重複帳號偵測（⚠︎） |
| 0.11 | 刪除帳號時一併刪掉 WebKit 資料目錄（`Store.purgeWebsiteDataDir`），不再殘留快取；刪除邏輯抽成 `performDelete(at:)` 供 UI 與 CLI 共用；`wipe` 同樣補刀（`wipeAccount(at:)`） |
| 0.12 | 登入狀態即時化（`scheduleLoginProbe`，節流 180s、只探可見的當前帳號）；開機自動啟動（`SMAppService.mainApp` + 選單勾選項） |
| 0.13 | 單一實例鎖（`flock` on `instance.lock`）：第二個實例叫回既有視窗後退出；寫入型 CLI 直接拒絕，避免兩個行程覆寫 `accounts.json`；`Store.save` 改原子寫入＋跨行程檔案鎖＋`STORE_CONFLICT` 偵測 |
| 0.14 | 省資源模式：切走的帳號閒置 10 分鐘後釋放 `WKWebView`（保留 storeID 與磁碟 cookie），切回自動重建仍登入 |

---

## 12. 接手檢查清單

```bash
# 1. 能編譯
cd ~/MuseDock && ./build.sh

# 2. 能啟動、狀態檔正常
MUSE_SNAPSHOT=1 /Applications/MuseDock.app/Contents/MacOS/MuseDock
cat ~/Library/Application\ Support/MuseDock/accounts.json | python3 -m json.tool | head -30

# 3. 選單列結構正常
MUSE_STATUS_TEST=1 /Applications/MuseDock.app/Contents/MacOS/MuseDock | head -20

# 4. 關窗不退出（常駐的核心行為）
MUSE_CLOSE_TEST=1 /Applications/MuseDock.app/Contents/MacOS/MuseDock | grep STILL_RUNNING

# 5. Chrome 匯入鏈路正常（會真的寫入，請用測試帳號）
MUSE_CHROME_LIST=1 /Applications/MuseDock.app/Contents/MacOS/MuseDock | head

# 6. 單一實例（App 已開著時再跑一次，應印 SINGLE_INSTANCE 並立刻結束）
/Applications/MuseDock.app/Contents/MacOS/MuseDock | grep SINGLE_INSTANCE

# 7. 寫入安全性（先關掉 App；會連續寫 200 次，內容不變）
MUSE_STORE_SELFTEST=1 /Applications/MuseDock.app/Contents/MacOS/MuseDock | grep STORE

# 8. 省資源模式（先關掉 App；約 50 秒，結尾應為 result1 PASS / result2 PASS）
MUSE_IDLE_TEST=1 MUSE_IDLE_RELEASE_SEC=10 /Applications/MuseDock.app/Contents/MacOS/MuseDock | grep IDLE_TEST
```

文件與程式碼不一致時，**以程式碼為準**並回頭修這份文件；README 用的截圖必須用 `MUSE_STATE_DIR` 指向假資料重新產生（見 §8 `MUSE_DEMO`），
不要把真實帳號的截圖放進版控——那種圖會帶著信箱與對話內容。

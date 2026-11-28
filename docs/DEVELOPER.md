# MuseDock 開發說明（v0.19）

一個 macOS 原生的小工具，把多個 Muse（muse.ai）帳號集中在同一個視窗裡切換，
每個帳號各自擁有**完全隔離的 Cookie / 網站資料**，互不干擾。

- 形態：單一 `NSApplication`，純程式碼建 UI（無 Xcode 專案、無 storyboard、無第三方套件）
- 語言／工具鏈：Swift 6（`swiftc` 直編）、AppKit、WebKit、Carbon（全域熱鍵）、SQLite3（讀 Chrome cookie）
- 產物：`MuseDock.app`（ad-hoc 簽章，本機執行）
- 平台：macOS 14+ / arm64
- 目前版本：`CFBundleShortVersionString 0.19`

**目錄**：[1 專案結構](#1-專案結構)｜[2 架構總覽](#2-架構總覽)｜[3 資料模型](#3-資料模型)｜[4 核心流程](#4-核心流程)｜[5 UI 規格](#5-ui-規格)｜[6 選單列常駐](#6-選單列常駐)｜[7 踩過的坑](#7-踩過的坑改動前務必看)｜[8 診斷入口](#8-診斷與自測入口)｜[9 已知限制](#9-已知限制--技術債)｜[10 下一步](#10-建議下一步)｜[11 版本沿革](#11-版本沿革)｜[12 檢查清單](#12-接手檢查清單)

---

## 1. 專案結構

```
~/MuseDock/
├── main.swift            3284 行   全部 UI + Controller + 診斷入口
├── ChromeCookies.swift    313 行   Chrome Profile 掃描與 cookie 解密
├── build.sh                64 行   編譯、打包 Info.plist、簽章、同步到 /Applications、提醒執行中實例
├── AppIcon.icns / .png            程式化繪製的圖示（10 個尺寸）
├── tools/
│   ├── rollback.sh        164 行   一鍵回滾（切 tag → pkill → 重建 → 重開）
│   ├── update.sh          105 行   一鍵升級（pull → pkill → 重建 → 重開）
│   ├── release.sh         163 行   一鍵發版（版本號 → build → commit → tag → Release）
│   └── draw_icon.py       181 行   PIL 4096px 超取樣繪製圖示
├── docs/screenshot-demo.png       示範截圖（用 MUSE_STATE_DIR 跑假資料產生）
└── docs/
    ├── DEVELOPER.md               本文件
    ├── CHANGELOG-v0.12.md         v0.11 → v0.12 變更說明（交接用）
    ├── CHANGELOG-v0.13.md         v0.12 → v0.13 變更說明（單一實例鎖）
    ├── CHANGELOG-v0.14.md         v0.13 → v0.14 變更說明（省資源模式）
    ├── CHANGELOG-v0.15.md         v0.14 → v0.15 變更說明（卡片頭像）
    ├── CHANGELOG-v0.16.md         v0.15 → v0.16 變更說明（編輯選單 / ⌘V 分發）
    ├── CHANGELOG-v0.17.md         v0.16 → v0.17 變更說明（輸入焦點 / 貼上路徑）
    ├── UPDATE-v0.17.md            v0.17 使用者向更新說明（不含程式細節）
    ├── CHANGELOG-v0.18.md         v0.17 → v0.18 變更說明（儲存加固 / 日誌）
    └── UPDATE-v0.18.md            v0.18 使用者向更新說明（不含程式細節）
```

執行期資料（不在 repo 內）：

```
~/Library/Application Support/MuseDock/accounts.json            ← 唯一的狀態檔
~/Library/Application Support/MuseDock/avatars/<storeID>.png    ← 卡片頭像快取（v0.15，非必要資料，刪掉會自己重抓）
~/Library/WebKit/local.sulipa.musedock/WebsiteDataStore/<storeID>/   ← WebKit 依 storeID 自動管理
```

### 建置

```bash
cd ~/MuseDock && ./build.sh
```

做的事：`rm -rf MuseDock.app` → 編譯 `main.swift ChromeCookies.swift` → 寫 `Info.plist`
→ 打包 `AppIcon.icns` → `codesign -s -`（ad-hoc，失敗不中斷）→ `cp -R` 到 `/Applications`
→ 若偵測到執行中的 `MuseDock`，印出警告（**只提醒，不動它**）。

> 為什麼要提醒：`cp -R` 只換磁碟上的檔案，已在跑的行程仍是舊的；而單一實例鎖會讓
> 下一次啟動 `exit(0)` 去叫回舊視窗，使用者會以為「更新沒生效」。見 §4.8 與坑 18。

回滾（換版本、驗舊版行為）：

```bash
./tools/rollback.sh            # 上一個 tag
./tools/rollback.sh v0.15      # 指定 tag
./tools/rollback.sh main       # 回最新
./tools/rollback.sh -n v0.16   # 只印計畫不動手
```

它把「pkill 舊實例 → 等鎖釋放 → checkout → 重建 → 印版本 → 重開」串起來，
正是缺一環就會誤判的那些步驟（見坑 18）。**舊 tag 裡沒有這支腳本**，
所以在 tag 上想回 main 要用它印出來的那行 `git checkout main && ./build.sh`。

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
| 卡片頭像用 AI 夥伴的影片影格，而不是首字母（v0.15） | Muse 沒有使用者頭像（見 §4.10），但每個帳號的 `<video>` 形象不同且穩定，比首字母更能一眼認人 |
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

### 解不出結構時：備份 + 唯讀（v0.18）

`Store.load()` 有三條路，**不要合併**：

| 情況 | 行為 |
|---|---|
| 檔案不存在 | 首次啟動 → 寫入兩張佔位帳號（`seedAndPersist`） |
| 檔案存在、解得開 | 正常回傳，順手補 `slot <= 0` |
| 檔案存在、解不開 | 另存 `accounts.broken-<yyyyMMdd-HHmmss>.json`（留最近 5 份）→ `Store.frozen = true` → 回傳佔位帳號**但不寫入** |

`frozen` 之後 `save()` 直接 return 並每次印 `STORE_FROZEN`；GUI 啟動彈一次說明
（`warnIfStoreFrozen`，CLI／自測不彈，免得卡住自動流程），狀態列後綴
`⚠︎ 資料檔毀損，本次不寫入`。

> **為什麼不能「解不開就回退種子並存檔」**：那等於把所有帳號連 `storeID`、指紋一起無聲刪掉，
> 而且不報錯，只表現為「清空了」。未來給 `Account` 加必填欄位時，舊版 App 讀到新版檔案
> 就是這條路。原子寫（v0.13）只防半截檔，防不了這個。
>
> 驗證：`MUSE_STORE_BROKEN_TEST=1` 檢查四件事——原檔位元組不變、備份內容一致、
> `save` 被擋、仍能開出 UI，全過才 `exit 0`。

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
`WKWebView`（沒有就建）→ **`window.makeFirstResponder(w)`** → 若尚未載入則 `load(muse.ai)`
→ 更新標題與狀態列 → 排程指紋取樣。

> `makeFirstResponder` 不能省：`removeFromSuperview` 會讓第一響應者退回視窗自己，
> 少了這行 `⌘V`／打字／選字全部失效（見 §4.11）。

> 熱鍵與 `slot` 綁定，不是陣列索引，所以刪帳號、換分組都不會改變 ⇧⌘n 的意義。

### 4.3 從 Chrome 匯入（主要登入路徑）

```
使用者：側邊欄 ⋯ → 從 Chrome 匯入 → 選 Profile
   ↓
importChromeProfile(_:)                      main.swift
   ├ ChromeCookies.profiles()   讀 Local State 列出所有 Profile（名稱/email/上次使用/muse cookie 數）
   ├ 目標帳號：名稱完全相同 → 直接用；否則忽略大小寫；再否則彈窗問「匯入當前 / 建立新帳號 / 取消」
   ├ 匯入前預檢：ownerOf(profileDir:) 有主人 → confirmReimport() 先問（v0.19，見下）
   ├ 背景執行緒：ChromeCookies.cookies(for: dir)   解密出 [HTTPCookie]
   └ 主執行緒：install(cookies:into:source:email:profileDir:)
          ├ 逐筆寫入該帳號的 WKWebsiteDataStore.httpCookieStore
          ├ loggedIn = true、補 email、補 profileDir
          ├ Store.save() → rebuildCards() → select(idx)
          └ 重新載入 muse.ai（探測後回寫真實登入狀態）
```

備援路徑：`從 cookies.txt 匯入…`（Netscape 格式，`CookieParser.parse(netscape:)`），
給沒有 Chrome 的機器或手動匯出用。

#### 匯入前預檢：同一個 Profile 只該有一個主人（v0.19）

`duplicateMap()` 靠左側對話標題指紋，要等頁面真的渲染過才有樣本——也就是說，
「同一個 Profile 匯入兩次」在匯入當下是看不出來的，等 ⚠︎ 出現時卡片已經多了一張。

所以預檢改用**匯入當下就有**的資料：`profileDir`。來源目錄是唯一的，
`ownerOf(profileDir:)` 一次線性比對，成本可忽略：

| 情況 | 行為 | 按鈕 |
|---|---|---|
| 沒有主人 | 直接寫入（照舊） | — |
| 主人就是目標帳號 | 問一次，說明會覆蓋登入狀態 | 「重新匯入」/「取消」 |
| 主人是別的帳號 | 問一次，說明會多一張同帳號卡片 | 「仍要新增」/「取消」 |

文案由 `reimportPrompt(profile:owner:target:)` 這個**純函式**產生，UI 只負責顯示——
這樣 `MUSE_IMPORT_PRECHECK` 能斷言「該不該問、問什麼」，不必真的彈窗點按鈕。

```bash
# 會問什麼？只印不算，不寫任何資料
MUSE_IMPORT_PRECHECK="Profile 11" ./MuseDock.app/Contents/MacOS/MuseDock | grep PRECHECK
# PRECHECK dir=Profile 11 already=3 owner=Grass target=5 same=false confirm=仍要新增 title=這個 Profile 已經匯入過了
# PRECHECK dir=Default  already=- prompt=none（這個 Profile 還沒匯入過，直接寫入）
```

`MUSE_CHROME_LIST` 的每一行也多一欄 `already=<slot>`（`-` = 還沒匯入過），
可以在匯入前直接看一眼，不必進 GUI：

```
  Profile 11 | Grass | sulipa888@gmail.com | cookies=13 | last=11/26 19:21 | already=3
  Profile 2  | sulipa| liangshienlin@gmail.com | cookies=12 | last=11/26 19:21 | already=-
```

> 這一欄用 `Store.peek()`（只讀，不修補 slot、不建檔）。用 `Store.load()` 會因為
> 「補 slot」或「首次啟動寫種子」而動到檔案——診斷指令不該有副作用。


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

### 4.10 卡片頭像（v0.15）

**先講結論：Muse 前端沒有「使用者頭像」這東西。** 用 `MUSE_AVATAR_PROBE` 把整頁 dump 過一次：

| 找到什麼 | 實際是什麼 |
|---|---|
| 9 張 `<img>`（`blob:` 來源，256×256 WebP，顯示 19–40pt） | 每個「空間（space）」的 3D 立體圖示 |
| `background-image` | 一個都沒有 |
| `[data-hatch-avatar-interaction]`（56×56，`aria-label="Muse"`）內含 `<video>` | **Muse(AI) 自己**的形象動畫；點開是它的檔案面板，沒有使用者名稱或 email |

所以「抓使用者大頭貼」這條路不存在。但那個 `<video>` **每個帳號不一樣**：
實測 甲＝白色絨毛小生物、乙＝黑貓抱臂、丙 與 甲 相同。同一帳號重複抽幀的 md5 一致，
所以它可以是「這個帳號的臉」。

```
didFinish / select(i)
 └ scheduleAvatarCapture(for:)              延遲 8 秒（等 SPA 畫完 + 影片解碼）
      ├ 前置條件：非 DEMO、已登入、WebView 存在且可見、muse.ai、無快取（或 MUSE_AVATAR_FORCE=1）
      ├ JS：取畫面最大的 <video>
      │     用亮度掃出角色包圍盒（每 2px 取樣，背景是純黑）
      │     side = 頭寬 × 1.04，水平置中、頭頂留 6% 空隙
      │     drawImage → 128×128 PNG dataURL
      ├ 失敗（no-video / rsN / draw:…）→ 5 秒後重試，最多三次
      └ 成功 → AvatarStore.save(png:for: storeID) → rebuildCards()（卡片立刻換臉）
```

**為什麼要掃包圍盒，不寫死比例**：兩個形象在畫面裡的大小與位置差很多
（頭寬約 0.62× 與 0.67× 畫面，垂直位置也不同）。第一版用固定比例（邊長 0.78、中心 0.36），
絨毛那張的臉被推到圓心外、貓那張下顎被切掉。改成掃包圍盒後兩張都正對圓心。

**為什麼必須「已登入 + 可見」**：未登入的登入頁顯示的是通用形象，不是這個帳號的；
而隱藏的 WebView 不解碼影片，`videoWidth` 永遠是 0（§7 坑 12）。

**存放與生命週期**：`~/Library/Application Support/MuseDock/avatars/<storeID>.png`
（128×128，約 26KB）。跟著 `MUSE_STATE_DIR` 走，所以示範模式讀的是假頭像，不會污染真實快取。

| 動作 | 頭像 |
|---|---|
| 刪除帳號 `performDelete` | `AvatarStore.remove` 一起刪 |
| `wipe`（清除網站資料） | 一起刪——等於換身分，舊臉不該留 |
| 閒置釋放 WebView | **保留**，切回來只重繪、不重抓 |
| 冷啟動 | 直接讀檔，不必開頁面就有圖 |

**沒做的**：頭像不隨深／淺色主題調整（影片本來就是深底）；形象相同的兩個帳號
只能靠名稱與編號區分，圖上分不出來。

### 4.11 剪貼板與第一響應者（v0.16）

**症狀**：在 1 號的對話框選字複製，切到 2 號，`⌘V` 貼不進去。

**這不是剪貼板的問題，是 App 少了兩樣東西。**

#### (1) 標準編輯快捷鍵靠選單分發，不是靠鍵盤事件

`⌘C` / `⌘V` / `⌘X` / `⌘A` / `⌘Z` 在 AppKit 裡的實作方式是：`NSMenu` 某個項目的
`keyEquivalent`，被 `NSApplication` 在 `performKeyEquivalent` 階段比對到，
再轉成 `copy:` / `paste:` 這些 action 沿回應鏈發送。

所以 **mainMenu 裡沒有「編輯」這一張，這幾顆鍵就永遠不會被發出去**。
MuseDock v0.15 只有「MuseDock / 帳號 / 檢視」三張。

```swift
// buildMenu()：放在 App 選單之後
let editItem = NSMenuItem()
main.addItem(editItem)
let editMenu = NSMenu(title: "編輯")
editMenu.addItem(withTitle: "復原",   action: Selector(("undo:")), keyEquivalent: "z")
let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
redo.keyEquivalentModifierMask = [.command, .shift]
editMenu.addItem(redo)
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)),       keyEquivalent: "x")
editMenu.addItem(withTitle: "複製", action: #selector(NSText.copy(_:)),      keyEquivalent: "c")
editMenu.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)),     keyEquivalent: "v")
editMenu.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
```

`target` 一律留 `nil`：讓回應鏈自己找 `WKContentView`（它實作了 `NSText` 那組）。
自己指定 `target = self` 會變成「選單永遠灰掉」或「貼到自己的東西」。

#### (2) 換帳號後第一響應者掉回視窗

`select()` 是「子視圖全部 `removeFromSuperview`，再放新的」。舊 WebView 離開視圖樹，
`window.firstResponder` 退回視窗自己——`paste:` 發出去了，回應鏈上卻沒人執行。

```swift
contentHost.subviews.forEach { $0.removeFromSuperview() }
contentHost.addSubview(w)
// …activate constraints…
window.makeFirstResponder(w)     // ← 少了這行，貼上、打字、選字全部失效
if w.url == nil { w.load(URLRequest(url: url)) }
```

`WKWebView` 會把焦點在內部轉給 `WKContentView`。因為 WebView 物件沒被銷毀
（§4.9 的釋放才會真的丟掉），它記得的 DOM 焦點也一併回來，切回去直接 `⌘V` 就能貼。

#### 為什麼症狀是「複製成功、貼上失敗」

| 動作 | 走哪條路 | v0.15 |
|---|---|---|
| 選字 → 右鍵「拷貝」 | WKWebView 內建右鍵選單，不經 `NSMenu` | 成功（所以以為複製沒問題） |
| `⌘C` | 需要「編輯」選單 | 其實也失效 |
| 切帳號 → `⌘V` | 選單缺項，事件終止 | 失敗 |

#### 自檢

```bash
MUSE_STATE_DIR=/tmp/md-keytest MUSE_KEYTEST=1 MUSE_DEMO=1 \
  ./MuseDock.app/Contents/MacOS/MuseDock
```

```
KEYTEST idx=0 slot=1 t=0  pasteMenu=OK inWebView=true responder=WKWebView
KEYTEST idx=1 slot=2 t=0  pasteMenu=OK inWebView=true responder=WKWebView
PASTETEST token=MUSE-PASTE-9895 dispatched=true got=MUSE-PASTE-9895 result=PASS
```

`KEYTEST` 印兩件事：選單裡有沒有 `⌘V`、第一響應者在不在 WebView 裡。
`PASTETEST` 是真的貼：注入 `contenteditable` → 寫 `NSPasteboard` →
`NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)` → 讀回 `innerText` 比對。
（`KEYTEST` 會自動在 3 秒後切到另一個帳號，所以一條日誌就能看到「切換前後」的對照。）

### 4.12 輸入焦點與貼上路徑（v0.17）

v0.16 讓 `⌘V` 能走到 `WKContentView`，但 `paste:` 只會貼到**有 DOM 焦點**的元素。
切帳號或頁面重繪之後 `activeElement` 會退回 `<body>`，那時貼上「表面上有執行、實際什麼都沒發生」。

實測 Muse 的輸入框是 **`<textarea>`**（不是 `contenteditable`），而且頁面自己有時會聚焦、有時不會；
即使切過去時是好的，對話載完重繪後焦點又會掉。所以做兩層：

#### (1) 切換後補焦點（體驗）

```
select(i) ─────────┐
                   ├─ scheduleComposerFocus(for: i) → 1.5 秒後執行（同帳號只留最新一個）
didFinish(nav) ────┘                               ↓ none / err → 3 秒後重試，最多三次
```

`composerJS` 的判斷順序（**不要改**）：

| 狀況 | 回傳 | 為什麼 |
|---|---|---|
| 已經在 `contenteditable` / `textarea` / `input` | `already` | 連游標位置都不該動，否則打斷草稿 |
| 使用者點在別的元素上 | `skip:user-active` | 正在選字／閱讀，搶焦點會讓人抓狂 |
| 找不到任何候選 | `none` | 未登入或 SPA 還沒畫完 → 重試 |
| 聚焦成功 | `focused` | 游標放文字末尾 |

候選是 `[contenteditable="true"],[contenteditable=""],textarea,[role="textbox"]` 裡
**面積最大**的可見元素（聊天介面只有一個 composer）。
`focus({ preventScroll: true })` 是必要的，否則切回去頁面會跳到輸入框。

#### (2) `⌘V` 自己確認落點（可靠）

「編輯 → 貼上」不接原生 `paste:`，改接 `pasteIntoPage(_:)`：

```swift
// ⌘V → pasteIntoPage
// ① 第一響應者不在 WebView（側欄改名、搜尋框）→ 原樣轉發，完全不干預
// ② 在 WebView → pasteJS 先確保焦點在輸入框 → 再 forwardPaste()
func forwardPaste() { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
```

`pasteJS` 與 `composerJS` 只差一行：**不檢查 `skip:user-active`**。
自動補焦點是順手幫忙，按 `⌘V` 是明確要求，容忍度不同。

#### 兩個時序坑

| 坑 | 現象 | 正確做法 |
|---|---|---|
| 改完焦點立刻 paste | 內容貼到舊位置（`body`），等於沒貼 | 等 0.5 秒（0.15 秒不夠）；`already` 時 `wait = 0` 不讓使用者等 |
| `<textarea>` 用 `Range` 設游標 | 無效，貼上的字插在草稿最前面 | `textarea`/`input` 用 `setSelectionRange(len, len)`，`contenteditable` 才用 `Range` |

#### 關掉自動聚焦

`MUSE_NO_AUTOFOCUS=1`：只關 (1)，`⌘V` 的落點確認仍然有效——
也就是說，關掉之後你得先點一下輸入框，但貼上本身永遠不會失效。

---

## 5. UI 規格

| 元素 | 規格 |
|---|---|
| 視窗 | 1240×840，最小 900×600，`fullSizeContentView` + 透明標題列；`isReleasedWhenClosed = false` |
| 側邊欄 | 固定 280pt，右側 1px hairline 分隔線 |
| 卡片 | 高 64pt、圓角 10、選取時 accent 13% 底 + 0.75 邊框、hover 7% 灰 |
| 卡片內容 | 32pt 圓形頭像（有快取時畫 AI 夥伴影格，否則首字母 + `Palette` 6 色盤、djb2 取色，見 §4.10）／名稱 14 semibold／`⇧n` 徽章／狀態點 5pt／副標題 11pt |
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
7. **Chrome Profile 名稱撞名**：`Default` 叫 "Work"、`Profile 2` 叫 "work"。
   `ChromeCookies.profile(matching:in:)` 規則是**先精確、再忽略大小寫**，不要改回單純 lowercase 比對。
8. **取得金鑰的方式**：用 `/usr/bin/security find-generic-password`（已授權的系統工具），
   不要用 `SecItemCopyMatching`，後者會反覆彈鑰匙串視窗。
9. **登入判定不要看頁面文字**："Sign in" 在登入後仍有；一律以 `/api/me` 狀態碼為準。
10. **沙箱內啟動 Chrome 會失敗**：只有使用者雙擊才能開 Chrome；匯入只需讀檔案，不受影響。
11. **單一實例鎖的 fd 要活到行程結束**：`InstanceLock.acquire()` 回傳的 fd 一旦 `close()` 就等於放鎖；
    別把它包進 `defer` 或區域變數作用域，也別「用完就關」。另外鎖檔本身留著沒關係（內容是 pid，僅供提示），
    **判斷是否持鎖只看 `flock` 的回傳值，不要看檔案存不存在**。
12. **隱藏的 WebView 不播影片**：這是坑 1 的影片版——切走的帳號 `video.videoWidth` 永遠是 0，
    抽幀只會拿到空白畫布。所以 `scheduleAvatarCapture` 除了要求 `host == muse.ai`，還要求 `w.window != nil`。
13. **樣本不足時不要覆寫既有指紋**：切換帳號的瞬間舊頁面被移出畫面，`innerText` 讀不到東西，
    `fingerprintJS` 會回 `n=0`。照寫就會把原本 20 幾筆樣本清成空陣列，重複偵測從此失效（v0.15 修）。
    規則：`n < 2` 只重試、不寫入；兩次都失敗就保留舊值並印 `FP_KEEP`。
14. **「複製得到、貼不上」先看 mainMenu**：`⌘C`/`⌘V`/`⌘X`/`⌘A`/`⌘Z` 是靠「編輯」選單項的
    `keyEquivalent` 分發到第一響應者的，程式化建選單時很容易只加 App／帳號／檢視就忘了它。
    少了那張選單，`paste:` 永遠不會被發出去；再加上 `removeFromSuperview` 會讓
    `window.firstResponder` 退回視窗自己，兩層一起壞就是「看得到、貼不進去」（v0.16 修，見 §4.11）。
    右鍵選單是 WebKit 自己管的，會讓人誤判「複製正常」。
15. **`⌘V` 送得到 ≠ 貼得上**：`paste:` 只認 DOM 焦點（`document.activeElement`）。
    切帳號、頁面重繪都會讓它退回 `<body>`，此時 `paste:` 有執行但內容進不了任何輸入框。
    v0.17 的解法是「按下的那一刻先確保焦點在 composer，再轉發」（見 §4.12），
    不要試圖在切換時補一次就了事——Muse 載完對話會再重繪一次，補好的焦點會被吃掉。
16. **JS 改完焦點不能立刻 `sendAction(paste:)`**：WebKit 的 `EditorState` 要一次 IPC 往返才更新，
    太快的話內容會貼到舊位置。實測 0.15 秒不夠、0.5 秒可以。
    另外 `textarea`/`input` 的游標要用 `setSelectionRange`，`createRange()` 只對 `contenteditable` 有效。
17. **自測要走選單／回應鏈時，視窗必須是 key window**：`NSApp.sendAction(_:to:nil,from:)`
    在非 key window 下找不到 `WKContentView`，回 `false`，很容易被誤判成「修壞了」。
    `orderFrontRegardless()` 只保證畫出來，自測請用 `makeKeyAndOrderFront` + `activate`。
18. **重建不會換掉正在跑的行程**：`./build.sh` 只覆寫磁碟上的 `.app`，已在執行的行程還是舊二進位。
    加上 v0.13 的單一實例鎖，下一次啟動會 `SINGLE_INSTANCE already running` → 叫回舊視窗 → `exit(0)`，
    使用者看到的仍是舊版，於是回報「更新沒生效」。**驗證新版前一定要先結束舊實例**：
    `pkill -x MuseDock`（`osascript -e 'quit app "MuseDock"'` 需要 TCC 自動化授權，
    未授權時回 `-10004 越權取用`，不要寫進文件當標準做法）。
    `build.sh` 偵測到執行中實例時會印警告，但**不會**替你結束它。
19. **`print` 在 GUI 啟動時等於丟掉**：從 Dock／`open` 開的行程 stdout 接 `/dev/null`，
    122 個 `print` 一行都不會留下。於是每次排查都得「用環境變數重跑一次自測」才看得到結論——
    那不是診斷，是重現，而使用者看到的場景往往重現不出來。v0.18 起一律用 `emit()`
    （stdout + `~/Library/Logs/MuseDock.log`）。**新增診斷輸出時請用 `emit`，不要用 `print`。**
20. **`activate(ignoringOtherApps:)` 在 macOS 14+ 等於沒說**：這個參數被忽略，背景啟動的行程
    常常整個請求被丟掉，`window.isKeyWindow` 一直是 `false`。徵狀是
    `PASTETEST … dispatched=false key=false`——看起來像「貼上壞了」，實際是「視窗從來不是 key」。
    v0.19 起統一走 `activateApp()`（14+ 用 `NSApp.activate()`），自測也改成**明確指定第一響應者**
    （`sendAction(to: window.firstResponder)`）。**寫新自測不要再用 `to: nil`**，那會把
    「測試環境沒有焦點」誤讀成「功能壞了」。
21. **`storeID` 不是 UUID 會硬崩**：`webView(for:)` 是 `UUID(uuidString: acc.storeID)!`。
    正常流程的 storeID 都是 `UUID().uuidString`，但手改 `accounts.json`、或從別處抄帳號時
    很容易寫成 `"S1"`，一啟動就在 `select()` 崩掉，日誌只留一行 `IDLE_TIMER`（看起來像「啟動即死」）。
    自造測試資料請用真的 UUID：`python3 -c 'import uuid;print(uuid.uuid4())'`。
    還沒修，記在 ROADMAP 2.4。

---

## 8. 診斷與自測入口

### 日誌（v0.18）

`emit()` 取代 `print()`，同時寫 stdout 與檔案：

| 啟動方式 | 日誌檔 |
|---|---|
| 一般 | `~/Library/Logs/MuseDock.log` |
| 帶 `MUSE_STATE_DIR` | `<該目錄>/musedock.log`（不污染真實那份） |

4MB 輪替，保留 `MuseDock.log` 與 `MuseDock.log.1`。每次啟動第一行是版本、pid、UTC 時間。
排查順序：先 `tail -50 ~/Library/Logs/MuseDock.log`，看不到線索才跑下面的自測。

全部透過環境變數驅動，直接跑 `MuseDock.app/Contents/MacOS/MuseDock` 即可（不需要 UI 操作）：

| 變數 | 作用 |
|---|---|
| `MUSE_SNAPSHOT=1` | 離屏渲染主視窗深／淺色 PNG 到 `/tmp/musedock_window_{dark,light}.png` |
| `MUSE_STATUS_TEST=1` | 印出選單列的選單結構後結束 |
| `MUSE_CLOSE_TEST=1` | 關窗後檢查行程是否存活，印 `AFTER_CLOSE` / `STILL_RUNNING` |
| `MUSE_CHROME_LIST=1` | 列出掃描到的 Chrome Profile；每行末尾 `already=<slot>` 表示該來源目錄已被哪個帳號佔用（`-` = 沒匯入過）。只讀，不會修補或建出 `accounts.json` |
| `MUSE_IMPORT_PRECHECK="Profile 11"` | 匯入前預檢：印出 `already=` / `owner=` / 目標 slot / 會彈什麼文案（`confirm=` / `title=`），不彈窗、不寫資料（見 §4.3） |
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
| `MUSE_AVATAR_TEST=<slot>` | 自測：先刪掉該帳號的頭像快取再載入，45 秒後檢查 PNG 是否產生（`AVATAR_TEST result PASS`） |
| `MUSE_AVATAR_FORCE=1` | 忽略既有快取，強制重抓頭像（換了形象或想確認抽幀仍正常時用） |
| `MUSE_WINDOW_FIT=1` | 把視窗縮進可見區域（避開選單列與 Dock）並印 `WINDOW_FRAME`，供截圖精確裁切 |
| `MUSE_IDLE_RELEASE_SEC=<秒>` | 閒置釋放門檻，預設 600（10 分鐘）；設小一點方便測 |
| `MUSE_IDLE_TEST=1` | 自測：開 1 號 → 切 2 號 → 等釋放 → 切回 1 號驗證仍登入，印 `result1` / `result2` |
| `MUSE_STORE_BROKEN_TEST=1` | 壞檔在場時驗證「備份 + 拒絕寫入 + 原檔不動」四項，全過 `exit 0`（見 §3） |
| `MUSE_STORE_SELFTEST=1` | 連續 200 次原子寫入 `accounts.json`（內容不變），並故意注入一次外部改動以驗證 `STORE_CONFLICT`；搭配外部輪詢腳本可確認讀不到半截檔 |
| `MUSE_AUTOSTART=status\|on\|off` | 查詢／設定開機自動啟動（`SMAppService`），印出 status 後退出 |
| `MUSE_START_SLOT=<slot>` | 啟動時直接選定該帳號 |
| `MUSE_KEYTEST=1` | 自檢：切換帳號（3 秒後自動切另一個）時印 `KEYTEST`（⌘V 選單項在不在、第一響應者在不在 WebView），並在 9 秒時做一次真的貼上（`PASTETEST … result=PASS`）。v0.19 起跑完自己結束（PASS → `exit 0`、FAIL → `exit 1`），可以直接接在管線後面。見 §4.11 |
| `MUSE_NO_AUTOFOCUS=1` | 切換帳號時不要把游標放進輸入框（`⌘V` 的落點確認仍然有效）。見 §4.12 |
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
| 卡片頭像 | 只在「已登入 + 頁面可見」時抽幀（v0.15） | 新匯入的帳號要切過去一次才有圖；同形象的兩個帳號只能靠名稱與編號區分 |
| 登入狀態 | 只探當前且可見的帳號（隱藏頁不 hydrate） | 沒切過去的帳號圓點仍是舊值，切過去 6 秒內校正 |
| Muse 真實 email | 前端不暴露（DOM/localStorage/IndexedDB/`api/me` 都沒有） | 卡片只能顯示 Chrome 的 Google 帳號 |
| 平台 | arm64 / macOS 14+ 硬編碼 | 換 Intel 需改 `-target` |
| 簽章 | ad-hoc，無公證 | 換機器首次開啟需右鍵「打開」 |
| 測試 | 無單元測試，只有 CLI 自測入口 | 改動靠人工驗證 |
| 多實例 | v0.13 起用 `flock`（`instance.lock`）擋住；寫入型 CLI 直接拒絕 | 已解決。仍需注意：同一份 `accounts.json` 不要用兩個不同路徑的 App 同時開 |
| 剪貼板 | v0.16 補「編輯」選單＋交還第一響應者；v0.17 補 DOM 焦點與 `⌘V` 落點確認 | 已解決。`⌘V` 在焦點被改過時多等 0.5 秒；`MUSE_NO_AUTOFOCUS=1` 可關自動聚焦 |

---

## 10. 建議下一步

1. **熱鍵可自訂**：目前固定 `⇧⌘1–9`，可能與其他 App 衝突
2. **匯入前預檢重複**：匯入後若指紋命中，直接在對話框問「要保留哪一個」
3. **記憶體壓力自適應**：目前門檻固定 10 分鐘，可改成依 `os_proc_available_memory()` 動態收緊
4. **頭像補抓**：目前只在使用者切過去時抓；可改成背景依序把已登入帳號的頭像補齊

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
| 0.15 | 卡片頭像：抽 AI 夥伴 `<video>` 的一幀（亮度掃包圍盒自適應裁切）存成 128×128 PNG，取代首字母；順手修掉「空指紋樣本覆寫既有樣本」的 bug；新增 `MUSE_WINDOW_FIT` 截圖輔助 |
| 0.16 | 修「1 號複製、2 號貼不上」：補上「編輯」選單（⌘C/⌘V 靠 `keyEquivalent` 分發，缺了這張就永遠收不到），`select()` 改在換頁後 `makeFirstResponder(w)` 交還第一響應者；帳號選單修飾鍵改 `⇧⌘n`；新增 `MUSE_KEYTEST` 自檢（含真貼上驗證 `PASTETEST`） |
| 0.18 | 儲存加固：`accounts.json` 解不出結構時備份為 `accounts.broken-*.json` 並轉唯讀（`Store.frozen`，`save` 拒寫、GUI 彈一次、狀態列提示），不再回退種子覆蓋；`print` 全面改為 `emit`，日誌落盤 `~/Library/Logs/MuseDock.log`（4MB 輪替兩份）；新增 `tools/update.sh` 與 `tools/release.sh`；`MUSE_STORE_BROKEN_TEST` 自測 |
| 0.17 | 修「`⌘V` 送到了卻貼不上」：切換帳號與頁面載入後自動把 DOM 游標放回 composer（`scheduleComposerFocus`），並把「貼上」改成 `pasteIntoPage`——按下時先確認焦點再轉發原生 `paste:`，焦點掉了也貼得上；`MUSE_IDLE_TEST` 擴成六段（含失焦到 body 後的貼上驗證）；新增 `MUSE_NO_AUTOFOCUS` |
| 0.19 | 匯入前預檢重複帳號：`ownerOf(profileDir:)` + `confirmReimport()`（文案由純函式 `reimportPrompt` 產生），在寫入前就攔住「同一個 Chrome Profile 匯入兩次」；`MUSE_CHROME_LIST` 多一欄 `already=<slot>`（走新增的只讀 `Store.peek()`）；新增 `MUSE_IMPORT_PRECHECK`。順手修基線：`activateApp()` 改用 macOS 14+ 的 `NSApp.activate()`、`PASTETEST` 改指定第一響應者不再依賴 key window、`MUSE_KEYTEST` 跑完自己結束 |

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

# 9. 頭像抽幀（先關掉 App；約 45 秒，應印 AVATAR name=… 與 result PASS）
MUSE_AVATAR_TEST=1 /Applications/MuseDock.app/Contents/MacOS/MuseDock | grep AVATAR_TEST

# 10. 匯入預檢（只讀；already= 應對得上你現有的來源目錄）
MUSE_IMPORT_PRECHECK="Profile 11" /Applications/MuseDock.app/Contents/MacOS/MuseDock | grep PRECHECK
```

### 截圖（給 README）

```bash
MUSE_STATE_DIR=/tmp/musedock-demo MUSE_DEMO=1 MUSE_WINDOW_FIT=1 \
  /Applications/MuseDock.app/Contents/MacOS/MuseDock
# 記下輸出的 WINDOW_FRAME，換算成像素裁切（scale=2）：
#   left = x*2, top = (screenH - y - h)*2, right = (x+w)*2, bottom = (screenH - y)*2
```

文件與程式碼不一致時，**以程式碼為準**並回頭修這份文件；README 用的截圖必須用 `MUSE_STATE_DIR` 指向假資料重新產生（見 §8 `MUSE_DEMO`），
不要把真實帳號的截圖放進版控——那種圖會帶著信箱與對話內容。

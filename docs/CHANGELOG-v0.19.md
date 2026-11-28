# MuseDock v0.18 → v0.19 變更說明

**主題：匯入前就攔住重複帳號；順手把「每週自動推進」的基線修成可重複執行。**

這一版有兩塊：一塊是新功能（P1 1.1），一塊是基線修復。基線修復是手動預演每週流程時
被擋下來的——照 ROADMAP §2 的規則，「基線不過就先修基線，不要在其上疊新功能」，
所以兩塊一起發在同一個版本，但先修的那塊先做完驗證。

`main.swift`：3284 → 3384 行。

---

## 0. 檔案與符號變更

| 位置 | 新增 / 變更 | 說明 |
|---|---|---|
| `main.swift:149` | `Store.peek()` 新增 | 只讀 `accounts.json`：不補 slot、不寫種子、不建檔 |
| `main.swift:2498` | `Controller.ownerOf(profileDir:)` 新增 | 回傳佔用該來源目錄的帳號索引；`nil` = 沒主人。忽略 `profileDir` 為空的帳號 |
| `main.swift:2504` | `Controller.reimportPrompt(profile:owner:target:)` 新增 | **純函式**，回傳 `(title, body, confirm)` 三段文案 |
| `main.swift:2521` | `Controller.confirmReimport(profile:owner:target:)` 新增 | 只負責把上面那段文案顯示成 `NSAlert` |
| `main.swift:2565` | `importChromeProfile(_:)` 插入預檢 | 在 `ChromeCookies.cookies(for:)` **之前**，因此也在任何寫入之前 |
| `main.swift:3088` | `activateApp()` 新增 | `#available(macOS 14)` 走 `NSApp.activate()`，否則 `activate(ignoringOtherApps:)` |
| `main.swift:1427` | `PASTETEST` 輸出多一欄 `fr=<型別>` | 直接看第一響應者是誰（`WKWebView` = 對） |
| `main.swift:3314` | `MUSE_IMPORT_PRECHECK` 新增 | 命令列預檢入口（唯讀） |
| `main.swift:3198` | `MUSE_IMPORT_PRECHECK` 併入 `READONLY_CLI` | 可與執行中的實例並存，不搶鎖 |
| `main.swift:3218` | `MUSE_CHROME_LIST` 多一欄 `already=<slot>` | `-` = 還沒匯入過 |
| `main.swift:2690` 附近 | `CHROME_APPLY` 多一欄 `already=<slot>` | CLI 匯入同樣看得出來是不是重匯 |
| `main.swift:828` | `pasteSelfTest` 跑完 `exit()` | PASS → 0、FAIL → 1 |
| 全部啟用點（3 處） | `NSApp.activate(ignoringOtherApps: true)` → `activateApp()` | 啟動、`runIdleTest`、`showWindow` |

---

## 1. 一頁摘要

| 問題 | 以前 | 現在 |
|---|---|---|
| 同一個 Chrome Profile 匯入兩次 | 卡片多一張，等頁面載完、指紋算出來才標 ⚠︎ | 寫入前就問：「這個 Profile 已經匯入過」 |
| 想知道某個 Profile 匯入了沒 | 只能開 App 看卡片 | `MUSE_CHROME_LIST` 每行末尾 `already=<slot>` |
| `MUSE_KEYTEST` 自測 | `PASTETEST dispatched=false key=false` 誤判 FAIL | 不依賴 key window，穩定 PASS |
| 自測指令 | 跑完不退出，管線永遠不返回 | 跑完自己結束，退出碼就是結果 |
| 叫回視窗 | `activate(ignoringOtherApps:)` 在 macOS 14+ 被忽略 | `NSApp.activate()` |

---

## 2. 為什麼「匯入後才偵測重複」不夠

`duplicateMap()`（v0.10）比的是左側欄對話標題做成的指紋。這條路徑有兩個先天限制：

1. **要有樣本**：頁面必須真的渲染過（見 DEVELOPER 坑 1，隱藏的 WebView 不 hydrate）。
   剛匯入的帳號在探測跑完之前，`hasUsableFp` 是 false。
2. **要比對兩邊**：`sameAccount(as:)` 需要兩個都有樣本才算得出來。

結果就是：使用者按下「匯入」那一刻，什麼警告都不會有；等到 ⚠︎ 出現，卡片已經兩張了，
而「哪張是哪張」只能靠人工判斷。這正是 ROADMAP §0 第 2 條「不可逆損毀全部堵住」的反面——
多出來的卡片不會自己消失，刪錯一張就丟了那個帳號的登入態。

**匯入前唯一可靠、且成本近乎零的線索是 `profileDir`。** 一個 Chrome Profile 目錄只會被
匯入到一個帳號（`install(cookies:into:source:email:profileDir:)` 會把它寫進 `Account`，
`decodeIfPresent` 保證舊資料讀得進來）。所以拿它做預檢，不需要頁面、不需要等、不需要網路。

---

## 3. 修法

### 3.1 預檢放在「任何寫入之前」

`importChromeProfile(_:)` 的順序被刻意排成：

```
ownerOf(profileDir:)        ← 預檢（最前面，比 target 解析還早）
   ↓ 有主人
confirmReimport(...)        ← 使用者按「重新匯入 / 仍要新增 / 取消」
   ↓ 同意
解析目標帳號（同名 → 忽略大小寫 → 彈窗問「匯入當前 / 建立新帳號 / 取消」）
   ↓
ChromeCookies.cookies(for:) ← 這裡才開始解密
   ↓
install(...)                ← 這裡才寫 cookie
```

預檢之所以要比「解析目標帳號」還早，是因為「建立新帳號」那條分支會**立刻 append 一個
`profileDir == p.dir` 的帳號**——若預檢排在它後面，`ownerOf` 會把這個剛建的新帳號當成
「已有主人」，使用者剛選完「建立新帳號」又立刻被問「這個 Profile 已經匯入過」，
完全錯亂（這正是初版 v0.19 埋的一個 bug，複查時抓出來並修正）。

放在解密之前而不是寫入之前，是為了讓「取消」真的什麼都沒發生——
解密會讀 Chrome 的 Keychain 條目，某些機器上會跳一次系統提示，不該為了一個被取消的操作跳。

### 3.2 三種情況，兩種文案

| 情況 | 訊息 | 按鈕 |
|---|---|---|
| 沒主人 | 不問，直接寫 | — |
| 主人 = 目標帳號 | 「『Grass』已經匯入過」，說明會覆蓋登入狀態 | 重新匯入 / 取消 |
| 主人 ≠ 目標帳號 | 「這個 Profile 已經匯入過了」，說明會多一張同帳號卡片 | 仍要新增 / 取消 |

第二種情況刻意**不擋**：用 Chrome 目前的 cookie 刷新一個舊帳號是正常需求（cookie 過期、
在 Chrome 裡重新登入過），擋掉只會逼使用者去改檔案。第一種才是真正會造成重複的。

### 3.3 文案抽成純函式

`reimportPrompt(...)` 只做字串組合，`confirmReimport(...)` 只做 `NSAlert` 顯示。
好處是自測不必彈窗、也不必模擬點擊——`MUSE_IMPORT_PRECHECK` 直接印出「會問什麼」：

```
PRECHECK dir=Profile 11 already=3 owner=Grass 舊卡 target=3 same=true  confirm=重新匯入 title=「Grass」已經匯入過
PRECHECK dir=Profile 11 already=3 owner=Grass 舊卡 target=5 same=false confirm=仍要新增 title=這個 Profile 已經匯入過了
PRECHECK dir=Default    already=- prompt=none（這個 Profile 還沒匯入過，直接寫入）
PRECHECK dir=Profile 99 profile=missing
```

這也是「使用者可見行為有回歸測試」（§0 第 3 條）的一部分：以後改文案不會悄悄改壞判斷邏輯。

### 3.4 `Store.peek()`：診斷指令不該有副作用

`MUSE_CHROME_LIST` 要顯示 `already=` 就得讀帳號，但 `Store.load()` 會做兩件有副作用的事：
補 `slot <= 0` 的帳號、以及在沒有檔案時寫入種子帳號。一個「看一眼」的指令不該改資料。

```swift
static func peek() -> [Account] {
    guard let data = try? Data(contentsOf: file),
          let list = try? JSONDecoder().decode([Account].self, from: data) else { return [] }
    return list
}
```

壞檔時回空陣列（`already` 全部顯示 `-`），不備份、不轉唯讀——那是 `load()` 的職責，
不該由一個唯讀查詢觸發。

---

## 4. 基線修復（先做的部分）

### 4.1 症狀

照 ROADMAP §2 跑第一步基線：

```
PASTETEST tag=keytest token=MUSE-PASTE-8265 dispatched=false key=false got= result=FAIL
```

但同一輪的 `KEYTEST` 兩項都是正常的：

```
KEYTEST idx=0 slot=1 t=0      pasteMenu=OK inWebView=true responder=WKWebView
KEYTEST idx=1 slot=2 t=+0.6s  pasteMenu=OK inWebView=true responder=WKWebView
```

也就是說：選單項在、第一響應者在 WebView 裡、DOM 也真的聚焦了，只有「派發」那一步回 false。

### 4.2 原因

`pasteProbe` 用的是 `NSApp.sendAction(_:to: nil, from: nil)`。`to: nil` 的意思是
「從 **key window** 的第一響應者開始沿響應鏈找」——沒有 key window 就無條件回 `false`。

而 macOS 14 起 `NSApp.activate(ignoringOtherApps:)` 的參數被忽略，背景啟動的行程
（自測就是）常常整個激活請求被丟掉，`window.isKeyWindow` 永遠是 `false`。
本機實測 macOS 26.6.2 重現：從 shell 直接跑二進位檔，`lsappinfo front` 一直是別的应用。

所以這個 FAIL 不是「貼上壞了」，是「測試環境沒有焦點」。但**它會讓每週自動化每次都在第一步失敗**，
然後照規則把好好的改動回退掉——這比沒有自動化更糟。

### 4.3 修法

三件事，都不改使用者行為：

1. **自測不依賴 key window**：改成明確指定第一響應者
   `NSApp.sendAction(#selector(NSText.paste(_:)), to: window.firstResponder, from: nil)`。
   走的是同一條響應鏈（起點就是 key window 情境下的起點），只是不看誰是 key。
   輸出多一欄 `fr=<型別>`，一眼看得出第一響應者是 `WKWebView` 還是 `nil`。
2. **自測跑完自己結束**：`pasteSelfTest` 的 completion 裡 `exit(ok ? 0 : 1)`。
   以前跑完不退出，ROADMAP 那行「`… | grep PASTETEST`」永遠不返回，只能靠外層
   `sleep 16; kill`（`release.sh` 一直是這樣兜的）。自動化裡「不返回」等於掛住。
3. **激活 API 現代化**：`activateApp()`，macOS 14+ 用 `NSApp.activate()`（協作式激活，
   由使用者動作觸發時才允許），舊系統保留原行為。順帶修掉一個潛在的使用者可見問題：
   在別的 App 前面按 `⇧⌘n`，舊寫法可能只換了內容、視窗仍在後面。

### 4.4 為什麼不「先 activate 再等一下」

考慮過在自測開頭 `NSApp.activate()` 然後 `sleep` 到 `isKeyWindow == true`。放棄的理由：
在 macOS 14+ 的協作式激活下，**沒有使用者動作就可能永遠等不到**，那會變成「有時 PASS、有時 FAIL」
的測試——比穩定 FAIL 更難查。

---

## 5. 驗證

全部使用 `/tmp` 下的臨時 `MUSE_STATE_DIR`，沒有動真實帳號。

### 5.1 基線四步（改動前後各一次）

```
STORE_BROKEN_TEST bytes=12 frozen=true accounts=2 backup=accounts.broken-20261128-134558.json backupOK=true backupSame=true
STORE_BROKEN_TEST unchanged=true result=PASS

STORE_SELFTEST done readable=true bytes=357

KEYTEST idx=0 slot=1 t=0 pasteMenu=OK inWebView=true responder=WKWebView
PASTETEST tag=keytest token=MUSE-PASTE-1857 dispatched=true key=true fr=WKWebView got=MUSE-PASTE-1857 result=PASS
KEYTEST done result=PASS

（日誌異常掃描：0 行）
```

### 5.2 預檢四種情境

```
PRECHECK dir=Profile 11 already=3 owner=Grass 舊卡 target=3 same=true  confirm=重新匯入
PRECHECK dir=Profile 11 already=3 owner=Grass 舊卡 target=5 same=false confirm=仍要新增
PRECHECK dir=Default    already=- prompt=none
PRECHECK dir=Profile 99 profile=missing
```

### 5.3 `already=` 欄

```
  Profile 11 | Grass  | sulipa888@gmail.com      | cookies=13 | last=11/26 19:21 | already=3
  Profile 2  | sulipa | liangshienlin@gmail.com  | cookies=12 | last=11/26 19:21 | already=-
```

### 5.4 選單結構未回歸

```
STATUS item=true hasIcon=true items=12
  ○ 從 Chrome 匯入 ▸(10)
```

---

## 6. 行為差異

| 情境 | v0.18 | v0.19 |
|---|---|---|
| 匯入一個「已匯入過」的 Profile（同一帳號） | 直接覆蓋 cookie | 先問「重新匯入」 |
| 匯入一個「已匯入過」的 Profile（不同帳號） | 直接新增，之後才 ⚠︎ | 先問「仍要新增」 |
| 匯入一個沒匯入過的 Profile | 直接匯入 | 一樣直接匯入（多一行 `CHROME_PRECHECK` 日誌） |
| 從 cookies.txt 匯入 | 不帶 `profileDir` | 不變（見 §9） |
| `MUSE_KEYTEST` | 不退出，靠外部 kill | 自己結束，退出碼 = 結果 |
| 在別的 App 前面按熱鍵 | `activate` 可能無效 | 走 `NSApp.activate()`，行為符合系統語意 |

---

## 7. 被否掉的方案

| 方案 | 為什麼不做 |
|---|---|
| 匯入時比指紋 | 匯入前頁面還沒載入，`hasUsableFp` 為 false；能比的時候已經來不及 |
| 直接禁止重複匯入 | cookie 過期後「重匯同一個 Profile」是正常需求，擋掉會逼使用者改檔案 |
| 用 `storeID` 當唯一鍵擋重匯 | `storeID` 是每個帳號一份，跟來源無關；比對不到來源目錄 |
| `MUSE_CHROME_LIST` 用 `Store.load()` | 會補 slot、可能寫種子帳號——唯讀查詢不該有副作用 |
| 預檢放在解密之後 | 取消時已經讀過 Keychain，某些機器會跳系統提示 |
| 自測先 `activate` 再等 `isKeyWindow` | macOS 14+ 沒有使用者動作可能永遠等不到 → 不穩定的測試 |
| `PASTETEST` 改走 `NSMenu.performKeyEquivalent` | 選單項 action 的 target 解析同樣先找 key window，換個地方踩同一個坑 |

---

## 8. 回歸清單

```bash
cd ~/MuseDock

# 匯入預檢（只讀；四種情境都該有合理輸出）
MUSE_IMPORT_PRECHECK="Profile 11" ./MuseDock.app/Contents/MacOS/MuseDock | grep PRECHECK
MUSE_IMPORT_PRECHECK="Profile 99" ./MuseDock.app/Contents/MacOS/MuseDock | grep PRECHECK

# already= 欄（只讀；跑完目錄不該多出 accounts.json 以外的檔案）
MUSE_CHROME_LIST=1 ./MuseDock.app/Contents/MacOS/MuseDock | head

# 鍵盤路徑（約 10 秒，自己結束）
rm -rf /tmp/md-key && mkdir -p /tmp/md-key
MUSE_STATE_DIR=/tmp/md-key MUSE_KEYTEST=1 MUSE_DEMO=1 MUSE_START_SLOT=1 \
  ./MuseDock.app/Contents/MacOS/MuseDock | grep -E "PASTETEST|KEYTEST done"
#   期望：PASTETEST … dispatched=true fr=WKWebView result=PASS、KEYTEST done result=PASS、exit 0

# 儲存（不能被預檢改動弄壞）
rm -rf /tmp/md-broken && mkdir -p /tmp/md-broken
printf '{"oops": 1}\n' > /tmp/md-broken/accounts.json
MUSE_STATE_DIR=/tmp/md-broken MUSE_STORE_BROKEN_TEST=1 ./MuseDock.app/Contents/MacOS/MuseDock | grep result=

# 匯入後沒有多出卡片（人工）：對同一個 Profile 匯入兩次，第二次應先看到詢問
```

**測試資料注意**：`accounts.json` 的 `storeID` 必須是合法 UUID，
否則 `webView(for:)` 的 `UUID(uuidString:)!` 會直接崩（DEVELOPER 坑 21，ROADMAP 2.4）。

---

## 9. 仍未處理

1. **只涵蓋 Chrome Profile 路徑**：從 `cookies.txt` 匯入不經過 `profileDir`，這條路徑仍可能產生
   兩張同帳號卡片（只能等指紋算出來）。要補必須先決定「檔案匯入的來源識別」用什麼。
2. **`storeID` 非 UUID 會硬崩**：已列 ROADMAP 2.4，屬資料層改動，要先確認不破壞 §0 第 2 條。
3. **熱鍵仍固定 `⇧⌘1–9`**：ROADMAP 1.2，未動。
4. **`main.swift` 3384 行**：ROADMAP 1.3，未動。

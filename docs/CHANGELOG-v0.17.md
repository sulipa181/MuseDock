# 變更說明：v0.16 → v0.17

- 日期：2026-11-27
- 讀者：**開發**。給使用者的版本在 [UPDATE-v0.17.md](UPDATE-v0.17.md)，內容等價但不含程式細節
- 範圍：`main.swift`（+367 / −50）、`build.sh`（版本號）、`docs/DEVELOPER.md`（+76）——逐項見 §0
- 是否影響既有資料：**不影響**
- 是否需重新登入：**不需要**
- 版本號：`CFBundleShortVersionString` 0.16 → **0.17**

---

## 0. 檔案與符號變更

```
README.md                |   4 +-      文件索引
build.sh                 |   2 +-      版本號 0.16 → 0.17
docs/CHANGELOG-v0.17.md  | 163 +++     本文件
docs/UPDATE-v0.17.md     | 新增        使用者向更新說明
docs/DEVELOPER.md        |  76 +++     §4.12、坑 15–17、§8 變數、§9、§11
main.swift               | 367 ++++--  全部實作（3119 行）
```

新增／改寫的符號（行號以 v0.17 的 `main.swift` 為準，會隨改動漂移，用名字找）：

| 符號 | 位置 | 職責 |
|---|---|---|
| `focusWork: [String: DispatchWorkItem]` | L693 | 每個帳號尚未執行的補焦點工作，用來去重 |
| `composerJS` | L1462 | 探測並（必要時）聚焦，回 `already` / `skip:user-active` / `none` / `focused <描述>` |
| `pasteJS` | L1493 | 與 `composerJS` 同構，**不檢查 `skip:user-active`** |
| `pasteIntoPage(_:)` | L1533 | 「編輯 → 貼上」的 action，v0.16 的原生 `paste:` 被換掉 |
| `forwardPaste()` | L1570 | `NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)` |
| `scheduleComposerFocus(for:attempt:)` | L1576 | 1.5 秒後執行，`none`／`err` 再隔 3 秒重試，最多三次 |
| `probeFocus(_:)` | L1430 | 讀 `document.activeElement`，回 `input:…` / `other:…` / `no-webview` |
| `pasteProbe(tag:)` | L1315 | 注入 `contenteditable` + 真 `sendAction`，驗證 DOM 路徑貼得上 |
| `pasteViaMenuProbe(tag:noBlur:)` | L1377 | 走 `pasteIntoPage`，落點用注入的透明 `textarea` 驗證 |
| `runIdleTest()` | L1648 | 由兩段擴成六段，全 PASS 才 `exit 0` |
| `NO_AUTOFOCUS` | L2949 | `MUSE_NO_AUTOFOCUS=1`，只關自動聚焦 |

呼叫點只有兩處，兩者覆蓋不同時機，缺一都會漏：

| 呼叫點 | 覆蓋的時機 |
|---|---|
| `select(i)` L1279 | WebView 已存在、只是換頁導致焦點掉回 `body` |
| `webView(_:didFinish:)` L2547 | 重建後 SPA 才把 composer 畫出來 |

`composerJS` / `pasteJS` 是 `let` 常數而非每帳號一份：字串只在啟動時建一次，
`callAsyncJavaScript` 每次呼叫本來就會重新解析，所以不需要快取 DOM 參照。
每次都重新查詢 DOM 是刻意的——頁面重繪後節點會換人，握著舊參照等於對著空氣操作；
`scheduleAvatarCapture` 也是同樣寫法（每次重試都重新 `querySelectorAll('video')`）。

---

## 1. 一頁摘要

| 改動 | 使用者感知 |
|---|---|
| 切換帳號後把 DOM 游標放回輸入框 | 切過去直接 `⌘V`，不用先點一下 |
| `⌘V` 先確認落點再轉發 `paste:` | 就算頁面重繪把焦點吃掉了，也貼得上 |
| 焦點本來就在輸入框時零延遲 | 正常打字時貼上沒有多餘等待 |
| `MUSE_NO_AUTOFOCUS=1` 可關自動聚焦 | 不喜歡自動聚焦的人有退路 |

一句話：**v0.16 讓 `⌘V` 送得到網頁；v0.17 讓它知道要貼到哪個輸入框，而且貼得上。**

---

## 2. 為什麼 v0.16 之後還有一個「貼不上」

v0.16 修好的是「`⌘V` 走不到 `WKContentView`」。但 `paste:` 只會貼到**有 DOM 焦點**的元素，
而切換帳號／頁面重繪之後：

```
舊 WebView removeFromSuperview
  → AppKit 第一響應者退回 window（v0.16 用 makeFirstResponder 修好）
  → DOM 的 activeElement 仍會退回 <body>
  → paste: 把內文插進 <body>（不可編輯）＝ 什麼都沒發生
```

實測還發現：即使切過去時焦點是好的（`state=already`），Muse 把對話載完、重新渲染之後
焦點又會掉回 `body`（同一條測試裡 `focus2` 從 `input:TEXTAREA` 變成 `other:BODY`）。
所以**不能只靠在切換的那一刻補一次焦點**——補得到是運氣，補不到就是使用者每天遇到的「貼不上」。

---

## 3. 修法：兩層，外加兩個時序坑

### 3.1 第一層：切過去就把游標放回 composer（體驗）

實測 Muse 的輸入框是 **`<textarea>`**，不是 `contenteditable`。頁面自己有時候會自動聚焦、
有時候不會，所以要在切換後補一次，而且要能辨認「不需要補」的情況。

```js
const ae = document.activeElement;
if (ae && (ae.isContentEditable || /^(TEXTAREA|INPUT)$/.test(ae.tagName))) return 'already';
if (ae && ae !== document.body && ae !== document.documentElement) return 'skip:user-active';
const cands = [...document.querySelectorAll('[contenteditable="true"],[contenteditable=""],textarea,[role="textbox"]')]
                .filter(vis);
if (!cands.length) return 'none';            // 還沒渲染 → 重試
cands.sort((a, b) => area(b) - area(a));     // 聊天介面只有一個 composer，取面積最大
el.focus({ preventScroll: true });           // 不讓頁面跳到輸入框
```

| 回傳 | 意思 | 處置 |
|---|---|---|
| `already` | 已經在輸入框 | 不動，連游標位置都不改 |
| `skip:user-active` | 使用者已點在別的元素上 | 不動，避免打斷選字／閱讀 |
| `none` | 還沒有輸入框（未登入／還沒畫完） | 3 秒後重試，最多三次 |
| `focused` | 剛剛聚焦成功 | 完成 |

兩個入口各排一次：`select(i)`（覆蓋「WebView 還在、焦點掉了」）與 `didFinish`
（覆蓋「重建後 SPA 才畫出 composer」）。`focusWork[storeID]` 存 `DispatchWorkItem`，
新調度會取消舊的，否則日誌會出現兩三條同時抵達的 `FOCUS`。

### 3.2 第二層：`⌘V` 自己確認落點（可靠）

只補焦點不夠——頁面重繪隨時會把焦點吃掉。所以把「編輯 → 貼上」這一項從原生
`paste:` 改成自己的方法：

```
⌘V（選單項 keyEquivalent）
  └ pasteIntoPage(_:)
       ├ 第一響應者不在 WebView 裡（側欄改名、搜尋框）→ 原樣轉發 paste:，完全不干預
       ├ 在 WebView 裡 → 跑 pasteJS：焦點不在輸入框就先聚焦（這裡允許搶，使用者意圖明確）
       │                  └ 回傳 already → 立刻轉發；focused → 等 0.5 秒再轉發
       └ forwardPaste() → NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
```

`pasteJS` 與 `composerJS` 只差一行：**不檢查 `skip:user-active`**。
自動補焦點是「順手幫忙」，按 `⌘V` 是「明確要求」，兩者對「使用者正在選字」的容忍度不同。

### 3.3 坑一：焦點換了要等 WebKit 跟上

剛用 JS 改過焦點就立刻 `sendAction(paste:)`，WebKit 內部的 `EditorState` 還沒更新，
內容會貼到**舊位置**（實測落在 `body`，等於沒貼）。0.15 秒不夠，0.5 秒可以。
所以：

```swift
if state.hasPrefix("already") { wait = 0 }   // 焦點本來就對，不要讓使用者等
DispatchQueue.main.asyncAfter(deadline: .now() + wait) { forwardOnce() }
DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { forwardOnce() }   // JS 不回來的兜底
```

### 3.4 坑二：`<textarea>` 的游標不能用 `Range`

`document.createRange()` + `Selection` 只對 `contenteditable` 有效；
`textarea` / `input` 要用 `setSelectionRange(len, len)`。用錯的話游標不在文字末尾，
貼上的內容會插在草稿最前面。

---

## 4. 驗證

`MUSE_IDLE_TEST` 從兩段擴成六段（真實帳號，`MUSE_IDLE_RELEASE_SEC=15` 加速）：

```
IDLE_TEST window key=true appActive=true
IDLE_TEST focus1 name=Grass after-select=input:TEXTAREA      ← ① 正常載入
IDLE_TEST focus2 name=良賢 after-switch=input:TEXTAREA       ← ② 切過去
IDLE_TEST result1 PASS（閒置者已釋放）
IDLE_TEST result2 PASS（重建後仍登入）
IDLE_TEST focus3 name=Grass after-rehydrate=input:TEXTAREA   ← ③ 重建後焦點
IDLE_TEST result3 PASS（重建後游標已在輸入框）
PASTETEST tag=rehydrate token=MUSE-PASTE-1589 dispatched=true key=true … result=PASS
IDLE_TEST result4 PASS（重建後直接 ⌘V 貼得上）
PASTEMENU tag=body-focus after-blur=BODY                     ← ④ 把焦點打成 body
PASTE_ROUTE name=Grass focus=focused TEXTAREA#__md_ta 900x700
PASTEMENU tag=body-focus token=MUSE-MENU-8922 landed=true … result=PASS
IDLE_TEST result5 PASS（失焦到 body 後 ⌘V 仍貼得上）
PASTEMENU tag=already-focus after-blur=TEXTAREA               ← ⑤ 焦點本來就在
PASTE_ROUTE name=Grass focus=already
PASTEMENU tag=already-focus token=MUSE-MENU-4635 landed=true … result=PASS
IDLE_TEST result6 PASS（焦點已在輸入框時直接貼）
```

六項全 PASS 才 `exit 0`。`PASTEMENU` 走的是**真正的選單 action**（`pasteIntoPage`），
落點用注入的透明 textarea 驗證，不去動真實帳號的 composer 草稿；剪貼板測前備份、測後還原。

> 踩過的測試坑：`NSApp.sendAction(paste:)` 在視窗不是 key window 時回 `false`
> （回應鏈上找不到 `WKContentView`）。自測一開始用 `orderFrontRegardless()`，
> 結果 `dispatched=false` 被誤判成「修壞了」。改成 `makeKeyAndOrderFront` + `activate` 才對得上真實情境。

---

## 5. 行為差異（升級後會看到的變化）

### 5.1 `⌘V` 不再是一條直線

| | v0.16 | v0.17 |
|---|---|---|
| 路徑 | `paste:` → `WKContentView` | `pasteIntoPage` → `pasteJS`（一次 IPC）→ `forwardPaste` → `paste:` |
| 焦點不在輸入框 | 內容進 `body`，靜默失敗 | 先聚焦，0.5 秒後貼進輸入框 |
| 延遲 | 0 | 0（`already`）／0.5 秒（剛改過焦點） |
| JS 無回應 | — | 1.5 秒兜底，一定轉發，不會卡住 |

**副作用要記住**：`paste:` 的來源從「選單直接發」變成「JS 回來後發」，
所以在網頁正在換頁的那 1.5 秒內按 `⌘V`，貼上的時機會比按鍵晚一點。
這是刻意的取捨——寧可慢半秒，也不要靜默失敗。

### 5.2 切換帳號會主動改變游標位置

切過去 1.5 秒後，如果 composer 已存在且你沒點在別處，游標會被放到文字末尾。
`preventScroll` 保證頁面不會因此滾動，但對某些使用者來說「游標自己跑進輸入框」
仍然是可感知的行為改變，這是 `MUSE_NO_AUTOFOCUS` 存在的原因。

### 5.3 新增四種日誌前綴

| 前綴 | 格式 | 什麼時候印 |
|---|---|---|
| `FOCUS` | `FOCUS name=… attempt=0 state=already` | 每次 `scheduleComposerFocus` 執行後 |
| `PASTE_ROUTE` | `PASTE_ROUTE name=… focus=focused TEXTAREA#__md_ta 900x700` | 每次 `⌘V` |
| `PASTEMENU` | `PASTEMENU tag=… token=… landed=true where={…} result=PASS` | 自測走選單路徑時 |
| `PASTETEST` | `PASTETEST tag=… token=… dispatched=true key=true got=… result=PASS` | 自測走 DOM 路徑時 |

`PASTE_ROUTE` 的 `focus=` 後面會帶元素描述（`tag#id 寬x高`），
出問題時這一行就能判斷是「貼到錯的元素」還是「根本沒聚焦」。

### 5.4 `MUSE_IDLE_TEST` 的退出碼

| 退出碼 | 意義 |
|---|---|
| `0` | 六段全 PASS |
| `7` | 有任一段 FAIL（含 `result1`–`result6`） |
| `9` | 帳號不足兩個，無法測釋放 |

### 5.5 內部重構（對外無感）

`pasteSelfTest(delay:)` 拆成 `pasteProbe(tag:)`（本體，帶完成回呼）＋薄包裝，
因為自測需要在同一個流程裡依序跑三次不同條件的貼上。`MUSE_KEYTEST` 的行為不變
（仍印 `PASTETEST tag=keytest`）。

---

## 6. 風險與回滾

| 風險 | 說明 | 緩解 |
|---|---|---|
| 自動聚焦打斷閱讀 | 切過去只想看對話，游標卻在輸入框 | `preventScroll` 不跳頁；`skip:user-active` 不搶已點擊的焦點；可 `MUSE_NO_AUTOFOCUS=1` |
| 蓋掉草稿插入點 | 草稿打到一半切走 | `already` 直接返回，不動游標；只有從 `body` 恢復時才放末尾 |
| `⌘V` 多 0.5 秒 | 焦點剛被改過時才等 | 焦點已正確時 `wait = 0`，正常打字貼上無延遲 |
| 選錯輸入框 | 頁面若同時有多個 textarea | 取面積最大者；Muse 只有一個 composer（實測） |
| 原生控件受影響 | 側欄改名等原生文字框 | `pasteIntoPage` 先看第一響應者在不在 WebView 裡，不在就原樣轉發 |
| 貼圖失效 | `pasteJS` 只處理焦點，不碰內容 | 內容仍由原生 `paste:` 插入，富文本／圖片照舊 |

升級與回滾都必須**先結束執行中的實例**——舊行程握著 `instance.lock`，
新行程搶不到鎖就只會叫回舊視窗並 `exit(0)`（`SINGLE_INSTANCE already running`），
磁碟上的新版永遠不會被載入。`build.sh` 已會在偵測到執行中實例時出聲提醒。

```bash
# 升級
pkill -x MuseDock
cd ~/MuseDock && git pull && ./build.sh && open -a MuseDock

# 回滾（accounts.json 無變動，資料不受影響）
./tools/rollback.sh            # 上一個版本；也可以 ./tools/rollback.sh v0.15
./tools/rollback.sh main       # 回到最新
```

`tools/rollback.sh` 就是把下面的手動流程包起來，另外多做三件事：等 `instance.lock`
真的釋放（最多 5 秒）、重建後讀 `Info.plist` 印出新舊版本、結尾給出回 `main` 的指令
（tag 上是 detached HEAD，且舊 tag 裡沒有這支腳本）。

```bash
# 等價的手動流程（腳本壞掉時用）
pkill -x MuseDock; sleep 1
git checkout v0.16 && ./build.sh && open -a MuseDock
# 回到最新：git checkout main && ./build.sh && open -a MuseDock
```

---

## 7. 被否掉的方案

留給下一個想「簡化」這塊的人——這些都試過或推演過，不是漏掉的。

| 方案 | 為什麼不用 |
|---|---|
| 監聽 DOM 的 `focus` / `blur` / `focusout` 補焦點 | SPA 每次重繪都會觸發一輪，會在使用者捲動、選字時搶焦點；而且焦點掉到 `body` 時這些事件在 `document` 上收得到、卻無法判斷「該不該補」 |
| 用 `document.execCommand('insertText')` 直接寫入剪貼板內容 | 等於自己接管編輯：圖片、富文本、undo stack、輸入法組字全部要重做。原生 `paste:` 這些都是免費的 |
| 在 WebView 層攔 `keyDown` 自己處理 `⌘V` | 要繞過 `keyEquivalent` 機制、還要自己判斷輸入法狀態；選單項 + `keyEquivalent` 是 macOS 的正規做法（v0.16 已確立） |
| 每次貼上都固定等 0.5 秒 | 正常打字時白等半秒。用 `already` 分流後，只有剛修過焦點才等 |
| 用 `MutationObserver` 盯 composer 出現 | 常駐 observer 在長對話頁面成本不低，而且解決不了「焦點被別的東西搶走」——那才是真正的失敗模式 |
| 等 WebKit 的某個「編輯器就緒」事件再貼 | 沒有這種公開事件。0.5 秒是量測出來的經驗值，收成常數並寫在這裡，不要散落到各處 |
| 把 `paste:` 的轉發延遲做成可設定 | 使用者不該為這種內部時序負責；出問題時應該是我們調，不是他調 |

---

## 8. 回歸清單（動這塊程式之前先跑）

```bash
# 1. 建置
./build.sh

# 2. 六段自測（真實帳號；15 秒加速版）
MUSE_IDLE_TEST=1 MUSE_IDLE_RELEASE_SEC=15 /Applications/MuseDock.app/Contents/MacOS/MuseDock
#    期望：result1–result6 全 PASS、exit 0

# 3. 鍵盤路徑（假資料，不動真實帳號）
rm -rf /tmp/md-keytest && mkdir -p /tmp/md-keytest
MUSE_STATE_DIR=/tmp/md-keytest MUSE_KEYTEST=1 MUSE_DEMO=1 MUSE_START_SLOT=1 \
  ./MuseDock.app/Contents/MacOS/MuseDock
#    期望：KEYTEST pasteMenu=OK inWebView=true responder=WKWebView
#          PASTETEST dispatched=true result=PASS
```

手動三項（自測取代不了）：

1. 1 號選字 `⌘C`（**不用右鍵**）→ `⇧⌘2` → 不點任何地方直接 `⌘V`
2. 側欄「改名」的原生輸入框裡 `⌘V` → 應貼在原生框，`PASTE_ROUTE` 不該出現
3. 剪貼板放一張圖 → 在 2 號 `⌘V` → 應貼成圖片（`pasteJS` 只動焦點、不碰內容）

**只改一個值的注意事項**：若調整 `pasteIntoPage` 裡的 `0.5`，必須重跑
`PASTEMENU tag=body-focus`（它模擬失焦到 `body`）。這是唯一能驗出
「貼到舊位置」的測試；`result6`（`already-focus`）測不出來，因為那條路 `wait = 0`。

---

## 9. 仍未處理

1. **熱鍵可自訂**：目前固定 `⇧⌘1–9`
2. **匯入前預檢重複**
3. **記憶體壓力自適應**
4. **頭像補抓**
5. **`⌘V` 貼圖到失焦的輸入框**：焦點在 `body` 時我們先把游標放回 composer 再貼，
   若剪貼板裡是圖片，`paste:` 由 WebKit 處理，行為與手動點輸入框後貼一致

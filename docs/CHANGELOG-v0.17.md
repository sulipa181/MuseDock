# 變更說明：v0.16 → v0.17

- 日期：2026-11-27
- 範圍：`main.swift`（新增 `composerJS` / `pasteJS` / `scheduleComposerFocus` / `pasteIntoPage` / `probeFocus` / `pasteViaMenuProbe`；`MUSE_IDLE_TEST` 擴成六段）、`build.sh`（版本號）、`docs/DEVELOPER.md`（新增 §4.12、坑 15、坑 16）
- 是否影響既有資料：**不影響**
- 是否需重新登入：**不需要**
- 版本號：`CFBundleShortVersionString` 0.16 → **0.17**

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

## 5. 風險與回滾

| 風險 | 說明 | 緩解 |
|---|---|---|
| 自動聚焦打斷閱讀 | 切過去只想看對話，游標卻在輸入框 | `preventScroll` 不跳頁；`skip:user-active` 不搶已點擊的焦點；可 `MUSE_NO_AUTOFOCUS=1` |
| 蓋掉草稿插入點 | 草稿打到一半切走 | `already` 直接返回，不動游標；只有從 `body` 恢復時才放末尾 |
| `⌘V` 多 0.5 秒 | 焦點剛被改過時才等 | 焦點已正確時 `wait = 0`，正常打字貼上無延遲 |
| 選錯輸入框 | 頁面若同時有多個 textarea | 取面積最大者；Muse 只有一個 composer（實測） |
| 原生控件受影響 | 側欄改名等原生文字框 | `pasteIntoPage` 先看第一響應者在不在 WebView 裡，不在就原樣轉發 |
| 貼圖失效 | `pasteJS` 只處理焦點，不碰內容 | 內容仍由原生 `paste:` 插入，富文本／圖片照舊 |

回滾：換回 v0.16 的 `.app`。`accounts.json` 無變動。

---

## 6. 仍未處理

1. **熱鍵可自訂**：目前固定 `⇧⌘1–9`
2. **匯入前預檢重複**
3. **記憶體壓力自適應**
4. **頭像補抓**
5. **`⌘V` 貼圖到失焦的輸入框**：焦點在 `body` 時我們先把游標放回 composer 再貼，
   若剪貼板裡是圖片，`paste:` 由 WebKit 處理，行為與手動點輸入框後貼一致

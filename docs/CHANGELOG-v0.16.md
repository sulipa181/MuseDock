# 變更說明：v0.15 → v0.16

- 日期：2026-11-27
- 範圍：`main.swift`（新增「編輯」選單、`select()` 補 `makeFirstResponder`、帳號選單修飾鍵、新增 `MUSE_KEYTEST` 自檢）、`build.sh`（版本號）、`docs/DEVELOPER.md`（新增 §4.11、坑 14）
- 是否影響既有資料：**不影響**。`accounts.json` 沒動
- 是否需重新登入：**不需要**
- 版本號：`CFBundleShortVersionString` 0.15 → **0.16**

---

## 1. 一頁摘要

| 改動 | 使用者感知 |
|---|---|
| 補上「編輯」選單（復原／重做／剪下／複製／貼上／全選） | 在 1 號複製，切到 2 號 `⌘V` 貼得上 |
| 切帳號時把第一響應者交還給新的 WebView | 貼上、打字、選字都跟著帳號走 |
| 帳號選單的 `⌘1` 改成 `⇧⌘1` | 選單顯示的跟實際熱鍵一致，不再多一條沒人知道的 `⌘n` |
| `MUSE_KEYTEST=1` 自檢 | 開發用：一行日誌看出 ⌘V 這條路上有沒有人接 |

一句話：**WebView 裡「複製得到、貼不上」，不是剪貼板壞了，是 App 少了那張選單。**

---

## 2. 根因：兩層，缺一層都不行

### 2.1 沒有「編輯」選單 → `⌘V` 根本沒被發出去

macOS 的 `⌘C` / `⌘V` / `⌘X` / `⌘A` / `⌘Z` **不是**由鍵盤事件直接送到第一響應者。
它們是 `NSMenu` 裡某一項的 `keyEquivalent`，由系統在
`NSApp.mainMenu.performKeyEquivalent(with:)` 時轉成 `copy:` / `paste:` 這些 action，
再沿回應鏈找實作的人。

MuseDock 的選單只有「MuseDock / 帳號 / 檢視」三張——**沒有「編輯」**。
於是 `⌘V` 連一個能承載它的選單項都沒有，事件到此為止，
WKWebView 內部的 `WKContentView` 從頭到尾沒收到 `paste:`。

```swift
// 修法：把標準編輯項加回去，target 一律 nil，讓回應鏈自己找 WKContentView
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
```

### 2.2 換帳號時第一響應者掉回視窗

`select()` 的做法是「把 `contentHost` 的子視圖全部 `removeFromSuperview`，再放進新的」。
舊 WebView 一離開視圖樹，它就失去第一響應者身分，`window.firstResponder` 退回視窗自己。
即使有選單、`paste:` 也發出去了，回應鏈上沒有人執行。

```swift
contentHost.subviews.forEach { $0.removeFromSuperview() }
contentHost.addSubview(w)
// 修法
window.makeFirstResponder(w)
```

`WKWebView` 會把焦點在內部轉給 `WKContentView`；因為 WebView 物件沒被銷毀，
它記得的 DOM 焦點（例如上次停在輸入框）也一併回來——切回去直接 `⌘V` 就貼得上。

---

## 3. 為什麼症狀長成「複製可以、貼上不行」

| 你做的動作 | 走的路 | 結果 |
|---|---|---|
| 選字 + 右键「拷貝」 | WKWebView 內建的右鍵選單（不經 `NSMenu`） | **成功**，剪貼板真的有東西 |
| `⌘C` | 需要「編輯」選單 | 其實也失效（只是你剛好用右鍵） |
| 切到 2 號 + `⌘V` | 選單缺項 → 事件終止 | **失敗** |

所以「複製成功」是右鍵選單的功勞，與 `⌘C` 無關；而貼上沒有右鍵選單可以繞（
在空輸入框上右鍵雖然有「貼上」，但很多人不會那樣做）。
使用者看到的就是：**同一段字，1 號拿得到，2 號貼不進去。**

---

## 4. 順手修：帳號選單的修飾鍵

原本帳號選單項寫 `keyEquivalent: "1"`，預設修飾鍵是 `⌘`，選單裡顯示 `⌘1`；
但實際的全域熱鍵（Carbon `RegisterEventHotKey`）是 `⇧⌘1`。等於多了一條
文件沒寫、也沒人記得的 `⌘1`，還會跟「切到第 1 個分頁」這種肌肉記憶打架。

```swift
it.keyEquivalentModifierMask = [.command, .shift]
```

---

## 5. 驗證

自檢模式（用臨時 `MUSE_STATE_DIR`，不碰真實帳號）：

```bash
rm -rf /tmp/md-keytest && mkdir -p /tmp/md-keytest
MUSE_STATE_DIR=/tmp/md-keytest MUSE_KEYTEST=1 MUSE_DEMO=1 MUSE_START_SLOT=1 \
  ./MuseDock.app/Contents/MacOS/MuseDock
```

實際輸出：

```
KEYTEST idx=0 slot=1 t=0  pasteMenu=OK inWebView=true responder=WKWebView
KEYTEST idx=0 t=+0.6s     pasteMenu=OK inWebView=true responder=WKWebView
WEBVIEW rebuilt name=帳號 2 total=2
KEYTEST idx=1 slot=2 t=0  pasteMenu=OK inWebView=true responder=WKWebView
KEYTEST idx=1 t=+0.6s     pasteMenu=OK inWebView=true responder=WKWebView
PASTETEST token=MUSE-PASTE-9895 dispatched=true got=MUSE-PASTE-9895 result=PASS
```

`PASTETEST` 不是看狀態，是真的貼：注入一個 `contenteditable`、塞字進 `NSPasteboard`、
用 `NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)`
（＝「編輯 → 貼上」被按下時系統做的事），再讀回 `innerText` 比對。

修好前 `pasteMenu=MISSING`、`dispatched=false`，`result=FAIL`。

---

## 6. 風險與回滾

| 風險 | 說明 | 緩解 |
|---|---|---|
| 「復原／重做」誤觸 | 選單項走回應鏈，WebView 內才有作用；在側欄改名時走的是 `NSTextField` 自己的 undo | 標準行為，與 Safari 一致 |
| 選單項灰掉 | 若回應鏈上沒人實作 `paste:`，項目會變灰 | 已驗證 `WKContentView` 有實作 |
| 與網頁自己的 `⌘Z` 衝突 | 網頁若自行攔截 keydown，會先收到 | 瀏覽器本來就這樣 |

回滾：換回 v0.15 的 `.app`。沒有任何資料格式變動。

---

## 7. 仍未處理

1. **熱鍵可自訂**：目前固定 `⇧⌘1–9`
2. **匯入前預檢重複**：指紋命中時直接問「要保留哪一個」
3. **記憶體壓力自適應**：門檻固定 10 分鐘
4. **頭像補抓**：只在使用者切過去時抓
5. **省資源釋放後 DOM 焦點會丟**：超過 10 分鐘被釋放的帳號，切回來要重新點一下輸入框

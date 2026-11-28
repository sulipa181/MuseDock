# MuseDock v0.17 → v0.18 變更說明

- 讀者：開發／接手的人。使用者向的另一份在 [`UPDATE-v0.18.md`](UPDATE-v0.18.md)
- 範圍：`main.swift`（`Store` 三路分流、`Log` + `emit`）、`tools/update.sh`、`tools/release.sh`、文件
- 是否影響既有資料：**不影響**（`accounts.json` 格式沒變）
- 是否需重新登入：**不需要**
- 版本號：`CFBundleShortVersionString` 0.17 → **0.18**

這一版沒有介面變化。做的是兩件「出事時救命」的事，加上把重複手打的流程收成腳本。

---

## 0. 檔案與符號變更

```
main.swift          | +165 −122   全部實作（3284 行）
tools/update.sh     | 新增  105   一鍵升級
tools/release.sh    | 新增  163   一鍵發版
docs/DEVELOPER.md   |  +60        §3 儲存分流、§8 日誌、坑 19、沿革
docs/CHANGELOG-v0.18.md | 新增    本文件
docs/UPDATE-v0.18.md    | 新增    使用者向
```

| 符號 | 職責 |
|---|---|
| `Store.frozen` | 檔案存在卻解不出結構時為 true；`save()` 見此值直接 return |
| `Store.brokenBackup` | 隔離出來的檔名，給日誌／UI／自測引用 |
| `Store.quarantine(_:)` | 把原檔寫成 `accounts.broken-<yyyyMMdd-HHmmss>.json`，只留最近 5 份 |
| `Store.seedAccounts()` / `seedAndPersist()` | 拆開「產生」與「產生並寫入」。原本混在一起，正是覆蓋的來源 |
| `enum Log` | `Log.url` / `setup()` / `rotateIfNeeded()` / `write(_:)` |
| `emit(_:)` | 取代 `print`：`fputs` 到 stdout + `Log.write`。122 處已全數替換 |
| `Controller.subtitle(for:)` | 狀態列主文字，`frozen` 時追加毀損提示 |
| `Controller.warnIfStoreFrozen()` | GUI 啟動彈一次說明；CLI／自測條件下不彈 |
| `MUSE_STORE_BROKEN_TEST` | 四項檢查的自測入口 |

`Store.load()` 的分流是本版最容易改壞的地方：

```
檔案不存在 ──────────────→ seedAndPersist()      寫入佔位帳號
檔案存在 + 解得開 ───────→ 補 slot → 回傳（照舊）
檔案存在 + 解不開 ───────→ quarantine → frozen=true → seedAccounts()（不寫）
```

第三條**必須**回傳能開 UI 的清單，否則 `accounts.isEmpty` 會走空狀態分支；但這個清單
永遠不會被存回去，因為 `save()` 已被 `frozen` 擋住。這兩件事要一起成立才算對。

---

## 1. 一頁摘要

| 問題 | 之前 | 現在 |
|---|---|---|
| `accounts.json` 讀得到但解不出結構 | 回退種子並 `save`，所有帳號無聲消失 | 備份為 `accounts.broken-*.json`、轉唯讀、拒絕寫入、GUI 提示 |
| 從 Dock／`open` 啟動時的診斷輸出 | 全部丟進 `/dev/null` | 同時寫 `~/Library/Logs/MuseDock.log`（4MB 輪替兩份） |
| 升級與發版流程 | 手打三行／六七步，漏步驟無感 | `./tools/update.sh`、`./tools/release.sh` |

---

## 2. 為什麼「解不開就回退種子」是不可接受的

`Store.load()` 原本長這樣：

```swift
if let data, let list = try? JSONDecoder().decode([Account].self, from: data) { return list }
let seed = [Account(name: "帳號 1", …), Account(name: "帳號 2", …)]
save(seed)          // ← 直接覆蓋
return seed
```

`try?` 把失敗吞掉了，於是「解不開」與「沒有檔案」走了同一條路。這在兩種情況下會真的發生：

1. **版本落差**：未來給 `Account` 加一個必填欄位，舊版 App 讀到新版寫的檔案 → 解不開 → 覆蓋。
   （現在所有欄位都用 `decodeIfPresent`，所以「加欄位」本身安全；但總有一天會遇到不得不改結構的改動。）
2. **外部改壞**：手動編輯出錯、磁碟寫入異常、同步工具把檔案改寫成非 JSON。

v0.13 的原子寫只保證「不會讀到半截檔案」，對這兩種完全無效——檔案是完整的，只是內容不對。
而且失敗是**靜默**的：不報錯、不彈窗，只表現為「帳號清空了」，接著 `storeID` 也沒了，
連帶 `~/Library/WebKit/.../<storeID>` 的登入態變成孤兒目錄。

---

## 3. 修法

### 3.1 分流 + 唯讀

```swift
if let data, !data.isEmpty {
    frozen = true
    brokenBackup = quarantine(data)
    emit("STORE_BROKEN …")
    return seedAccounts()          // 能開 UI，但存不回去
}
return seedAndPersist()            // 真正的首次啟動
```

`quarantine` 用「已讀到的 Data」寫備份，而不是 `copyItem`——備份內容必須與判定失敗時
看到的位元組完全一致，否則等於備了另一份東西。只留最近 5 份，避免反覆出錯把目錄塞滿。

`save()` 的擋法：

```swift
if frozen {
    emit("STORE_FROZEN 拒絕寫入（accounts.json 已備份為 …）；請處理後重啟")
    return
}
```

每次都印，不是只印一次。這行若在一小時內出現幾十次，代表某段程式碼一直「以為自己在修資料」，
從日誌就能看出是哪個操作在反覆嘗試——只印一次反而失去線索。

### 3.2 UI 提示

狀態列在 `frozen` 時追加 `⚠︎ 資料檔毀損，本次不寫入`。沒有這個，使用者改名字、匯入、
刪帳號都會「看起來成功」，然後重啟發現全沒了——那會被當成 bug 回報，而真正的問題在更早。

`warnIfStoreFrozen()` 只在 GUI 啟動時彈一次，且排除 `PROBE_MODE` / `MUSE_STORE_SELFTEST` /
`KEYTEST` / `MUSE_WHO` / `MUSE_AVATAR_PROBE`；否則 CI 與自測會卡在 modal 上。

### 3.3 日誌

```swift
func emit(_ items: Any...) {
    let line = items.map { String(describing: $0) }.joined(separator: " ")
    fputs(line + "\n", stdout)
    Log.write(line)
}
```

- 參數語意與 `print` 相同（空格分隔、換行結尾），所以 122 處是機械替換，沒有行為差異。
- `fputs` 配合既有的 `setvbuf(stdout, nil, _IONBF, 0)`，終端即時可見（開發時習慣不變）。
- `Log.write` 用 `NSLock` 串行化；每 512 行才 stat 一次大小，常駐選單列的行程不會把目錄 IO 打爆。
- 4MB 輪替：`MuseDock.log` → `MuseDock.log.1`（覆蓋舊的），只留兩份。
- `MUSE_STATE_DIR` 在場時日誌跟著走，示範／自測不污染真實那份。

啟動第一行固定是版本、pid、UTC 時間，排查時先確認「你看的是不是那支行程」。

---

## 4. 驗證

```
$ MUSE_STATE_DIR=/tmp/md-broken MUSE_STORE_BROKEN_TEST=1 ./MuseDock.app/Contents/MacOS/MuseDock
STORE_BROKEN accounts.json 有 12B 但解不出結構；已備份為 accounts.broken-20261128-132059.json，本次不寫入
STORE_BROKEN_TEST bytes=12 frozen=true accounts=2 backupOK=true backupSame=true
STORE_FROZEN 拒絕寫入（accounts.json 已備份為 accounts.broken-20261128-132059.json）；請處理後重啟
STORE_BROKEN_TEST unchanged=true result=PASS
```

`unchanged=true` 是關鍵：`load()` 之後與 `save()` 之後各讀一次原檔，兩次都必須與測試前位元組相同。

回歸（確認沒把首次啟動弄壞）：

```
$ MUSE_STATE_DIR=/tmp/md-fresh MUSE_STORE_SELFTEST=1 ./MuseDock.app/Contents/MacOS/MuseDock
STORE_SELFTEST begin accounts=2 rounds=200
STORE_SELFTEST done readable=true bytes=357
```

鍵盤路徑（v0.17 的成果，改 `Store` 不該影響它）：

```
KEYTEST idx=1 slot=2 t=0 pasteMenu=OK inWebView=true responder=WKWebView
PASTETEST tag=keytest token=MUSE-PASTE-5257 dispatched=true key=true result=PASS
```

日誌落盤（正式實例，從 `open` 啟動）：

```
$ tail -4 ~/Library/Logs/MuseDock.log
=== MuseDock 0.17 pid=24948 2026-11-28T05:21:23Z log=/Users/sulipa/Library/Logs/MuseDock.log
INSTANCE_LOCK acquired pid=24948
IDLE_TIMER tick=60s releaseAfter=600s
FOCUS name=Grass attempt=0 state=already
```

---

## 5. 行為差異

| | v0.17 | v0.18 |
|---|---|---|
| 壞檔啟動 | 覆蓋成種子帳號 | 備份 + 唯讀 + 彈窗 + 狀態列提示 |
| 壞檔期間的操作 | 正常寫入（蓋掉原資料） | 全部被擋，每次印 `STORE_FROZEN` |
| 日誌 | 只有 stdout（GUI 啟動時等於沒有） | stdout + `~/Library/Logs/MuseDock.log` |
| 磁碟佔用 | — | 日誌最多 8MB（兩份 ×4MB）＋ 最多 5 份壞檔備份 |

**副作用**：`emit` 每行多一次檔案寫入。啟動與切換的日誌量很小（十幾行／分鐘），
但 `MUSE_IDLE_TEST` 這類高頻自測會讓日誌長得快——這也是輪替要存在的理由。

---

## 6. 升級與回滾

```bash
# 升級（v0.18 起有腳本）
./tools/update.sh

# 回滾
./tools/rollback.sh          # 上一個版本
./tools/rollback.sh main     # 回到最新
```

`update.sh` 做的正是原本手打的三步，另外多兩件事：骯髒工作區先擋下（`git pull` 會撞車）、
`pkill` 之後輪詢等 `instance.lock` 真的釋放（不等就會撞上單一實例鎖，看起來像「沒生效」）。

`release.sh` 一次做掉：改版本號（`build.sh` / README 含日期 / DEVELOPER）→ 建置並校驗打包版本
→ 可選 `--test` 跑 16 秒 KEYTEST → commit → tag → push → `gh release`。手打這套最容易漏的三件事
（版本號沒改、文件沒同步、tag 沒推）都寫在腳本開頭。

---

## 7. 被否掉的方案

| 方案 | 為什麼不用 |
|---|---|
| 給 `accounts.json` 加 `schemaVersion`（改成 `{version, accounts}`） | 格式一改，**舊版 App 讀到新檔就解不開**——正好會走進這次新加的「損壞」分支，等於讓回滾失效。要加就得同時讓新舊兩版都能讀（先寫舊格式、附加欄位），成本遠大於這一版的收益。等真要改結構時再一起做 |
| 解不開時把檔案刪掉讓它重新 seed | 等於換一種方式銷毀資料，只是看起來「乾淨」 |
| 壞檔時直接 `exit`，不讓使用者進 App | 進不去就無法截圖、無法看日誌、無法先改用別的帳號。只讀模式能做的事更多 |
| 用 `NSLog` / `os_log` 取代自建日誌 | 統一 log 用 `log show` 查，但要教使用者、且容易與系統日誌混在一起。`~/Library/Logs/` 是 macOS 的慣例位置，「打開資料夾就找得到」更重要 |
| 用 pipe + tee 重定向 stdout，不改 122 處 `print` | 會破壞既有的自測方式（腳本靠 `> 檔案` 讀 stdout），而且行程結束時尾部容易丟。`emit` 是機械替換，風險更低 |
| 壞檔時自動嘗試「修復 JSON」（補逗號、截斷尾部） | 猜錯就是把資料改得更壞。備份原檔讓人自己處理，是唯一可接受的預設 |

---

## 8. 回歸清單

```bash
./build.sh

# 儲存：壞檔保護（四項檢查）
rm -rf /tmp/md-broken && mkdir -p /tmp/md-broken
printf '{"oops": 1}\n' > /tmp/md-broken/accounts.json
MUSE_STATE_DIR=/tmp/md-broken MUSE_STORE_BROKEN_TEST=1 \
  ./MuseDock.app/Contents/MacOS/MuseDock
#   期望：STORE_BROKEN → STORE_FROZEN → result=PASS、exit 0
#   以及 accounts.json 位元組不變、accounts.broken-*.json 內容相同

# 儲存：首次啟動與原子寫（不能被上面的改動弄壞）
rm -rf /tmp/md-fresh && mkdir -p /tmp/md-fresh
MUSE_STATE_DIR=/tmp/md-fresh MUSE_STORE_SELFTEST=1 \
  ./MuseDock.app/Contents/MacOS/MuseDock
#   期望：done readable=true、exit 0

# 鍵盤路徑（v0.17 的成果）
MUSE_STATE_DIR=/tmp/md-key MUSE_KEYTEST=1 MUSE_DEMO=1 MUSE_START_SLOT=1 \
  ./MuseDock.app/Contents/MacOS/MuseDock
#   期望：PASTETEST … result=PASS

# 日誌
tail -5 ~/Library/Logs/MuseDock.log
```

手動兩項：

1. 正常啟動一次，確認 `~/Library/Logs/MuseDock.log` 有新增，且第一行版本號正確
2. 把 `accounts.json` 改成 `{}` 再啟動 → 應彈窗、狀態列有 `⚠︎`，改回原內容後重啟恢復正常

---

## 9. 仍未處理

- **熱鍵不可自訂**：`⇧⌘1–9` 與其他 App 衝突時只能走選單。
- **匯入前不預檢重複**：`duplicateMap()` 已存在，但等匯入完才標 ⚠︎。
- **記憶體壓力不自適應**：`os_proc_available_memory()` 的閾值在沙箱裡驗不了（`ps` 被拒），
  改了也無法用數據說明有效。現有「閒置 10 分鐘」夠用。
- **`main.swift` 3284 行**：該拆，但要先有日誌（本版有）與回歸清單兜底再動。

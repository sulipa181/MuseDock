# 變更說明：v0.12 → v0.13

- 日期：2026-11-27
- 範圍：`main.swift`（新增 `InstanceLock`、改寫 `Store.save/load`）、`build.sh`（版本號）、`docs/DEVELOPER.md`（新增 §4.8、§3 寫入安全性）
- 是否影響既有資料：**不影響**。`accounts.json` 結構未動，WebKit 資料目錄未動
- 是否需重新登入：**不需要**
- 版本號：`CFBundleShortVersionString` 0.12 → **0.13**

---

## 1. 一頁摘要

| 改動 | 類型 | 使用者感知 |
|---|---|---|
| 單一實例鎖（`flock` on `instance.lock`） | 新功能 | 連點兩次不會再開第二個；會被叫回原本那個視窗 |
| 寫入型 CLI 拒絕並存 | 安全性 | 維護命令在 App 開著時會中止，不再冒險覆寫 `accounts.json` |
| `Store.save()` 原子寫入 + 跨行程檔案鎖 | **修 bug** | 以前中途被 kill 可能留下半截 JSON，現在不會 |
| `STORE_CONFLICT` 偵測 | 可觀測性 | 檔案被外部改過時會出聲，不再無聲丟帳號 |

一句話：**以前連點兩下是「兩個 MuseDock」，現在是「一個 MuseDock，視窗跳出來」；
而且就算真的出現第二個，也不會寫出壞檔。**

---

## 2. 為什麼要做

`Store.save()` 的實作是「整份陣列序列化後覆寫檔案」，沒有鎖、沒有版本號、沒有讀回比對。
兩個行程同時活著時：

```
行程 A：讀 accounts.json（3 筆）→ 使用者刪掉 3 號 → 寫回（2 筆）
行程 B：早先讀到（3 筆，記憶體中）→ 使用者改了個名 → 寫回（3 筆，3 號復活）
```

結果是「刪掉的帳號又回來」，而且對應的 WebKit 資料目錄已經被 `purgeWebsiteDataDir` 刪了，
卡片點了只會得到一個空身分——比崩潰更難查，因為沒有任何錯誤訊息。

觸發路徑比想像中多：

- Dock／Finder 連點兩下（第二次啟動不一定被 LaunchServices 合併）
- 一邊開著 App，一邊在終端機跑 `MUSE_DROP_SLOT` 或 `MUSE_CHROME_APPLY`
- 開機自動啟動 + 使用者手動再開一次

## 3. 怎麼做的

`flock(LOCK_EX | LOCK_NB)` 鎖 `~/Library/Application Support/MuseDock/instance.lock`，
依「啟動模式」決定搶不搶鎖：

| 模式 | 判定 | 行為 |
|---|---|---|
| 一般啟動 | 沒有任何相關 `MUSE_*` 變數 | 搶排他鎖；搶不到 → 叫回既有實例 → `exit(0)` |
| 寫入型 CLI | `MUSE_DROP_SLOT` / `MUSE_WIPE_SLOT` / `MUSE_IMPORT_FILE` / `MUSE_CHROME_APPLY` | 搶排他鎖；搶不到 → `exit(3)` 並說明原因 |
| 唯讀 CLI | `MUSE_SNAPSHOT` / `MUSE_STATUS_TEST` / `MUSE_CLOSE_TEST` / `MUSE_CHROME_LIST` / `MUSE_CHROME_IMPORT` / `MUSE_WHO` / `MUSE_AUTOSTART` | **不搶鎖**，可與執行中的實例並存 |

唯讀那組放行是刻意的：開發時常需要「App 開著 + 立刻截圖看版面」，
若一律擋掉，每次改 UI 都得先關 App 再開，反而讓人想繞過鎖。

### 為什麼是 flock，不是 pid 檔

| 方案 | 問題 |
|---|---|
| pid 檔 + `kill(pid, 0)` | `kill -9`、斷電、重開機後留殘留檔；pid 還可能被新行程重用 → 誤判「已在執行」，只能手動刪檔 |
| 只查 `NSRunningApplication` | 兩個行程同時啟動時雙方都還沒註冊完，都查不到對方 → 兩個都活著（TOCTOU） |
| `flock` | 仲裁在 kernel：`close(fd)` 或行程結束（含 crash、`kill -9`）自動釋放，無殘留、無競態 |

`NSRunningApplication` 仍有用，但只用來「叫醒既有實例」（`activate`），不用來判斷能不能啟動。

### 叫回視窗為什麼要發通知

常駐模式下關窗只是 `orderOut`——App 沒有可見視窗，單純 `activate` 不會把視窗拉回來。
所以第二個行程會先發 `local.sulipa.musedock.show`（`DistributedNotificationCenter`），
由執行中的實例呼叫 `showWindow()`，再 `activate`。

---

## 4. 行為差異

| 場景 | v0.12 | v0.13 |
|---|---|---|
| 連點兩下 App | 兩個行程、兩份記憶體狀態、互相覆寫 | 只開一個，第二次啟動把原視窗叫回前景 |
| App 開著跑 `MUSE_WIPE_SLOT` | 兩個行程同時動同一份資料 | 直接拒絕，`exit 3`，提示先關 App |
| App 開著跑 `MUSE_SNAPSHOT` | 可跑 | 仍可跑（唯讀不搶鎖） |
| `kill -9` 之後再開 | 正常 | 正常（鎖由 kernel 釋放，無需清檔） |

---

## 5. 驗證

實測輸出（2026-11-27）：

```console
$ /Applications/MuseDock.app/Contents/MacOS/MuseDock
INSTANCE_LOCK acquired pid=19594
LOGIN_PROBE name=甲 loggedIn=true api=200 changed=false

# 同一個 shell 再啟動一次
$ /Applications/MuseDock.app/Contents/MacOS/MuseDock
SINGLE_INSTANCE already running pid=19594，已叫回既有視窗
（立刻返回，exit=0）

# 唯讀 CLI：放行
$ MUSE_STATUS_TEST=1 /Applications/MuseDock.app/Contents/MacOS/MuseDock
STATUS item=true hasIcon=true items=14
  ◉ 甲　⇧⌘1 …

# 寫入型 CLI：拒絕
$ MUSE_IMPORT_FILE=/tmp/nope.txt MUSE_IMPORT_ACCOUNT=1 /Applications/MuseDock.app/Contents/MacOS/MuseDock
REFUSE 另一個 MuseDock 正在執行（pid 19594）；此命令會改寫 accounts.json，已中止
（exit=3）

# 強制終止後（kill -9），鎖應自動釋放
$ pkill -9 -f "MuseDock.app/Contents/MacOS/MuseDock"
$ /Applications/MuseDock.app/Contents/MacOS/MuseDock
INSTANCE_LOCK acquired pid=19874     ← 沒有殘留鎖，直接取得
```

檢查清單指令見 `DEVELOPER.md` §12 第 6 項。

---

## 6. 限制與風險

| 項目 | 說明 |
|---|---|
| 鎖的範圍是「同一份 Application Support」 | 若把 App 複製成兩份、用不同 bundle id 跑，會鎖到不同檔案——但那種用法本來就會讀同一份 `accounts.json`，屬已知風險 |
| 沒有「切換到既有實例並帶參數」 | 第二次啟動只會叫回視窗，不會把 `MUSE_START_SLOT` 之類的參數傳給既有行程 |
| 只擋行程層級 | 不防「兩個不同使用者的 session」或外部程式直接改 `accounts.json` |
| 鎖檔會一直存在 | 內容是持鎖 pid，僅供錯誤訊息使用；**不要**用「檔案存在」判斷是否在執行 |

**回滾**：換回 v0.12 的 `MuseDock.app` 即可，`accounts.json` 與資料目錄都不受影響；
`instance.lock` 留著也無害（舊版不讀它）。

---

## 7. 仍未處理

1. **省資源模式**：閒置 N 分鐘釋放非當前帳號的 `WKWebView`
2. **Muse 真實頭像**：`img[src*="avatar"]` 可抓
3. **熱鍵可自訂**：目前固定 `⇧⌘1–9`
4. **匯入前預檢重複**：指紋命中時直接問「要保留哪一個」

---

## 8. 追加：寫入層加固（同日）

實例鎖只擋得住「MuseDock 自己」，擋不住「同一份 `accounts.json` 被別人寫」。
所以把保護下沉到 `Store`，順手修掉一個原本就存在的真 bug。

### 8.1 修掉的 bug：非原子寫入

原本是 `try? data.write(to: file)`。若在寫入過程中程式被 `kill`、斷電、或磁碟滿，
`accounts.json` 會停在「寫了一半」的狀態——檔案存在、但 JSON 解析失敗，
下次啟動 `Store.load()` 直接掉進 seed 分支，**四個預設帳號蓋掉使用者真正的三個**。

改成 `options: .atomic`（同目錄暫存檔 → `rename`）：rename 在檔案系統層是原子的，
讀取端只會看到「舊的完整檔」或「新的完整檔」。

### 8.2 加上跨行程檔案鎖

`accounts.lock` + `flock`：`save()` 持 `LOCK_EX`、`load()` 持 `LOCK_SH`。
這層不解決邏輯上的 lost update（那要靠實例鎖），但保證不會有兩個行程同時在改同一個 inode。

### 8.3 加上衝突偵測

`Store.lastDigest` 記住上次讀到／寫入內容的 FNV-1a 64 指紋。寫入前若發現磁碟上的內容
與記憶中的不同：

```
STORE_CONFLICT 檔案已被其他行程改過（磁碟 1959B / 本次 1565B），以本次為準
```

仍以本次為準（拒絕寫入會讓當前實例的狀態與磁碟永久分叉，更糟），但至少留下一行證據。
沒有這行的話，「帳號怎麼不見了」只能靠猜。

### 8.4 驗證

新增自測入口 `MUSE_STORE_SELFTEST=1`：載入 → 故意在檔案尾端加一個換行（模擬外部改動）
→ 連續 200 次 `Store.save` → 檢查可讀性。

```console
$ MUSE_STORE_SELFTEST=1 /Applications/MuseDock.app/Contents/MacOS/MuseDock
STORE_SELFTEST begin accounts=3 rounds=200
STORE_SELFTEST injected external change
STORE_CONFLICT 檔案已被其他行程改過（磁碟 1959B / 本次 1565B），以本次為準
STORE_SELFTEST done readable=true bytes=1565
```

同時開一個每 1 毫秒解析一次 `accounts.json` 的外部程式：

```console
READER samples=1468 bad=0
```

1468 次取樣、0 次讀到空檔或半截 JSON。測試後 `accounts.json` 與測試前的備份逐欄比對相同，
目錄內也沒有 `.tmp` 殘留。

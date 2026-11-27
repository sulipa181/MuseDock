# 變更說明：v0.14 → v0.15

- 日期：2026-11-27
- 範圍：`main.swift`（新增 `AvatarStore`、`AvatarView(image:)`、`scheduleAvatarCapture`、`avatarJS`、`runAvatarTest`；修 `scheduleFingerprint` 的空樣本覆寫；新增 `MUSE_WINDOW_FIT`）、`build.sh`（版本號）、`docs/DEVELOPER.md`（新增 §4.10）、`docs/screenshot-demo.png`（重拍）
- 是否影響既有資料：**不影響**。`accounts.json` 結構沒動；新增的 `avatars/` 目錄是純快取，刪掉會自己重抓
- 是否需重新登入：**不需要**
- 版本號：`CFBundleShortVersionString` 0.14 → **0.15**

---

## 1. 一頁摘要

| 改動 | 使用者感知 |
|---|---|
| 卡片頭像改成 AI 夥伴的形象（抽 `<video>` 的一幀） | 一眼分辨是哪個帳號，不必再靠名字 |
| 頭像存成 128×128 PNG，冷啟動直接讀 | 不需要先打開頁面才有臉 |
| 刪帳號／`wipe` 時一併刪頭像 | 不會留下已刪帳號的圖 |
| 修掉「空指紋樣本覆寫既有樣本」 | 重複帳號的 ⚠︎ 不會無故消失 |
| `MUSE_WINDOW_FIT=1` 截圖輔助 | 開發用；README 截圖不再被 Dock 擋住 |

一句話：**Muse 不給使用者頭像，那就用「這個帳號的 AI 夥伴」當臉。**

---

## 2. 為什麼不是「使用者大頭貼」

原本的計畫是抓 `img[src*="avatar"]`。實際 dump 之後發現這條路不存在：

| 現象 | 真相 |
|---|---|
| 頁面上 9 張 `<img>`，全是 `blob:`、256×256 WebP、顯示 19–40pt | 每個**空間（space）**的 3D 圖示，跟帳號無關，還會隨內容變 |
| `background-image` | 0 個 |
| 唯一的「頭像」`[data-hatch-avatar-interaction]`（56×56，`aria-label="Muse"`） | 裡面是 `<video>`，點開是 **Muse(AI) 自己的檔案面板**（已連結 / 排定任務），沒有使用者名稱或 email |
| `/api/me`、localStorage、IndexedDB | 都沒有使用者 profile（只有 `hatch:debug:device-id`） |

所以卡片上的 email 其實一直是 Chrome 的 Google 帳號，不是 Muse 的——這件事 v0.10 就已經寫在文件裡。

**但那個 `<video>` 有價值**：它的形象**因帳號而異**。實測：

| 帳號 | 形象 | 首次抽幀大小 |
|---|---|---|
| 甲（1 號） | 白色絨毛小生物 | 25,110 B |
| 乙（2 號） | 黑貓抱臂、挑眉 | 28,056 B |
| 丙（3 號） | 與甲相同（同一個 Muse 帳號的前身） | — |

同一帳號重複抽幀的 md5 一致，所以它是穩定的「臉」，不是隨機裝飾。

---

## 3. 實作

```
didFinish / select(i)
 └ scheduleAvatarCapture(for:)
      ├ DEMO → 直接返回（示範資料沒有真頁面）
      ├ 已登入？WebView 存在且 window != nil？host == muse.ai？
      ├ 快取已存在 → 返回（MUSE_AVATAR_FORCE=1 可強制重抓）
      ├ avatarBusy / 60 秒節流（失敗也記，避免每次 didFinish 都重試）
      ├ 延遲 8 秒 → avatarJS
      │    ├ 挑 videoWidth 最大的 <video>（readyState < 2 → rsN，重試）
      │    ├ 掃亮度包圍盒 → side = 頭寬 × 1.04、水平置中、頭頂留 6%
      │    ├ drawImage → 128×128 → toDataURL('image/png')
      │    └ 失敗 → 5 秒後重試，最多三次
      └ 成功 → AvatarStore.save(png:for:) → rebuildCards()
```

抽幀腳本（實際跑在 page context）：

```js
const vs = [...document.querySelectorAll('video')].filter(v => v.videoWidth > 0);
vs.sort((a, b) => b.videoWidth * b.videoHeight - a.videoWidth * a.videoHeight);
const v = vs[0];
// 背景是純黑，用亮度掃出角色邊界（每 2px 取樣）
for (let y = 0; y < h; y += 2)
  for (let x = 0; x < w; x += 2) {
    const i = (y * w + x) * 4;
    if (d[i + 3] > 20 && (d[i] + d[i + 1] + d[i + 2]) > 60) { /* 更新 min/max */ }
  }
const side = Math.round(Math.min(Math.min(w, h), (maxX - minX) * 1.04));
```

### 為什麼要掃包圍盒

第一版寫死「邊長 = 0.78×畫面、垂直中心 0.36」，結果：

- 絨毛那張：臉被推到圓心外，右半邊全是身體
- 黑貓那張：下顎被切掉

兩個形象在畫面裡的大小差很多（頭寬約 0.62× 與 0.67× 畫面，垂直位置也不同），
固定比例不可能同時對。改成掃包圍盒後，實際抓到的裁切參數是：

```
甲  crop=(0, 0, 480)      身體寬到貼邊，直接整張
乙  crop=(123, 40, 472)   以頭為中心，兩隻耳朵都在框內
```

（`crop = (sx, sy, side)`，原圖 480² / 720²。）

### 卡片繪製

`AvatarView` 多一個 `image:` 參數：有圖就 `addClip` 成圓、畫上去，再加一圈 12% 的
`labelColor` 細線當邊界；沒圖就退回原本的首字母 + `Palette` 取色。

---

## 4. 順手修掉的 bug：空樣本覆寫指紋

這是這次改動時意外發現的，與頭像無關，但會讓 v0.10 的重複偵測失效。

**觸發**：切換帳號的瞬間，舊帳號的 WebView 被移出畫面。`fingerprintJS` 只抓
`offsetParent !== null` 的元素，所以回傳 `n=0`。而舊程式碼的規則是
「`n < 2` 且是第一次 → 重試一次」，**重試後仍為 0 就直接寫入**：

```
accounts[idx].fpItems = n >= 2 ? all : []      ← n=0 時寫入空陣列
```

結果 20 幾筆樣本被清空，`⚠︎ 同 1 號`的標記消失，而且不會自己恢復（除非再打開那個帳號）。

**修法**：`n < 2` 只重試、不寫入；兩次都失敗就保留舊值並印 `FP_KEEP`。

```swift
guard n >= 2 else {
    if attempt == 0 { /* 再試一次 */ }
    else if !accounts[idx].fpItems.isEmpty { print("FP_KEEP …") }
    return
}
```

實測：本次開發中真的踩到一次（`FP name=甲 n=0` → `fpItems` 變 0），修完後重啟，
甲的樣本回到 21 筆。

---

## 5. 頭像的生命週期

| 動作 | 頭像檔案 | 說明 |
|---|---|---|
| 刪除帳號 `performDelete` | 刪除 | 與 WebKit 目錄一起清 |
| `wipe`（清除網站資料） | 刪除 | 等於換身分，舊臉不該留 |
| 閒置釋放 WebView | 保留 | 切回來只重繪，不重抓 |
| 冷啟動 | 直接讀檔 | 不開頁面也有圖 |
| 換 `MUSE_STATE_DIR` | 跟著走 | 示範模式用自己的假頭像 |

---

## 6. 驗證方式

```bash
# 先關掉 App（MUSE_AVATAR_TEST 會寫快取，屬寫入型 CLI）
MUSE_AVATAR_TEST=1 /Applications/MuseDock.app/Contents/MacOS/MuseDock | grep AVATAR
```

預期輸出：

```
AVATAR_TEST start slot=1 name=甲 loggedIn=true
AVATAR_TEST dir=/Users/…/Library/Application Support/MuseDock/avatars
AVATAR name=甲 bytes=25110 vw=480 vh=480 crop=(0, 0, 480) at=6D2047BC-….png
AVATAR_TEST file=6D2047BC-….png exists=true bytes=25110 cacheCount=1
AVATAR_TEST result PASS
```

失敗時會看到 `AVATAR_RETRY … why=no-video|not-ready|rs0`，兩次後 `AVATAR_GIVEUP`。
`why=no-video` 通常是頁面還沒載入完或未登入（登入頁沒有這個影片）。

---

## 7. 這次的 README 截圖怎麼來的

截圖要換成有頭像的版本，但不能用真實帳號（信箱 + 對話內容會進版控）。做法：

1. `MUSE_STATE_DIR=/tmp/musedock-demo` + `MUSE_DEMO=1` 跑假資料（4 個帳號，甲/乙/丙/丁）
2. 假頭像用 PIL 畫四個虛構角色放進 `avatars/`（`MUSE_DEMO` 會跳過抽幀，所以不會被覆寫）
3. `MUSE_WINDOW_FIT=1` 讓視窗縮進可見區域，並印出 `WINDOW_FRAME`：

```
WINDOW_FRAME x=100 y=86 w=1240 h=776 screen=1440x900 scale=2
→ 裁切 (200, 76) – (2680, 1628)，得到 2480×1552，再縮成 1600 寬
```

`MUSE_WINDOW_FIT` 只影響截圖，平常啟動不會動使用者調好的視窗大小。

---

## 8. 風險與回滾

| 風險 | 說明 | 緩解 |
|---|---|---|
| 抽幀抓到奇怪的動畫格 | 影片是動畫，可能停在歪頭／閉眼的瞬間 | 延遲 8 秒（通常已在待機循環）；不滿意可 `MUSE_AVATAR_FORCE=1` 重抓 |
| 頭像與帳號對不上 | 快取檔名用 `storeID`，正常不會錯 | 換帳號時不會重用 `storeID` |
| 快取目錄膨脹 | 一張 26KB，10 個帳號約 260KB | 可整個刪除，會自動重抓 |

回滾：換回 v0.14 的 `.app` 即可。`accounts.json` 沒有新欄位，舊版讀得懂；
`avatars/` 目錄留著也不影響舊版。

---

## 9. 仍未處理

1. **熱鍵可自訂**：目前固定 `⇧⌘1–9`
2. **匯入前預檢重複**：指紋命中時直接問「要保留哪一個」
3. **記憶體壓力自適應**：門檻固定 10 分鐘
4. **頭像補抓**：只在使用者切過去時抓；可在背景依序補齊已登入帳號
5. **形象相同的帳號**：甲與丙的圖一樣，只能靠名稱與編號區分

# MuseDock

把多個 [Muse](https://muse.ai) 帳號集中在同一個 macOS 視窗裡切換 —— 每個帳號各自擁有**完全隔離的 Cookie / localStorage / IndexedDB**，互不干擾，不必再開多個瀏覽器 Profile 或反覆登入登出。

純程式碼建 UI，沒有 Xcode 專案、沒有 storyboard、沒有第三方套件，只依賴 Command Line Tools。

![MuseDock](docs/screenshot-demo.png)

## 功能

| 功能 | 說明 |
|---|---|
| 多身分隔離 | 每個帳號一個 `WKWebsiteDataStore(forIdentifier:)`，登入態真正分開 |
| 快速切換 | 側邊欄卡片、全域熱鍵 `⇧⌘1–9`、選單列三種入口 |
| Chrome Profile 匯入 | 直接解密本機 Chrome 的 muse cookie 寫入指定帳號，不用手動匯出 |
| 來源標註 | 卡片副標題顯示 `Profile 11 · 你的 Google 帳號`，看得出資料從哪來 |
| 帳號頭像 | 抽該帳號 AI 夥伴的形象當卡片圖示（Muse 不提供使用者頭像），存成 128×128 快取 |
| 重複帳號偵測 | 用左側對話列表做指紋，同一個 Muse 帳號被匯入兩次會標 ⚠︎ |
| 登入狀態即時化 | 載入後探測 `/api/me`，cookie 過期會即時反映在圓點與狀態列 |
| 省資源模式 | 切走的帳號閒置 10 分鐘後釋放 WebView，切回自動重建且仍登入 |
| 選單列常駐 | 關窗不退出，從選單列或熱鍵隨時叫回 |
| 開機自動啟動 | `SMAppService`，可在選單裡勾選 |
| 單一實例 | `flock` 仲裁，連點兩次只會叫回既有視窗，不會兩個行程搶同一份狀態檔 |

## 需求

- macOS 14 以上（arm64）
- Command Line Tools（`xcode-select --install`），不需要完整 Xcode

## 建置與安裝

```bash
git clone https://github.com/sulipa181/MuseDock.git
cd MuseDock
./build.sh
```

`build.sh` 會編譯、打包 `Info.plist`、產生 `AppIcon.icns`、ad-hoc 簽章，最後複製到 `/Applications`。

> ad-hoc 簽章沒有公證，換機器第一次開啟請右鍵 →「打開」。

## 使用

1. 開啟 App，側邊欄「⋯」→ **從 Chrome 匯入**，選一個已登入 Muse 的 Chrome Profile
2. `⇧⌘1`～`⇧⌘9` 切換帳號；編號一旦分配就不再重用
3. 關掉視窗不會退出，從選單列圖示或熱鍵叫回；`⌘Q` 才是結束

狀態檔與 WebKit 資料位置：

```
~/Library/Application Support/MuseDock/accounts.json     帳號清單（含 storeID、來源、指紋）
~/Library/Application Support/MuseDock/avatars/          卡片頭像快取（刪掉會自動重抓）
~/Library/WebKit/local.sulipa.musedock/WebsiteDataStore/  每個帳號的實際資料
```

## 專案結構

```
main.swift              UI + Controller + 診斷入口
ChromeCookies.swift     Chrome Profile 掃描與 cookie 解密（PBKDF2 + AES-128-CBC）
build.sh                編譯、打包、簽章、安裝
tools/draw_icon.py      程式化繪製 App 圖示
docs/DEVELOPER.md       開發說明（架構、流程、踩過的坑、自測入口）
docs/CHANGELOG-*.md     各版本變更說明
docs/screenshot-demo.png 示範截圖（假資料，非真實帳號）
```

## 文件

- [docs/DEVELOPER.md](docs/DEVELOPER.md) — 接手前先看，含資料模型、七個核心流程、13 條踩坑紀錄
- [docs/CHANGELOG-v0.17.md](docs/CHANGELOG-v0.17.md) — 最新變更（切換帳號後直接 `⌘V` 就能貼）
- 更早：[v0.16](docs/CHANGELOG-v0.16.md)（編輯選單 / ⌘V 修復）、[v0.15](docs/CHANGELOG-v0.15.md)（卡片頭像）、[v0.14](docs/CHANGELOG-v0.14.md)（省資源模式）、[v0.13](docs/CHANGELOG-v0.13.md)（單一實例鎖）、[v0.12](docs/CHANGELOG-v0.12.md)（登入狀態即時化）

## 已知限制

- Muse 前端不暴露登入帳號的 email，卡片上的 email 是**匯入來源的 Chrome Google 帳號**
- 重複偵測與頭像只能針對「被開啟過」的帳號，冷啟動當下未必有樣本
- Muse 沒有使用者頭像，卡片上顯示的是該帳號 AI 夥伴的形象；形象相同的帳號只能靠名稱與編號區分
- `arm64 / macOS 14` 是硬編碼的編譯目標，換 Intel 需改 `-target`

## 聲明

本專案是個人使用的小工具，與 Muse（muse.ai）官方無關；cookie 解密只在本機進行，不會上傳任何資料。

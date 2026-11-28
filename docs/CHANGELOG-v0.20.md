# MuseDock v0.19 → v0.20 變更說明

**主題：修一個複查 v0.19 時抓到的 UX bug——「建立新帳號」後不會再被誤問「這個 Profile 已經匯入過」。**

一個 commit、一處邏輯挪動。沒有資料格式變動，`accounts.json` 不用重新登入。

---

## 1. bug 是什麼

v0.19 的匯入預檢排在「目標帳號解析」**之後**。但「建立新帳號」那條分支會
**立刻 append 一個 `profileDir == p.dir` 的帳號並存檔**——於是緊接著的 `ownerOf(profileDir:)`
就把這個剛建的新帳號當成「已有主人」，使用者剛選完「建立新帳號」、又立刻跳出一個
「這個 Profile 已經匯入過了」的確認框。

不是資料錯誤、不是崩潰，純粹是**多問一次、令人錯亂**。因為涉及「寫入前攔截」的時機，
值得獨立修掉並記一筆坑（DEVELOPER 坑 22）。

## 2. 修法

把預檢整段挪到 `importChromeProfile(_:)` 的**最前面**——在任何 `append` / `Store.save()`
發生之前。這樣 `ownerOf` 看到的永遠是「匯入動作之前的帳號清單」，不會撞到自己剛建的帳號。

順手統一語意：`ownerOf` 加上 `!$0.profileDir.isEmpty` 的守衛，與 `MUSE_CHROME_LIST`
那一欄的判斷一致（空 `profileDir` 的帳號不算「佔用任何來源目錄」）。

```swift
func ownerOf(profileDir dir: String) -> Int? {
    guard !dir.isEmpty else { return nil }
    return accounts.firstIndex { !$0.profileDir.isEmpty && $0.profileDir == dir }
}
```

## 3. 驗證

`MUSE_IMPORT_PRECHECK` 的五種情境全部符合預期：

```
PRECHECK dir=Profile 11 already=3 owner=Grass 舊卡 target=3 same=true  confirm=重新匯入
PRECHECK dir=Profile 11 already=3 owner=Grass 舊卡 target=5 same=false confirm=仍要新增
PRECHECK dir=Default    already=- prompt=none
PRECHECK dir=Profile 99 profile=missing
（空 profileDir 的帳號不再被誤當成主人：查任何 Profile 都回 already=-）
```

基線四步（壞檔保護 / 原子寫 / 鍵盤路徑 / 日誌）全 PASS。

## 4. 影響範圍

| 情境 | v0.19 | v0.20 |
|---|---|---|
| 匯入已匯入過的 Profile | 問一次 | 問一次（不變） |
| 「建立新帳號」後 | 又問一次「已匯入過」 | 不問（修好了） |
| CLI `MUSE_CHROME_APPLY` / `MUSE_IMPORT_PRECHECK` | — | 不變 |

只有 GUI 的「建立新帳號」這條互動路徑受影響；CLI、資料格式、登入態都完全不變。

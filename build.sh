#!/bin/zsh
# 編譯 MuseDock.app（不需要 Xcode，只要有 Command Line Tools）
set -eu
cd "${0:A:h}"

APP="MuseDock.app"
BIN="$APP/Contents/MacOS/MuseDock"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 圖示（若存在 AppIcon.icns 就一起打包）
if [[ -f AppIcon.icns ]]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  echo "→ 打包圖示 AppIcon.icns"
fi

echo "→ 編譯中…"
swiftc -O -target arm64-apple-macos14.0 \
  -framework AppKit -framework WebKit -framework ServiceManagement \
  -lsqlite3 \
  -o "$BIN" main.swift ChromeCookies.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MuseDock</string>
  <key>CFBundleDisplayName</key><string>MuseDock</string>
  <key>CFBundleIdentifier</key><string>local.sulipa.musedock</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>0.5</string>
  <key>CFBundleShortVersionString</key><string>0.17</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>MuseDock</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

codesign -s - --force "$APP" 2>/dev/null || echo "（未簽章，仍可本機執行）"
echo "✓ 完成：$(pwd)/$APP"

# 同步一份到 /Applications，讓 Spotlight 與 Dock 找得到（失敗不中斷）
if [[ -w /Applications ]]; then
  rm -rf "/Applications/MuseDock.app"
  cp -R "$APP" "/Applications/MuseDock.app" 2>/dev/null \
    && echo "✓ 已同步到 /Applications/MuseDock.app"
fi

# 舊實例還在跑的話，新版只寫到磁碟、記憶體裡仍是舊的；
# 而且下次啟動會被單一實例鎖擋下（SINGLE_INSTANCE already running → 叫回舊視窗），
# 看起來就像「更新沒生效」——所以這裡一定要講出來。
RUNNING="$(pgrep -x MuseDock 2>/dev/null || true)"
if [[ -n "$RUNNING" ]]; then
  echo ""
  echo "⚠️  MuseDock 正在執行（pid ${RUNNING//$'\n'/, }）——磁碟上是新版，執行中的還是舊版。"
  echo "    ⌘Q 結束後再開才會換過來；直接開會被單一實例鎖擋下，只會叫回舊視窗。"
  echo "    一步到位：pkill -x MuseDock; sleep 1; open -a MuseDock"
fi

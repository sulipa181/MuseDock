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
  <key>CFBundleShortVersionString</key><string>0.15</string>
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

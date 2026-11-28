#!/bin/zsh
# MuseDock 發版：改版本號 → 建置 →（可選）自測 → commit → tag → push → GitHub Release
#
#   ./tools/release.sh 0.18                                  # 最常用
#   ./tools/release.sh 0.18 --title "MuseDock v0.18 — 一句話"
#   ./tools/release.sh 0.18 --notes docs/CHANGELOG-v0.18.md  # 預設會自動找這個檔
#   ./tools/release.sh 0.18 --test                           # 發版前先跑鍵盤自測
#   ./tools/release.sh 0.18 -n                               # 只印計畫
#
# 手打這套流程時最容易漏的三件事，腳本一次做掉：
#   ① build.sh 的版本號沒改（裝上去還是舊號，rollback 也會對不上）
#   ② README / DEVELOPER 的版本號與日期沒同步
#   ③ tag 沒推（Release 建得出來，但別人 clone 不到那個版本）
set -eu
cd "${0:A:h}/.."

info() { print -r -- "$@" }
die()  { print -r -- "✗ $@" >&2; exit 1 }
step() { print -r -- ""; print -r -- "▶ $@" }

VERSION=""; TITLE=""; NOTES=""; TEST=0; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY=1; shift ;;
    --test)       TEST=1; shift ;;
    --title)      [[ $# -ge 2 ]] || die "--title 需要一個值"; TITLE="$2"; shift 2 ;;
    --notes)      [[ $# -ge 2 ]] || die "--notes 需要檔案路徑"; NOTES="$2"; shift 2 ;;
    -h|--help)    sed -n '3,9p' "${0}" | sed 's/^# //'; exit 0 ;;
    -*)           die "不認識的參數：$1（用 -h 看用法）" ;;
    *)            [[ -z "$VERSION" ]] || die "只接受一個版本參數（多出來的是：$1）"
                  VERSION="$1"; shift ;;
  esac
done

[[ -n "$VERSION" ]] || die "用法：./tools/release.sh <版本> [--title …] [--notes 檔案] [--test]"
print -r -- "$VERSION" | grep -qE '^[0-9]+\.[0-9]+$' || die "版本格式要像 0.18，收到：$VERSION"
git rev-parse --git-dir >/dev/null 2>&1 || die "這裡不是 git 倉庫：$(pwd)"
[[ -f main.swift && -f build.sh ]] || die "找不到 main.swift / build.sh，請把腳本放在 <repo>/tools/ 下"
git tag | grep -qx "v$VERSION" && die "v$VERSION 已經存在，換個號"

OLD_VER="$(grep -o 'CFBundleShortVersionString</key><string>[0-9.]*' build.sh | grep -o '[0-9.]*$')"
[[ -n "$OLD_VER" ]] || die "讀不出 build.sh 裡的版本號"
[[ "$OLD_VER" != "$VERSION" ]] || die "build.sh 已經是 $VERSION，沒有要改的（重發同一版請手動處理）"
TODAY="$(date +%Y-%m-%d)"
TITLE="${TITLE:-MuseDock v${VERSION}}"

command -v gh >/dev/null 2>&1 || die "找不到 gh（GitHub CLI），請先安裝或跳過 Release 手動建"
gh auth status >/dev/null 2>&1 || die "gh 尚未登入（gh auth login）"

if [[ -z "$NOTES" && -f "docs/CHANGELOG-v${VERSION}.md" ]]; then
  NOTES="docs/CHANGELOG-v${VERSION}.md"
fi

info "版本：${OLD_VER} → ${VERSION}    日期：${TODAY}"
info "標題：${TITLE}"
info "說明：${NOTES:-（用 gh --generate-notes 自動產生）}"

step "1/6 同步版本號"
if [[ $DRY == 1 ]]; then
  info "  （dry-run）build.sh / README.md / docs/DEVELOPER.md：${OLD_VER} → ${VERSION}，README 日期 → ${TODAY}"
else
  python3 - "$OLD_VER" "$VERSION" "$TODAY" <<'PY'
import sys, re, pathlib
old, new, today = sys.argv[1:4]
def patch(path, pairs, required=True):
    p = pathlib.Path(path)
    if not p.exists():
        print(f"  ⚠️  {path} 不存在，跳過"); return
    s = p.read_text(encoding="utf-8"); n = s
    for a, b in pairs:
        n = n.replace(a, b, 1)
    if n != s:
        p.write_text(n, encoding="utf-8"); print(f"  ✓ {path}")
    else:
        print(f"  ·  {path} 已是 {new} 或找不到舊字串，未改")

patch("build.sh", [(f"<key>CFBundleShortVersionString</key><string>{old}</string>",
                    f"<key>CFBundleShortVersionString</key><string>{new}</string>")])
patch("README.md", [(f"`CFBundleShortVersionString {old}`", f"`CFBundleShortVersionString {new}`")])
# README 的 meta 行帶日期，一起換
p = pathlib.Path("README.md")
if p.exists():
    s = p.read_text(encoding="utf-8")
    s2 = re.sub(r"(`CFBundleShortVersionString " + re.escape(new) + r"`（)[0-9-]+(）)", r"\g<1>" + today + r"\g<2>", s, count=1)
    if s2 != s: p.write_text(s2, encoding="utf-8"); print("  ✓ README.md 日期")
patch("docs/DEVELOPER.md", [(f"# MuseDock 開發說明（v{old}）", f"# MuseDock 開發說明（v{new}）"),
                            (f"`CFBundleShortVersionString {old}`", f"`CFBundleShortVersionString {new}`")])
PY
  # 版本號真的改到了才算成功
  NEW_IN_SH="$(grep -o 'CFBundleShortVersionString</key><string>[0-9.]*' build.sh | grep -o '[0-9.]*$')"
  [[ "$NEW_IN_SH" == "$VERSION" ]] || die "build.sh 版本號仍是 $NEW_IN_SH，未改成 $VERSION"
fi

step "2/6 建置"
if [[ $DRY == 1 ]]; then
  info "  （dry-run）./build.sh"
else
  ./build.sh | grep -E "✓|⚠️|error:" || true
  GOT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/MuseDock.app/Contents/Info.plist)"
  [[ "$GOT" == "$VERSION" ]] || die "打包出來的版本是 $GOT，不是 $VERSION"
  info "  /Applications/MuseDock.app = $GOT"
fi

step "3/6 自測"
if [[ $TEST == 0 ]]; then
  info "  略過（要跑請加 --test；用假資料，16 秒）"
elif [[ $DRY == 1 ]]; then
  info "  （dry-run）KEYTEST 自測"
else
  TMP="$(mktemp -d)"; mkdir -p "$TMP/state"
  MUSE_STATE_DIR="$TMP/state" MUSE_KEYTEST=1 MUSE_DEMO=1 MUSE_START_SLOT=1 \
    ./MuseDock.app/Contents/MacOS/MuseDock > "$TMP/out.log" 2>&1 &
  TPID=$!
  sleep 16
  kill "$TPID" 2>/dev/null || true
  if grep -q "result=PASS" "$TMP/out.log"; then
    info "  PASTETEST PASS"
  else
    print -r -- "  自測輸出：" >&2; sed 's/^/    /' "$TMP/out.log" >&2
    die "自測沒過，先別發版（要跳過就別加 --test）"
  fi
  rm -rf "$TMP"
fi

step "4/6 提交"
if [[ $DRY == 1 ]]; then
  git status --short | sed 's/^/    /'
  info "  （dry-run）git add -A && git commit -m \"release: v${VERSION}\""
else
  git add -A
  if git diff --cached --quiet; then
    info "  沒有要提交的改動（版本號已在提交裡？）"
  else
    git commit -q -m "$(print -r -- "release: v${VERSION}")" -m "版本號 ${OLD_VER} → ${VERSION}；同步 README / DEVELOPER。"
    info "  $(git log --oneline -1)"
  fi
fi

step "5/6 打 tag"
if [[ $DRY == 1 ]]; then
  info "  （dry-run）git tag -a v${VERSION} -m \"v${VERSION}\""
else
  git tag -a "v${VERSION}" -m "v${VERSION}"
  info "  v${VERSION} → $(git rev-parse --short HEAD)"
fi

step "6/6 推送與 Release"
if [[ $DRY == 1 ]]; then
  info "  （dry-run）git push origin main --tags"
  info "  （dry-run）gh release create v${VERSION} --title \"${TITLE}\"${NOTES:+ --notes-file $NOTES}"
  exit 0
fi
git push --quiet origin main --tags || die "推送失敗（分支分岔或沒權限）；commit 與 tag 都在本機，處理後重推即可"
info "  已推送 main + tag"
if [[ -n "$NOTES" ]]; then
  gh release create "v${VERSION}" --title "$TITLE" --notes-file "$NOTES" >/dev/null
else
  gh release create "v${VERSION}" --title "$TITLE" --generate-notes >/dev/null
fi
info "  Release：$(gh release view "v${VERSION}" --json url -q .url)"

info ""
info "完成 v${VERSION}。要回滾：./tools/rollback.sh"

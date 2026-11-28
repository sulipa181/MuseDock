#!/bin/zsh
# MuseDock 一鍵回滾：切到指定版本 → 結束舊實例 → 重建 → 重開
#
#   ./tools/rollback.sh              # 回到上一個版本（預設：第二新的 tag）
#   ./tools/rollback.sh v0.15        # 回到指定 tag
#   ./tools/rollback.sh main         # 回到最新（main 分支）
#   ./tools/rollback.sh --list       # 看有哪些版本可回
#   ./tools/rollback.sh -n v0.16     # 只印計畫，不動任何東西
#
# 為什麼要「先結束舊實例」：build.sh 只覆寫磁碟上的 .app，執行中的行程仍是舊二進位；
# 加上單一實例鎖（v0.13），下一次啟動會 SINGLE_INSTANCE → 叫回舊視窗 → exit(0)，
# 看起來就像「回滾沒生效」。所以這支腳本自己負責把舊的收掉。
set -eu
cd "${0:A:h}/.."

info()  { print -r -- "$@" }
die()   { print -r -- "✗ $@" >&2; exit 1 }
step()  { print -r -- ""; print -r -- "▶ $@" }

DRY=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY=1 ;;
    -l|--list)    LIST=1 ;;
    -h|--help)    sed -n '3,7p' "${0}" | sed 's/^# //'; exit 0 ;;
    -*)           die "不認識的參數：$arg（用 -h 看用法）" ;;
    *)            TARGET="$arg" ;;
  esac
done

# ---------- 環境檢查 ----------
git rev-parse --git-dir >/dev/null 2>&1 || die "這裡不是 git 倉庫：$(pwd)"
[[ -f main.swift && -f build.sh ]] || die "找不到 main.swift / build.sh，請把腳本放在 <repo>/tools/ 下"

TAGS=(${(f)"$(git tag --sort=-creatordate)"})
(( ${#TAGS} )) || die "沒有任何 tag，無法回滾"

if [[ "${LIST:-0}" == 1 ]]; then
  info "可用版本（新 → 舊）："
  for t in ${TAGS[1,12]}; do
    printf "  %-8s %s  %s\n" "$t" "$(git log -1 --format=%ad --date=short "$t")" "$(git log -1 --format=%s "$t" | cut -c1-40)"
  done
  info ""
  info "目前：$(git describe --tags --always 2>/dev/null || echo '?')"
  exit 0
fi

CURRENT_TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
CURRENT_HEAD="$(git describe --tags --always 2>/dev/null || echo '?')"

if [[ -z "$TARGET" ]]; then
  if [[ -n "$CURRENT_TAG" ]]; then
    # 正好停在某個 tag 上 → 退回它之前的那個版本
    idx=$(( ${TAGS[(i)$CURRENT_TAG]} + 1 ))
    (( idx <= ${#TAGS} )) || die "已經是最舊的版本（$CURRENT_TAG），沒有更早的可回"
    TARGET="${TAGS[$idx]}"
  else
    # 在 main 或某個 commit 上（通常是改完還沒發版）→ 退回最新發布的 tag
    TARGET="${TAGS[1]}"
  fi
fi

if [[ "$TARGET" == "main" || "$TARGET" == "latest" || "$TARGET" == "master" ]]; then
  TARGET_REF="main"
  TARGET_DESC="main（最新）"
else
  git rev-parse -q --verify "refs/tags/${TARGET}^{commit}" >/dev/null \
    || die "沒有這個 tag：$TARGET（用 --list 看清單）"
  TARGET_REF="$TARGET"
  TARGET_DESC="$TARGET"
fi

# 已經在那個版本上就別白忙一場
if [[ "$TARGET_REF" == "$CURRENT_TAG" || "$TARGET_REF" == "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" && "$TARGET_REF" == "main" ]]; then
  info "目前已經在 ${TARGET_DESC}，不需要回滾。"
  exit 0
fi

# 已追蹤檔案的改動會擋住 checkout，而且有遺失風險——不替你 stash
DIRTY="$(git status --porcelain --untracked-files=no)"
if [[ -n "$DIRTY" ]]; then
  print -r -- "✗ 有未提交的改動，先處理再回滾：" >&2
  print -r -- "$DIRTY" | sed 's/^/    /' >&2
  print -r -- "    git stash          # 收起來（之後 git stash pop）" >&2
  print -r -- "    git checkout -- .  # 丟掉這些改動" >&2
  exit 1
fi
# 未追蹤的檔案不影響 checkout（會原樣留在原地），只提醒
UNTRACKED="$(git ls-files --others --exclude-standard)"
if [[ -n "$UNTRACKED" ]]; then
  print -r -- "（提醒）有未追蹤的檔案，會原樣保留："
  print -r -- "$UNTRACKED" | sed 's/^/    /'
fi

BUILT_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  /Applications/MuseDock.app/Contents/Info.plist 2>/dev/null || echo '未安裝')"

info "目前：${CURRENT_HEAD}（已安裝版本 ${BUILT_VER}）"
info "目標：${TARGET_DESC}"

if (( DRY )); then
  step "dry-run：以下是不會執行的步驟"
  info "  1. pkill -x MuseDock（等鎖釋放，最多 5 秒）"
  info "  2. git checkout ${TARGET_REF}"
  info "  3. ./build.sh"
  info "  4. open -a MuseDock"
  exit 0
fi

# ---------- 1. 收掉舊實例 ----------
step "結束執行中的 MuseDock"
if pgrep -x MuseDock >/dev/null 2>&1; then
  pkill -x MuseDock || true
  for _ in {1..50}; do
    pgrep -x MuseDock >/dev/null 2>&1 || break
    sleep 0.2
  done
  if pgrep -x MuseDock >/dev/null 2>&1; then
    die "舊實例還在跑（pkill 沒效），請手動 ⌘Q 後再跑一次"
  fi
  info "  已結束"
else
  info "  沒有在跑，跳過"
fi

# ---------- 2. 切版本 ----------
step "切到 ${TARGET_DESC}"
git checkout -q "$TARGET_REF"
NEW_HEAD="$(git describe --tags --always 2>/dev/null || echo '?')"
info "  現在是 ${NEW_HEAD}"

# ---------- 3. 重建 ----------
step "重建（./build.sh）"
if ! ./build.sh; then
  die "建置失敗——倉庫還停在 ${NEW_HEAD}，修好後重跑，或 git checkout main 放棄回滾"
fi

# ---------- 4. 驗證與啟動 ----------
NEW_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  /Applications/MuseDock.app/Contents/Info.plist 2>/dev/null || echo '?')"
step "啟動"
# 版本號只在發版時遞增：從 main 回到最新 tag、或重裝同一版，號碼都會一樣。
# 真正該看的是「有沒有換成目標 commit」，版本號只是給人看的對照。
if [[ "$NEW_VER" == "$BUILT_VER" ]]; then
  info "  版本號同為 ${NEW_VER}（來源可能不同，例如 main → 最新 tag；版本號只在發版時遞增）"
fi
open -a MuseDock
sleep 1
if pgrep -x MuseDock >/dev/null 2>&1; then
  info "  已啟動 pid=$(pgrep -x MuseDock | head -1) 版本 ${NEW_VER}"
else
  info "  ⚠️ 啟動後沒看到行程，請手動開啟 /Applications/MuseDock.app"
fi

info ""
info "完成：${BUILT_VER} → ${NEW_VER}（${NEW_HEAD}）"
info "資料不受影響：accounts.json 格式未變，不需要重新登入。"
if [[ "$TARGET_REF" != "main" ]]; then
  info ""
  info "（現在是 detached HEAD）要回到最新："
  info "    git checkout main && ./build.sh && open -a MuseDock"
  info "  或直接：./tools/rollback.sh main   ← 這個檔案在舊 tag 裡不存在，所以上面那行才保險"
fi

#!/bin/zsh
# MuseDock 一鍵升級：拉最新 → 結束舊實例 → 重建 → 重開
#
#   ./tools/update.sh             # 升級並重開
#   ./tools/update.sh --no-open   # 只重建，不重開（想先看日誌時用）
#   ./tools/update.sh -n          # 只印計畫，不動任何東西
#
# 為什麼要「先結束舊實例」：build.sh 只覆寫磁碟上的 .app，執行中的行程仍是舊二進位；
# 加上單一實例鎖（v0.13），下一次啟動會 SINGLE_INSTANCE → 叫回舊視窗 → exit(0)，
# 看起來就像「更新沒生效」。這支腳本自己負責收掉舊的，並確認鎖真的釋放。
set -eu
cd "${0:A:h}/.."

info() { print -r -- "$@" }
die()  { print -r -- "✗ $@" >&2; exit 1 }
step() { print -r -- ""; print -r -- "▶ $@" }

DRY=0
OPEN_AFTER=1
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY=1 ;;
    --no-open)    OPEN_AFTER=0 ;;
    -h|--help)    sed -n '3,7p' "${0}" | sed 's/^# //'; exit 0 ;;
    *)            die "不認識的參數：$arg（用 -h 看用法）" ;;
  esac
done

git rev-parse --git-dir >/dev/null 2>&1 || die "這裡不是 git 倉庫：$(pwd)"
[[ -f main.swift && -f build.sh ]] || die "找不到 main.swift / build.sh，請把腳本放在 <repo>/tools/ 下"

version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
              "${1:-/Applications/MuseDock.app}/Contents/Info.plist" 2>/dev/null || print -n "?" }

step "1/4 更新原始碼"
BEFORE_VER="$(version)"
info "  目前安裝版本：${BEFORE_VER}"
DIRTY="$(git status --porcelain --untracked-files=no)"
if [[ -n "$DIRTY" ]]; then
  # 有本地改動時 pull 會撞車；這通常代表「自己改完還沒提交」，不是升級
  print -r -- "✗ 有未提交的改動，先處理再升級：" >&2
  print -r -- "$DIRTY" | sed 's/^/    /' >&2
  print -r -- "    git stash  或  git commit  之後再跑一次" >&2
  exit 1
fi
if [[ $DRY == 1 ]]; then
  info "  （dry-run）git pull --ff-only"
else
  git pull --ff-only --quiet || die "git pull 失敗（分支分岔或有衝突），請手動處理"
  info "  HEAD：$(git log --oneline -1)"
fi

step "2/4 結束執行中的實例"
if pgrep -x MuseDock >/dev/null 2>&1; then
  OLD_PID="$(pgrep -x MuseDock | tr '\n' ' ')"
  if [[ $DRY == 1 ]]; then
    info "  （dry-run）pkill -x MuseDock  # ${OLD_PID}"
  else
    pkill -x MuseDock || true
    # 等鎖真的放掉：instance.lock 由 kernel 在行程結束時釋放，
    # 但 pkill 到真正結束有幾十毫秒的視窗，不等就會撞上單一實例鎖
    for i in {1..50}; do
      pgrep -x MuseDock >/dev/null 2>&1 || break
      sleep 0.1
    done
    pgrep -x MuseDock >/dev/null 2>&1 && die "舊實例仍在執行（${OLD_PID}），請手動 ⌘Q 後再試"
    info "  已結束 ${OLD_PID}"
  fi
else
  info "  沒有執行中的實例"
fi

step "3/4 重建"
if [[ $DRY == 1 ]]; then
  info "  （dry-run）./build.sh"
else
  ./build.sh | grep -E "✓|⚠️|error:" || true
  [[ -x /Applications/MuseDock.app/Contents/MacOS/MuseDock ]] || die "建置後找不到 /Applications/MuseDock.app"
fi

step "4/4 開新版"
AFTER_VER="$(version)"
if [[ $DRY == 1 ]]; then
  info "  （dry-run）open -a MuseDock"
  info ""
  info "（dry-run）預計：${BEFORE_VER} → ${AFTER_VER}（版本號只在發版時遞增，相同是正常的）"
  exit 0
fi
if [[ $OPEN_AFTER == 1 ]]; then
  open -a MuseDock
  for i in {1..40}; do
    pgrep -x MuseDock >/dev/null 2>&1 && break
    sleep 0.1
  done
  NEW_PID="$(pgrep -x MuseDock | head -1 || true)"
  [[ -n "$NEW_PID" ]] || die "開啟後沒有行程，看看日誌：tail -30 ~/Library/Logs/MuseDock.log"
  info "  已啟動 pid=${NEW_PID}"
fi

info ""
info "完成：${BEFORE_VER} → ${AFTER_VER}  ($(git describe --tags --always 2>/dev/null || echo '?'))"
info "日誌：tail -f ~/Library/Logs/MuseDock.log"
if [[ "$BEFORE_VER" == "$AFTER_VER" ]]; then
  info "（版本號相同：這次只是拉到新提交還沒發版，或本來就是同一版）"
fi

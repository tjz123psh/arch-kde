#!/usr/bin/env bash
# 描述：KOS（NextKDE）桌面更新器 —— 检查/更新/回退/本地补丁/构建部署 + fzf 菜单 + 每日检查通知
# Description: KOS (NextKDE) desktop updater -- check, update, rollback, local patches,
#              build+deploy, fzf menu, and scheduled update notifications.
#
# 上游没有 Arch 包（官方仓库/archlinuxcn/AUR 都没有），桌面本体只能走上游 GitHub 发布，
# pacman 只负责它的依赖。本脚本把官方 kosctl 的动作收成一条命令，并解决两个真实痛点：
#   1. 本地补丁会让 kosctl update 因脏工作区直接拒绝 —— 这里导出 → 清理 → 切换 → 重打；
#   2. 不带参数的 kosctl update 走 GitHub API 查 Latest，本机易被限流 —— 这里用
#      git ls-remote 自己算最新正式 tag，再显式传给 kosctl，完全绕开 API。

set -euo pipefail

# 以调用名显示用法：软链成 kos 时提示里就是 kos，而不是 update.sh。
PROG=${0##*/}
SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")

# --- 常量 ---
UPSTREAM_URL="${KOS_SRC_URL:-https://github.com/SuceV587/NextKde.git}"
REPO="${KOS_REPO_DIR:-${KOS_SRC_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/kos-src}}"
PREFIX="${KOS_PREFIX:-$HOME/.local}"
RELEASE_RECORD="$PREFIX/share/kos/release.json"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kos"
PATCH_DIR="$STATE_DIR/local-patches"
LOG_DIR="$STATE_DIR/update-logs"
MAIN_CACHE="$STATE_DIR/main-head"
LATEST_CACHE="$STATE_DIR/latest-tag"
ASKPASS="${HOME}/scripts/desktop/fuzzel-askpass"
GSUDO="${HOME}/scripts/desktop/gsudo"
DEFAULT_CHANNEL="${KOS_CHANNEL:-stable}"
# 最新 tag 缓存的存活时间。菜单每次重绘都会读它，避免每敲一次键就打一次网络。
LATEST_TTL=900
MENU_LOCK="$STATE_DIR/menu.lock"
MENU_PIDFILE="$STATE_DIR/menu.pid"
LOCK_FILE="$STATE_DIR/update.lock"
LOCK_FD=-1

ASSUME_YES=0
DRY_RUN=0
START_AFTER=0
NOTIFY=0
QUIET=0
JSON=0
PREVIEW_MODE=0
CACHE_ONLY=0
HOLD=${KOS_HOLD:-0}
LOG_FILE=""

# --- 颜色与符号 ---
# 只在终端上色；被管道/重定向时全部退化为空，保证 管道 grep 与日志可读。
BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; CYAN=$'\033[36m'; NC=$'\033[0m'
fi

usage() {
  printf '用法: %s [命令] [选项]\n\n' "$PROG"
  cat <<'EOF'
命令（不带命令时进入 fzf 菜单）:
  status                  显示已装版本 / 源码检出 / 最新正式版 / 补丁 / 服务状态
  check                   查上游最新正式 tag（git ls-remote，不走 GitHub API）
  update [stable|main|vX.Y.Z]
                          保存补丁 → 切换源码 → 重打补丁 → 构建部署
  rollback                从历史 tag 里选一个重装
  patch list|save|apply|drop
                          本地补丁：列出 / 导出 / 重打 / 丢弃
  build                   不换源码，仅按当前检出重新构建部署
  start                   启动/重启 KOS 服务（kosctl start）
  logs [--all|-f]         查看最近一次更新日志
  notes [tag]             打印某个版本的发布说明（默认最新正式版）

选项:
  -y, --yes               不再逐项确认
  -n, --dry-run           只打印将要执行的命令
      --start             更新后执行 kosctl start
      --notify            用 notify-send 发桌面通知（check/timer 用）
      --all               （logs）输出整份日志
  -f, --follow            （logs）跟随日志
  -q, --quiet             除错误外不输出（配合 --notify 给 timer）
      --json              status/check 输出一条 JSON（给脚本用）
      --hold              退出前停住等按键（桌面启动器用，否则窗口随进程关闭）
  -h, --help              显示本帮助

退出码:
  0  正常 / 已是最新
  10 有新版本可用（check 用，便于调用方判断）
  1  执行失败
  2  参数错误
  127 缺少依赖

菜单里的快捷键:
  Enter 执行选中项 · Esc 退出 · / 过滤
  ?      预览开关          alt-h   本帮助（分页）
  ctrl-o 状态（分页查看）
  ctrl-e 最新发布说明       ctrl-g  最近一次更新日志
  （后三者与 alt-h 都用 less 分页：q 返回菜单）

环境变量:
  KOS_REPO_DIR     源码检出目录（默认 ~/.cache/kos-src）
  KOS_PREFIX       安装前缀（默认 ~/.local）
  KOS_CHANNEL      默认通道（stable）
  KOS_SRC_URL      上游仓库地址
EOF
}

# --- 基础输出 ---
have() { command -v "$1" >/dev/null 2>&1; }

die() {
  local message="$*"
  # 会话中出错：先还原备用屏，错误才能留在用户看得见的主屏上。
  if (( ${SESSION_ALT:-0} )); then
    leave_session
  fi
  printf '%s错误:%s %s\n' "$RED" "$NC" "$message" >&2
  # 备用屏里的动作输出会随屏幕一起消失，这里把日志尾部重打到主屏，
  # 否则“更新失败”时用户当屏看不到任何上下文。
  if [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]]; then
    printf '%s最近日志（%s）%s\n' "$DIM" "$LOG_FILE" "$NC" >&2
    tail -n 12 -- "$LOG_FILE" | sed 's/^/  /' >&2
    printf '完整日志：%s logs --all\n' "$PROG" >&2
  fi
  exit 1
}

# 缺依赖单独用 127：调用方（timer/包装脚本）能区分“环境不齐”和“执行失败”。
die_missing() {
  if (( ${SESSION_ALT:-0} )); then
    leave_session
  fi
  printf '%s错误:%s 缺少依赖：%s\n' "$RED" "$NC" "$*" >&2
  exit 127
}

# 从桌面启动器打开时，kitty 直接跑本脚本，进程一退窗口就关。
# --hold 让所有退出路径（含出错）先停住，用户才看得到结果。
hold_pause() {
  (( HOLD )) || return 0
  is_tty || return 0
  printf '\n%s按任意键关闭窗口…%s' "$DIM" "$NC"
  # 加超时：走人忘关窗口时不要让进程（以及任何锁）一直挂着
  read -r -n 1 -s -t 600 || true
  printf '\n'
  return 0
}

# 参数错误统一退出 2，和执行失败（1）区分开。
die_usage() {
  printf '%s错误:%s %s\n' "$RED" "$NC" "$*" >&2
  printf '用 --help 查看用法\n' >&2
  exit 2
}

warn() { printf '%s!%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
ok() { printf '%s✓%s %s\n' "$GREEN" "$NC" "$*"; }
log() { printf '%s\n' "$*"; }

# 段落标题：终端里独占一行，比满屏边框便宜也更好读。
stage() { printf '\n%s▌%s %s%s%s\n' "$CYAN" "$NC" "$BOLD" "$*" "$NC"; }

rule() {
  # 预览面板里 fzf 通过 FZF_PREVIEW_COLUMNS 给出可用列数（实测已扣掉边框），
  # 再减去我们自己的两格缩进；不能再用猜的宽度，否则下置预览时会顶到右边框。
  local cols width
  if [[ -n "${FZF_PREVIEW_COLUMNS:-}" ]]; then
    width=$(( FZF_PREVIEW_COLUMNS - 2 ))
  else
    cols=$(tput cols 2>/dev/null || printf '80')
    width=$(( cols > 60 ? 52 : cols - 8 ))
  fi
  (( width < 8 )) && width=8
  (( width > 52 )) && width=52
  # 逐字重复而不是 tr 替换：tr 按字节工作，会把 UTF-8 的 ─ 拆坏。
  printf '%s' "$DIM"
  printf '─%.0s' $(seq 1 "$width")
  printf '%s\n' "$NC"
}

# --- 交互会话（备用屏） ---
# 菜单会话全程跑在终端备用屏里：进入即切屏，退出即还原，退出后才在主屏打一行摘要。
# 这样反复打开不会看到上一轮的输出残影，也不污染 shell 的 scrollback。
SESSION_ALT=0

is_tty() { [[ -t 0 && -t 1 ]]; }

set_title() {
  # 只影响窗口标题栏：dock 打开时能直接看出当前版本
  [[ -t 1 ]] || return 0
  printf '\033]0;%s\007' "$*"
}

enter_session() {
  is_tty || return 0
  SESSION_ALT=1
  printf '\033[?1049h\033[H\033[2J'
  # EXIT 钩子由 main 统一装（on_exit），这里只管中断类信号。
  trap 'leave_session; exit 130' INT
  trap 'leave_session; exit 143' TERM
  trap 'leave_session; exit 129' HUP
}

leave_session() {
  (( SESSION_ALT )) || return 0
  SESSION_ALT=0
  trap - INT TERM HUP
  printf '\033[?1049l'
  set_title 'KOS 更新器'
  return 0
}

release_menu_lock() {
  rm -f -- "$MENU_PIDFILE" 2>/dev/null || true
  (( ${MENU_FD:--1} >= 0 )) || return 0
  exec {MENU_FD}>&-
  MENU_FD=-1
}

# 所有退出路径的唯一收尾：还原屏幕 → （hold 时）停住，避免窗口一闪而过。
on_exit() {
  leave_session
  hold_pause
}

# 退出后在主屏留一行“收据”：做了什么、当前什么版本。用户回头还能看到结论。
session_receipt() {
  local inst latest cols wide=0
  inst=$(installed_version)
  cols=$(tput cols 2>/dev/null || printf '80')
  (( cols >= 100 )) && wide=1
  # dev 版的收据也要说 main，而不是拿正式 tag 冒充"可用更新"
  if is_dev_source; then
    local rel=0
    main_behind || rel=$?
    case $rel in
      0) printf '%sKOS 更新器%s · 已装 %s · main 有新提交（%s update main）\n' "$BOLD" "$NC" "$inst" "$PROG" ;;
      1) printf '%sKOS 更新器%s · 已装 %s · main 一致\n' "$BOLD" "$NC" "$inst" ;;
      *) printf '%sKOS 更新器%s · 已装 %s · main 未检查\n' "$BOLD" "$NC" "$inst" ;;
    esac
    return 0
  fi
  if latest=$(latest_tag 0 2>/dev/null); then
    if [[ "$latest" == "v$inst" ]]; then
      if (( wide )); then
        printf '%sKOS 更新器%s · 已装 %s · 已是最新 · 日志在 %s\n' "$BOLD" "$NC" "$inst" "$LOG_DIR"
      else
        printf '%sKOS 更新器%s · 已装 %s · 已是最新 · %s logs 看详情\n' "$BOLD" "$NC" "$inst" "$PROG"
      fi
    else
      printf '%sKOS 更新器%s · 已装 %s · 可用 %s · 运行 %s update\n' \
        "$BOLD" "$NC" "$inst" "$latest" "$PROG"
    fi
  else
    printf '%sKOS 更新器%s · 已装 %s · %s logs 看详情\n' "$BOLD" "$NC" "$inst" "$PROG"
  fi
}

confirm() {
  (( ASSUME_YES )) && return 0
  if [[ ! -t 0 ]]; then
    printf '%s非交互模式不自动确认，确认请加 -y%s\n' "$YELLOW" "$NC" >&2
    return 1
  fi
  local answer
  printf '%s?%s %s [y/N] ' "$YELLOW" "$NC" "$1"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

pause_prompt() {
  [[ -t 0 && -t 1 ]] || return 0
  printf '\n%s按任意键返回菜单…%s' "$DIM" "$NC"
  read -r -n 1 -s || true
  printf '\r%*s\r' 40 ''
}

# --- 状态读取 ---
repo_require() {
  [[ -d "$REPO/.git" ]] || die "找不到 KOS 源码检出：$REPO（先跑一次 ~/arch-kde/install.sh，或设置 KOS_REPO_DIR）"
  [[ -x "$REPO/tools/kosctl" ]] || die "找不到 kosctl：$REPO/tools/kosctl"
}

# main 的 VERSION 带 -dev 后缀（上游约定），永远不会等于正式 tag，
# 直接拿 "v<已装>" 去比会天天误报“有更新”。
is_dev_source() {
  [[ "$(installed_version)" == *-dev ]] && return 0
  [[ "$(source_kind)" == main ]] && return 0
  return 1
}

installed_version() {
  [[ -f "$RELEASE_RECORD" ]] || { printf '未安装'; return 0; }
  # 不用 `| head -n1`：pipefail 下 SIGPIPE 会让赋值语句意外退出
  sed -n '/"version"/{s/.*"version": *"\([^"]*\)".*/\1/p;q;}' "$RELEASE_RECORD"
}

# 完整 revision（40 位）：与上游 sha 比较要用全长，展示时再截断。
installed_revision_full() {
  [[ -f "$RELEASE_RECORD" ]] || return 1
  sed -n '/"revision"/{s/.*"revision": *"\([^"]*\)".*/\1/p;q;}' "$RELEASE_RECORD"
}

# 展示用的 7 位短 sha
installed_revision() {
  local rev
  rev=$(installed_revision_full) || return 1
  printf '%s' "${rev:0:7}"
}

source_version() { head -n1 "$REPO/VERSION" 2>/dev/null || printf '?'; }
source_head() { git -C "$REPO" rev-parse --short HEAD 2>/dev/null || printf '?'; }

# detached 时 @tag 比 "HEAD" 有意义；有分支名就显示分支。
source_kind() {
  local branch tag
  [[ -d "$REPO/.git" ]] || { printf '缺失'; return 0; }
  branch=$(git -C "$REPO" symbolic-ref --short -q HEAD || true)
  if [[ -n "$branch" ]]; then printf '%s' "$branch"; return 0; fi
  tag=$(git -C "$REPO" describe --tags --exact-match 2>/dev/null || true)
  [[ -n "$tag" ]] && printf 'detached @ %s' "$tag" || printf 'detached'
}

# 一行说清源码位置：tag/分支 + 提交 + （分支时才补 VERSION，tag 本身就是版本）。
source_label() {
  local kind head ver
  [[ -d "$REPO/.git" ]] || { printf '缺失（无源码检出）'; return 0; }
  kind=$(source_kind)
  head=$(source_head)
  ver=$(source_version)
  case "$kind" in
    detached\ @*) printf '%s @%s · detached' "${kind#detached @ }" "$head" ;;
    detached)     printf '%s @%s · detached' "$ver" "$head" ;;
    v[0-9]*.[0-9]*.[0-9]*) printf '%s @%s · 本地分支' "$kind" "$head" ;;
    *)            printf '%s @%s · VERSION %s' "$kind" "$head" "$ver" ;;
  esac
}

dirty_files() {
  git -C "$REPO" status --porcelain --untracked-files=normal 2>/dev/null |
    sed -e 's/^...//' -e 's/^"//' -e 's/"$//'
}

untracked_files() {
  git -C "$REPO" status --porcelain --untracked-files=normal 2>/dev/null |
    sed -n 's/^?? //p'
}

# 上游正式 tag 列表。用 ls-remote 而不是 GitHub API：本机 API 会被限流 403，
# 而 ls-remote 走 git 协议，稳定且无需凭据。
# 上游查询可能被墙/弱网：没有超时的 git ls-remote 会一直挂着，
# 没有 tty 时还可能停下来等凭据输入。统一用 timeout + 禁交互。
git_remote() {
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
    timeout "${KOS_GIT_TIMEOUT:-30}" git ls-remote "$@"
}

remote_tags() {
  git_remote --tags --refs "$UPSTREAM_URL" 'refs/tags/v*' 2>/dev/null |
    sed 's#.*refs/tags/##' |
    grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
    sort -V
}

tag_exists() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  git_remote --tags --refs "$UPSTREAM_URL" "refs/tags/$1" 2>/dev/null | grep -q .
}

latest_tag() {
  local refresh=${1:-0} cached="" age=999999
  # 预览面板必须零网络：只用已有缓存，哪怕过期（状态卡会标注“缓存过期未核对”）。
  if (( PREVIEW_MODE || CACHE_ONLY )) && (( refresh == 0 )); then
    [[ -s "$LATEST_CACHE" ]] || return 1
    head -n1 "$LATEST_CACHE"
    return 0
  fi
  if [[ -s "$LATEST_CACHE" ]]; then
    cached=$(head -n1 "$LATEST_CACHE")
    age=$(( $(date +%s) - $(stat -c %Y "$LATEST_CACHE" 2>/dev/null || printf '0') ))
  fi
  if (( refresh == 0 )) && [[ -n "$cached" ]] && (( age < LATEST_TTL )); then
    printf '%s' "$cached"
    return 0
  fi
  local tag attempt
  for attempt in 1 2; do
    tag=$(remote_tags | tail -n1) || true
    [[ -n "$tag" ]] && break
    (( attempt == 1 )) && sleep 2
  done
  [[ -n "$tag" ]] || return 1
  mkdir -p -- "$STATE_DIR"
  printf '%s\n' "$tag" > "$LATEST_CACHE"
  printf '%s' "$tag"
}

# ── 上游 main 追踪（dev 版用）────────────────────────────────
# dev 版装的是一串 main 提交，只比正式 tag 等于瞎了：这里单独记 main HEAD。
upstream_main() {
  local refresh=${1:-0} cache="$MAIN_CACHE" line="" sha="" age=999999 cached_line=""
  if [[ -s "$cache" ]]; then
    cached_line=$(head -n1 "$cache")
    line="$cached_line"
    age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || printf '0') ))
  fi
  # 预览 / 只读模式：只读缓存（过期也照读），绝不联网、绝不写盘
  if (( PREVIEW_MODE || CACHE_ONLY )); then
    [[ -n "$line" ]] || return 1
    printf '%s' "$line"
    return 0
  fi
  if [[ -n "$line" ]] && (( refresh == 0 )) && (( age < LATEST_TTL )); then
    printf '%s' "$line"
    return 0
  fi
  line=""
  # 有源码检出就 fetch 一次（顺带拿到提交日期与标题）；没有就退化成 ls-remote。
  if [[ -d "$REPO/.git" ]] && GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
      timeout "${KOS_GIT_TIMEOUT:-30}" git -C "$REPO" fetch -q --depth 1 --no-tags origin main 2>/dev/null; then
    line=$(git -C "$REPO" log -1 --format='%H|%cs|%s' FETCH_HEAD 2>/dev/null || true)
  fi
  if [[ -z "$line" ]]; then
    sha=$(git_remote "$UPSTREAM_URL" refs/heads/main 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$sha" ]]; then line="$sha||"; fi
  fi
  if [[ -z "$line" ]]; then
    # 强制刷新（check/timer）失败时绝不用旧缓存冒充结果，交由调用方报"无法判断"
    if (( refresh == 1 )); then return 1; fi
    [[ -n "$cached_line" ]] || return 1
    printf '%s' "$cached_line"
    return 0
  fi
  mkdir -p -- "$STATE_DIR"
  printf '%s\n' "$line" > "$cache"
  printf '%s' "$line"
}

# main 缓存的新鲜度（秒）；-1 表示没有缓存
# 秒数 → 人类可读（供 main_line 复用，避免和 latest_cache_age 两套措辞）
latest_cache_age_text() {
  local age=${1:--1}
  if (( age < 0 )); then printf '从未'; return 0; fi
  if (( age < 120 )); then printf '刚刚'
  elif (( age < 3600 )); then printf '%d 分钟前' $(( age / 60 ))
  elif (( age < 86400 )); then printf '%d 小时前' $(( age / 3600 ))
  else printf '%d 天前' $(( age / 86400 )); fi
}

main_cache_age() {
  [[ -s "$MAIN_CACHE" ]] || { printf '%s' -1; return 0; }
  printf '%s' $(( $(date +%s) - $(stat -c %Y "$MAIN_CACHE" 2>/dev/null || printf '0') ))
}

# 部署的 revision 与上游 main 的关系：0=有新提交 1=一致 2=未知
main_behind() {
  local up deployed
  up=$(upstream_main 0 2>/dev/null) || return 2
  deployed=$(installed_revision_full 2>/dev/null || true)
  [[ -n "$deployed" ]] || return 2
  [[ "${up%%|*}" == "$deployed"* ]] && return 1
  return 0
}

cache_age_secs() {
  [[ -s "$LATEST_CACHE" ]] || { printf '%s' -1; return 0; }
  printf '%s' $(( $(date +%s) - $(stat -c %Y "$LATEST_CACHE" 2>/dev/null || printf '0') ))
}

latest_cache_age() {
  [[ -s "$LATEST_CACHE" ]] || { printf '从未'; return 0; }
  local age; age=$(cache_age_secs)
  if (( age < 120 )); then printf '刚刚'
  elif (( age < 3600 )); then printf '%d 分钟前' $(( age / 60 ))
  else printf '%d 小时前' $(( age / 3600 )); fi
}

apps_installed() {
  local f
  for f in "$HOME"/.local/share/applications/kos-calendar.desktop \
           "$HOME"/.local/share/applications/kos-calculator.desktop; do
    [[ -f "$f" ]] && return 0
  done
  return 1
}

lockscreen_installed() {
  local dir
  for dir in "$HOME/.local/share/plasma/shells" "$HOME/.local/share/plasma/look-and-feel"; do
    [[ -d "$dir/org.kos.desktop" ]] && return 0
  done
  return 1
}

services_state() {
  local unit state out=""
  for unit in kos-platform.service kos-data.service kos-shell.service; do
    if ! have systemctl; then printf '未知'; return 0; fi
    state=$(systemctl --user is-active "$unit" 2>/dev/null || true)
    case "$state" in
      active) out+="✓ ${unit%.service} " ;;
      "") out+="· ${unit%.service} " ;;
      *) out+="× ${unit%.service}($state) " ;;
    esac
  done
  printf '%s' "$out"
}

# --- 补丁 ---
patch_list() {
  local -a files=()
  shopt -s nullglob
  files=("$PATCH_DIR"/*.patch)
  shopt -u nullglob
  (( ${#files[@]} )) && printf '%s\n' "${files[@]}"
}

save_patch() {
  local diff rev stamp file
  # HEAD 为基准：已暂存和未暂存都要导出，否则暂存内容会被 checkout 留在树上。
  diff=$(git -C "$REPO" diff HEAD --binary) || return 1
  if [[ -z "$diff" ]]; then
    log '无未提交改动，无需导出补丁'
    return 0
  fi
  if (( DRY_RUN )); then
    log "[dry-run] 会导出 $(printf '%s\n' "$diff" | grep -c '^diff --git') 个文件的补丁到 $PATCH_DIR"
    return 0
  fi
  rev=$(source_head)
  stamp=$(date +%Y%m%dT%H%M%S)
  mkdir -p -- "$PATCH_DIR"
  file="$PATCH_DIR/kos-local-$rev-$stamp.patch"
  # 头部写清"这个补丁是在哪条通道、哪个提交上导出的"：
  # 之后切到别的版本时就能判断它是否还适用，而不是盲打。
  {
    printf '# kos-source: %s@%s\n' "$(source_kind)" "$rev"
    printf '# kos-exported: %s\n' "$stamp"
    printf '%s\n' "$diff"
  } > "$file"
  ok "已导出本地补丁：$file（$(printf '%s\n' "$diff" | grep -c '^diff --git') 个文件，基线 $(source_kind)@$rev）"
}

apply_patches() {
  local -a files=()
  # 按导出时间应用（文件名里的 rev 字典序不等于时间序）
  mapfile -t files < <(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' -printf '%T@ %p\n' 2>/dev/null |
    sort -n | cut -d' ' -f2-)
  if (( ${#files[@]} == 0 )); then
    log '没有待应用的本地补丁'
    return 0
  fi
  local p name failed=0 base="" base_rev="" cur_rev=""
  cur_rev=$(source_head)
  for p in "${files[@]}"; do
    name=$(basename -- "$p")
    base=$(sed -n '1s/^# kos-source: *//p' "$p" 2>/dev/null || true)
    if [[ -n "$base" && "$base" != *"@$cur_rev" ]]; then
      base_rev=${base##*@}
      warn "跳过补丁 $name：它是在 ${base%@*}@$base_rev 上导出的，当前源码是 $(source_kind)@$cur_rev"
      printf '  确认仍然适用可手工：git -C %s apply --3way %s\n' "$REPO" "$p" >&2
      failed=1
      break
    fi
    if git -C "$REPO" apply --check --reverse "$p" >/dev/null 2>&1; then
      log "补丁已在位：$name"
      continue
    fi
    if (( DRY_RUN )); then
      log "[dry-run] 会应用补丁：$name"
      continue
    fi
    if git -C "$REPO" apply --check "$p" >/dev/null 2>&1; then
      git -C "$REPO" apply "$p"
      ok "已应用补丁：$name"
      continue
    fi
    # 直接 apply 不行时试 3-way（浅克隆可能没有 base blob，失败就当作冲突）。
    if git -C "$REPO" apply --3way --check "$p" >/dev/null 2>&1; then
      git -C "$REPO" apply --3way "$p"
      ok "已 3-way 应用补丁：$name"
      continue
    fi
    # 绝不 --reject：那会把能应用的 hunk 写进工作区，留下半补丁树。
    warn "补丁冲突：$name（未做任何修改）"
    printf '  该补丁与当前源码不兼容。可先 %s patch drop 放弃它，或手工 git apply --3way 适配。\n' "$PROG" >&2
    failed=1
    break
  done
  (( failed == 0 )) || {
    # .rej 留在工作区会变成未跟踪文件，下一次更新会被守卫直接挡下，
    # 所以统一挪到状态目录，工作区保持干净。
    local reject_dir
    reject_dir="$PATCH_DIR/rejects/$(date +%Y%m%dT%H%M%S)"
    mkdir -p -- "$reject_dir"
    # 保留相对路径，避免不同目录的同名 .rej 互相覆盖
    local rel
    while IFS= read -r rel; do
      mkdir -p -- "$reject_dir/$(dirname -- "$rel")"
      mv -- "$REPO/$rel" "$reject_dir/$rel"
    done < <(cd "$REPO" && find . -name '*.rej' -printf '%P\n' 2>/dev/null)
    printf '%s补丁冲突（拒绝块已移到 %s）%s\n' "$RED" "$reject_dir" "$NC" >&2
    return 1
  }
}

# build/update 成功后把已应用的补丁归档，避免下次再把同样的补丁打一遍。
archive_applied_patches() {
  local -a files=()
  mapfile -t files < <(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' 2>/dev/null)
  (( ${#files[@]} )) || return 0
  local dest
  dest="$PATCH_DIR/archive/$(date +%Y%m%dT%H%M%S)"
  mkdir -p -- "$dest"
  local p
  for p in "${files[@]}"; do
    mv -- "$p" "$dest/"
  done
  printf '%s  已把 %d 个本地补丁移入 %s（下次更新不会重复应用）%s\n' \
    "$DIM" "${#files[@]}" "$dest" "$NC"
}

# --- 提权 ---
# kosctl 会把 KWin 插件装进 /usr，并在缺依赖时自己调 sudo。这里先提权把时间戳刷热，
# 同时导出 SUDO_ASKPASS，让 kosctl 内部那些没有 tty 的 sudo 也能弹 fuzzel 框。
preauth() {
  if (( DRY_RUN )); then
    log '[dry-run] 构建前会经 gsudo 提权（安装 KWin 插件到 /usr）'
    return 0
  fi
  export SUDO_ASKPASS="$ASKPASS"
  if sudo -n true >/dev/null 2>&1; then
    log '已有 sudo 时间戳，跳过提权'
    return 0
  fi
  [[ -x "$ASKPASS" ]] || die "缺少 askpass 助手：$ASKPASS"
  [[ -x "$GSUDO" ]] || die "缺少 gsudo：$GSUDO"
  log '构建需要提权（安装 KWin 插件到 /usr），将弹出密码框'
  "$GSUDO" || die '提权被取消'
}

# --- kosctl 调用（同时落日志） ---
kosctl_exec() {
  local -a cmd=("$REPO/tools/kosctl" "$@")
  printf '%s→%s %s\n' "$DIM" "$NC" "${cmd[*]}"
  (( DRY_RUN )) && return 0
  local start=$SECONDS status=0
  if [[ -n "$LOG_FILE" ]]; then
    set +e
    "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
    status=${PIPESTATUS[0]}
    set -e
  else
    set +e
    "${cmd[@]}"
    status=$?
    set -e
  fi
  if (( status == 0 )); then
    printf '%s  ↳ 完成（%ds）%s\n' "$DIM" "$(( SECONDS - start ))" "$NC"
  else
    printf '%s  ↳ 失败（%ds，退出码 %d）%s\n' "$RED" "$(( SECONDS - start ))" "$status" "$NC"
  fi
  return "$status"
}

# --- 日志与锁 ---
start_log() {
  [[ -n "$1" ]] || return 0
  (( DRY_RUN )) && return 0
  mkdir -p -- "$LOG_DIR"
  LOG_FILE="$LOG_DIR/$1-$(date +%Y%m%dT%H%M%S).log"
  { printf '# %s\n' "$(date -Is)"; printf '# 仓库 %s\n' "$REPO"; } >> "$LOG_FILE"
}

# 文件名由本脚本生成，但仍用 find 排序，避免 ls 解析带空格的路径。
latest_log_file() {
  [[ -d "$LOG_DIR" ]] || return 1
  find "$LOG_DIR" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | head -n1 | cut -d' ' -f2-
}

acquire_lock() {
  have flock || die_missing 'flock（util-linux）'
  mkdir -p -- "$STATE_DIR"
  # 同一会话里第二次操作也要能拿锁：fd 只开一次，用完 release_lock 关掉。
  if (( LOCK_FD < 0 )); then
    exec {LOCK_FD}>>"$LOCK_FILE"
  fi
  flock -n "$LOCK_FD" || die '另一个更新正在运行（或残留锁）'
}

release_lock() {
  (( LOCK_FD >= 0 )) || return 0
  exec {LOCK_FD}>&-
  LOCK_FD=-1
}

# --- 渲染：状态卡 ---
render_status() {
  local inst latest installed_rev patch_note
  inst=$(installed_version)
  installed_rev=$(installed_revision || true)
  patch_note='无未提交改动'
  local -a dirty=()
  mapfile -t dirty < <(dirty_files)
  if (( ${#dirty[@]} > 0 )); then
    patch_note="${#dirty[@]} 处未提交"
  fi

  printf '%sKOS 桌面 · 状态%s\n' "$BOLD" "$NC"
  rule
  printf '  已装     %s%s%s %s\n' "$BOLD" "$inst" "$NC" "${installed_rev:+($installed_rev)}"
  printf '  源码     %s\n' "$(source_label)"
  local age age_txt
  # 先取年龄再读 tag：latest_tag 可能在缓存过期时刷新，之后 age 就不代表原来的缓存了。
  age=$(cache_age_secs)
  age_txt=$(latest_cache_age)
  if latest=$(latest_tag 0 2>/dev/null); then
    if (( age >= 0 && age > LATEST_TTL )); then
      printf '  最新     %s（缓存 %s，已过期）%s未核对，跑 check%s\n' \
        "$latest" "$age_txt" "$DIM" "$NC"
    elif is_dev_source; then
      printf '  最新     %s（%s核对）  %s当前 main 开发版，不参与 tag 比较%s\n' \
        "$latest" "$age_txt" "$DIM" "$NC"
    elif [[ "$latest" == "v$inst" ]]; then
      printf '  最新     %s（%s核对）  %s已是最新%s\n' "$latest" "$age_txt" "$GREEN" "$NC"
    else
      printf '  最新     %s（%s核对）  %s有更新%s\n' "$latest" "$age_txt" "$YELLOW" "$NC"
    fi
  else
    printf '  最新     %s从未核对（离线或缓存为空），跑 %s check%s\n' "$DIM" "$PROG" "$NC"
  fi
  printf '  main     %s\n' "$(main_line)"
  printf '  补丁     %s\n' "$patch_note"
  if (( ${#dirty[@]} > 0 )); then
    printf '           %s\n' "${dirty[0]}"
    (( ${#dirty[@]} > 1 )) && printf '           %s…\n' "$(( ${#dirty[@]} - 1 )) 个其余文件"
  fi
  printf '  应用     %s\n' "$(apps_installed && printf '已装（日历/计算器/待办/天气）' || printf '未装')"
  printf '  锁屏     %s\n' "$(lockscreen_installed && printf '已装（org.kos.desktop）' || printf '未装')"
  printf '  服务     %s\n' "$(services_state)"
  printf '  上次     %s\n' "$(last_log_summary)"
  printf '  上游     %s\n' "$(upstream_display)"
  [[ -n "$LOG_FILE" ]] && printf '  日志     %s\n' "$LOG_FILE"
  return 0
}

# 状态卡里的一行 main 状态：上游 HEAD vs 已部署 revision。
main_line() {
  local up sha date deployed age stale=0
  if ! up=$(upstream_main 0 2>/dev/null); then
    printf '%s未检查（跑 %s check）%s' "$DIM" "$PROG" "$NC"
    return 0
  fi
  IFS='|' read -r sha date _ <<< "$up"
  deployed=$(installed_revision 2>/dev/null || true)
  age=$(main_cache_age)
  (( age > LATEST_TTL )) && stale=1
  if (( stale )); then
    printf '%s上游 %s（%s，缓存 %s 已过期）未核对，跑 %s check%s' \
      "$DIM" "${sha:0:7}" "${date:-?}" "$(latest_cache_age_text "$age")" "$PROG" "$NC"
    return 0
  fi
  if [[ -z "$deployed" ]]; then
    printf '上游 %s（%s）' "${sha:0:7}" "${date:-?}"
    return 0
  fi
  if [[ "$sha" == "$deployed"* ]]; then
    printf '上游 %s（%s）· 已部署一致' "${sha:0:7}" "${date:-?}"
  else
    printf '上游 %s（%s）· 已部署 %s  %s有新提交，重建：%s update main%s' \
      "${sha:0:7}" "${date:-?}" "$deployed" "$YELLOW" "$PROG" "$NC"
  fi
}

# 上游地址去 scheme、超长截断，避免状态卡被一行撑爆。
upstream_display() {
  local url=${UPSTREAM_URL#*://}
  url=${url%.git}
  (( ${#url} > 46 )) && url="${url:0:43}…"
  printf '%s' "$url"
}

# 上次更新动作的“多久以前 + 通道”，取自日志文件名与 mtime。
last_log_summary() {
  local f age when channel
  f=$(latest_log_file || true)
  if [[ -z "$f" ]]; then
    if [[ -f "$RELEASE_RECORD" ]]; then
      printf '无更新记录（安装于 %s）' "$(date -d "@$(stat -c %Y "$RELEASE_RECORD")" '+%m-%d')"
    else
      printf '无更新记录'
    fi
    return 0
  fi
  age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || printf '0') ))
  if (( age < 120 )); then when='刚刚'
  elif (( age < 3600 )); then when="$(( age / 60 )) 分钟前"
  elif (( age < 86400 )); then when="$(( age / 3600 )) 小时前"
  else when=$(date -d "@$(stat -c %Y "$f")" '+%m-%d %H:%M'); fi
  channel=$(basename -- "$f" .log | sed -E 's/-[0-9]{8}T[0-9]{6}$//; s/^update-//')
  printf '%s（%s）' "$when" "$channel"
}

render_summary() {
  local inst
  inst=$(installed_version)
  printf '\n'
  ok "已装版本：$inst（源码 $(source_label)）"
  printf '%s下一步：注销并重新登录，KWin 特效与锁屏才会换成新版本。%s\n' "$DIM" "$NC"
  printf '%s回退：%s rollback%s\n' "$DIM" "$PROG" "$NC"
}

# --- 渲染：检查结果 ---
render_check() {
  local latest inst
  inst=$(installed_version)
  # dev 版跑的是 main 的某个提交，先比 main HEAD（这才是"有没有新功能"）。
  if is_dev_source; then
    render_check_dev "$inst"
    return $?
  fi
  (( QUIET )) || printf '%s查询上游正式 tag（git ls-remote）…%s\n' "$DIM" "$NC"
  if ! latest=$(latest_tag 1); then
    if (( NOTIFY )); then
      warn '取不到上游最新 tag（离线或上游不可达），本次跳过'
      return 0
    fi
    die "取上游最新 tag 失败（离线或上游不可达）。检查网络后可重试：git ls-remote --tags $UPSTREAM_URL"
  fi
  if is_dev_source; then
    (( QUIET )) || printf '%s✓%s 已是最新正式版 %s；当前源码是 main 开发版（%s），不参与 tag 比较\n' \
      "$GREEN" "$NC" "$latest" "$inst"
    return 0
  fi
  if [[ "$latest" == "v$inst" ]]; then
    (( QUIET )) || { printf '%s%s%s %s已是最新正式版（%s）%s\n' "$GREEN" '✓' "$NC" "$DIM" "$latest" "$NC"; }
    return 0
  fi
  (( QUIET )) || {
    printf '%s↑%s 有新版本：%s → %s%s\n' "$YELLOW" "$NC" "$inst" "$BOLD$latest$NC" ''
    printf '%s  %s update   即可更新（会自动保存并重打本地补丁）%s\n' "$DIM" "$PROG" "$NC"
  }
  if (( NOTIFY )); then
    printf '有新版本可用：%s -> %s（%s update）\n' "$inst" "$latest" "$PROG"
    notify_update "$inst" "$latest"
  fi
  return 10
}

# 开发版不跟 tag 比，但正式版发了仍值得提醒一次（同一个 tag 只提一次）。
# dev 版专用：main 有新提交才提示重建；正式 tag 只是附带信息。
render_check_dev() {
  local inst=$1 up deployed relation sha date subj
  (( QUIET )) || printf '%s检查上游 main…%s\n' "$DIM" "$NC"
  deployed=$(installed_revision_full 2>/dev/null || true)
  if ! up=$(upstream_main 1); then
    if (( NOTIFY )); then warn '取不到上游 main（离线或上游不可达），本次跳过'; return 0; fi
    die "取不到上游 main（离线或上游不可达）。重试：git ls-remote $UPSTREAM_URL refs/heads/main"
  fi
  IFS='|' read -r sha date subj <<< "$up"
  relation=0
  main_behind || relation=$?
  case "$relation" in
    0)
      (( QUIET )) || {
        printf '%s↑%s main 有新提交：已部署 %s → 上游 %s（%s）\n' \
          "$YELLOW" "$NC" "${deployed:0:7}" "${sha:0:7}" "${date:-?}"
        [[ -n "$subj" ]] && printf '%s  %s%s\n' "$DIM" "$subj" "$NC"
        printf '%s  重建即可获得新功能：%s update main%s\n' "$DIM" "$PROG" "$NC"
      }
      if (( NOTIFY )); then
        printf 'main 有新提交：%s -> %s（%s update main）\n' "${deployed:0:7}" "${sha:0:7}" "$PROG"
        notify_dev_main "$inst" "${sha:0:7}" "${subj:-}"
      fi
      return 10 ;;
    1)
      (( QUIET )) || printf '%s✓%s main 无新提交（已部署 %s，与上游一致）\n' "$GREEN" "$NC" "${deployed:0:7}"
      return 0 ;;
    *)
      (( QUIET )) || printf '%s?%s 无法判断 main 状态（release.json 缺 revision）\n' "$YELLOW" "$NC"
      return 1 ;;
  esac
}

notify_dev_main() {
  local inst=$1 sha=$2 subj=$3 marker="$STATE_DIR/last-notified-main"
  [[ -s "$marker" && "$(head -n1 "$marker")" == "$sha" ]] && return 0
  have notify-send || return 0
  if notify-send --app-name='KOS 更新' --icon=system-software-update \
      --hint=string:x-canonical-private-synchronous:kos-update \
      "KOS main 有新提交 $sha" "已部署 $inst。重建获取新功能：kos update main${subj:+（$subj）}"; then
    mkdir -p -- "$STATE_DIR"
    printf '%s\n' "$sha" > "$marker"
  fi
}

notify_update() {
  local inst=$1 latest=$2 marker="$STATE_DIR/last-notified-tag"
  # 已经为这个 tag 提醒过就不再打扰；用户升级后自然不再进入这个分支。
  [[ -s "$marker" && "$(head -n1 "$marker")" == "$latest" ]] && return 0
  have notify-send || return 0
  notify-send --app-name='KOS 更新' --icon=system-software-update \
    --hint=string:x-canonical-private-synchronous:kos-update \
    "KOS 桌面有新版本 $latest" \
    "已装 $inst。终端执行 kos update 更新（会保留本地补丁）。" || true
  mkdir -p -- "$STATE_DIR"
  printf '%s\n' "$latest" > "$marker"
}

# --- 菜单 ---
build_menu() {
  printf '%s\t%s\n' \
    update   '↑ 更新到最新正式版' \
    check    '⟳ 检查更新' \
    status   '● 状态与版本' \
    main     '⇡ 拉取 main 最新并重建' \
    rollback '↩ 回退到历史版本' \
    patch    '✎ 本地补丁' \
    build    '⚙ 重新构建部署' \
    start    '▶ 启动 KOS 服务' \
    logs     '≡ 更新日志'
}

# 左列只放动作：不堆说明就不会在窄屏被截断，细节全交给右侧预览。
# 菜单顶部那句状态：被 __header 复用（方便测试），不要直接内联到 printf。
menu_state_word() {
  local inst latest rel=0
  inst=$(installed_version)
  if is_dev_source; then
    local age
    age=$(main_cache_age)
    if (( age < 0 || age > LATEST_TTL )); then
      printf '%s' "${DIM}main 未核对${NC}"
      return 0
    fi
    main_behind || rel=$?
    case $rel in
      0) printf '%s' "${YELLOW}main 有新提交${NC}" ;;
      1) printf '%s' "${GREEN}main 一致${NC}" ;;
      *) printf '%s' "${DIM}main 未核对${NC}" ;;
    esac
    return 0
  fi
  if latest=$(latest_tag 0 2>/dev/null); then
    if [[ "$latest" == "v$inst" ]]; then
      printf '%s' "${GREEN}已是最新${NC}"
    else
      printf '%s' "${YELLOW}可更新 $latest${NC}"
    fi
  else
    printf '%s' "${DIM}未检查${NC}"
  fi
}

menu_header() {
  local inst state patch_n
  inst=$(installed_version)
  state=$(menu_state_word)
  local -a dirty=()
  mapfile -t dirty < <(dirty_files)
  if (( ${#dirty[@]} > 0 )); then patch_n="${#dirty[@]} 处未提交"; else patch_n="无"; fi
  local cols pane hint
  cols=$(tput cols 2>/dev/null || printf '80')
  if (( cols >= 100 )); then pane=$(( cols * 42 / 100 )); else pane=$(( cols - 2 )); fi
  # 真实的显示宽度（CJK 按 2 计）：full=39 / mid=22 / short=10。
  # 阈值留 2 格余量，避免 fzf 在 pane 边缘截成 “alt··”。
  if (( pane >= 41 )); then
    hint='Esc 退出 · / 过滤 · ? 预览 · alt-h 帮助'
  elif (( pane >= 24 )); then
    hint='Esc 退出 · alt-h 帮助'
  else
    hint='alt-h 帮助'
  fi
  printf '%s已装%s %s · %s\n%s源码%s %s · %s补丁%s %s\n%s%s%s\n' \
    "$DIM" "$NC" "$BOLD$inst$NC" "$state" \
    "$DIM" "$NC" "$(source_kind)" \
    "$DIM" "$NC" "$patch_n" \
    "$DIM" "$hint" "$NC"
}

cmd_menu() {
  have fzf || die_missing 'fzf（sudo pacman -S fzf）'
  is_tty || die "菜单需要交互终端；非交互请用子命令，例如：$PROG status / $PROG check / $PROG update"
  # 不在这里 die：status/check/logs/start 不依赖源码检出，菜单要能用；
  # 依赖源码的条目在选中时给出修复办法。
  local have_repo=1
  [[ -d "$REPO/.git" && -x "$REPO/tools/kosctl" ]] || have_repo=0
  local selection key cols preview_window
  cols=$(tput cols 2>/dev/null || printf '80')
  # 窄终端把预览从右侧改为下方，否则左列会被挤到只剩图标。
  if (( cols >= 100 )); then
    preview_window='right,58%,border-left,wrap'
  else
    preview_window='down,45%,border-top,wrap'
  fi
  # 同一时间只允许一个菜单会话：重复点启动器时不要开出两个互相不知道的窗口。
  mkdir -p -- "$STATE_DIR"
  exec {MENU_FD}>>"$MENU_LOCK"
  if ! flock -n "$MENU_FD"; then
    # 上一个会话可能被 kill -9（子进程还继承着锁 fd）：用 pidfile 判活并接管
    if [[ -s "$MENU_PIDFILE" ]]; then
      local old_pid
      old_pid=$(head -n1 "$MENU_PIDFILE")
      if [[ "$old_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$old_pid" 2>/dev/null; then
        rm -f -- "$MENU_PIDFILE"
        exec {MENU_FD}>&-
        exec {MENU_FD}>>"$MENU_LOCK"
        if flock -n "$MENU_FD"; then
          printf '%s接管了上一个已退出的会话遗留的锁%s\n' "$DIM" "$NC"
        fi
      fi
    fi
  fi
  if ! flock -n "$MENU_FD"; then
    printf '%s已有一个更新窗口在运行%s，请切到那个窗口继续（Esc 退出）。\n' "$YELLOW" "$NC"
    printf '%s如果确认没有窗口，删掉 %s 后重试。%s\n' "$DIM" "$MENU_LOCK" "$NC"
    # 窗口会立刻关掉，用一条通知让用户知道"为什么没反应"
    have notify-send && notify-send --app-name='KOS 更新' --icon=system-software-update \
      --hint=string:x-canonical-private-synchronous:kos-update \
      'KOS 更新：已有一个窗口在运行' '请切到那个更新窗口（Esc 退出）' || true
    HOLD=0   # 这一条不需要停住：窗口会立刻关掉，避免又多一个空窗口
    return 0
  fi
  printf '%s\n' "$$" > "$MENU_PIDFILE"
  enter_session
  set_title "KOS 更新 · $(installed_version) · $(source_kind)"
  while true; do
    set +e
    selection=$(
      build_menu |
        fzf --ansi --height=100% --border=rounded --border-label=' KOS 桌面更新 ' \
          --layout=reverse --info=inline-right --pointer='▸' --marker='✓' \
          --prompt='操作 ▸ ' --header="$(menu_header)" --header-first \
          --delimiter=$'\t' --with-nth=2 \
          --preview="$SCRIPT_PATH __preview {1}" \
          --preview-window="$preview_window" --no-scrollbar \
          --bind="?:toggle-preview" \
          --bind="alt-h:execute($SCRIPT_PATH help | less -R)" \
          --bind="ctrl-e:execute($SCRIPT_PATH notes | less -R)" \
          --bind="ctrl-g:execute($SCRIPT_PATH logs --all | less -R)" \
          --bind="ctrl-o:execute($SCRIPT_PATH status | less -R)"
    )
    local status=$?
    set -e
    case "$status" in
      0) ;;
      1|130) break ;;
      *) die "fzf 失败（退出码 $status）" ;;
    esac
    [[ -n "$selection" ]] || break
    key=${selection%%$'\t'*}
    local action_rc=0
    local action_rc=0
    case "$key" in
      update|main|rollback|patch|build)
        if (( ! have_repo )); then
          warn "缺少源码检出：$REPO"
          printf '  修复：跑一次 ~/arch-kde/install.sh，或设置 KOS_REPO_DIR 指向已有检出\n'
          pause_prompt
          continue
        fi ;;
    esac
    case "$key" in
      status)   cmd_status ;;
      check)    cmd_check ;;
      update)   cmd_update "$DEFAULT_CHANNEL" ;;
      main)     cmd_update main ;;
      rollback) cmd_rollback ;;
      patch)    cmd_patch_menu ;;
      build)    cmd_build ;;
      start)    cmd_start ;;
      logs)     cmd_logs ;;
      *)        warn "未知动作：$key" ;;
    # 不能写 `case ... esac || true`：被 || 包裹后函数内 errexit 全失效，
    # save_patch/checkout 失败会被静默吞掉（菜单与 CLI 语义分裂）。
    esac || action_rc=$?
    (( action_rc == 0 )) || warn "动作未成功完成（退出码 $action_rc）"
    pause_prompt
  done
  release_menu_lock
  leave_session
  session_receipt
}

# 预览面板：只读本地状态与缓存，绝不在这里发起网络请求（菜单每次移动都会重绘）。
cmd_preview() {
  local key=${1:-status}
  # 菜单每次移动都会重绘预览：这里禁止任何网络请求与写盘，只用本地缓存。
  PREVIEW_MODE=1
  case "$key" in
    status)
      render_status
      ;;
    check)
      printf '%s用 git ls-remote 查最新正式 tag，不走 GitHub API%s\n\n' "$DIM" "$NC"
      printf '  上游      %s\n' "$UPSTREAM_URL"
      printf '  方式      git ls-remote（避开 GitHub API 限流）\n'
      printf '  缓存      %s（%s，TTL %d 秒）\n' "$LATEST_CACHE" "$(latest_cache_age)" "$LATEST_TTL"
      printf '  最近 tag  %s\n' "$(latest_tag 0 2>/dev/null || printf '未缓存')"
      ;;
    update|main)
      local tag
      if [[ "$key" == update ]]; then tag=$(latest_tag 0 2>/dev/null || true); else tag=main; fi
      printf '%s保存补丁 → 切换源码 → 重打补丁 → 构建部署%s\n\n' "$DIM" "$NC"
      if [[ "$key" == main ]]; then
        printf '%smain%s %s\n\n' "$BOLD" "$NC" "$(main_line)"
      fi
      printf '%s目标%s %s\n\n' "$BOLD" "$NC" "${tag:-未知}"
      local -a dirty=()
      mapfile -t dirty < <(dirty_files)
      if (( ${#dirty[@]} > 0 )); then
        printf '%s本地改动（会先导出为补丁，更新后重打）%s\n' "$BOLD" "$NC"
        printf '  %s\n' "${dirty[@]}"
        printf '\n'
      fi
      local p
      if p=$(patch_list); then
        printf '%s补丁库%s\n' "$BOLD" "$NC"
        printf '  %s\n' "$p"
        printf '\n'
      fi
      local notes
      notes=$(release_notes "$tag" 2>/dev/null || true)
      if [[ -n "$notes" ]]; then
        local total
        total=$(printf '%s\n' "$notes" | wc -l)
        printf '%s更新说明%s\n\n' "$BOLD" "$NC"
        printf '%s\n' "$notes" | head -n 40
        if (( total > 40 )); then
          printf '%s…（共 %d 行，按 ctrl-e 看全文）%s\n' "$DIM" "$total" "$NC"
        fi
      else
        printf '%s（该版本没有随源码发布的说明文档）%s\n' "$DIM" "$NC"
      fi
      ;;
    rollback)
      printf '%s从历史 tag 里选一个重装，本地补丁保留%s\n\n' "$DIM" "$NC"
      remote_tags 2>/dev/null | tail -n 15 | sed 's/^/  /' || printf '  取 tag 失败\n'
      ;;
    patch)
      printf '%s升级会自动重打补丁库；这里可手动导出、重打或丢弃%s\n\n' "$DIM" "$NC"
      local p
      if p=$(patch_list); then
        printf '%s补丁库%s\n\n' "$BOLD" "$NC"
        printf '%s\n' "$p"
        printf '\n%s各补丁改动文件%s\n' "$BOLD" "$NC"
        local f
        while IFS= read -r f; do
          printf '  %s\n    %s\n' "$(basename -- "$f")" \
            "$(grep -c '^diff --git' "$f" 2>/dev/null || printf '?') 个文件"
        done <<< "$p"
      else
        printf '%s补丁库为空：%s\n\n' "$DIM" "$NC"
      fi
      local -a dirty=()
      mapfile -t dirty < <(dirty_files)
      if (( ${#dirty[@]} > 0 )); then
        printf '%s当前未提交改动%s\n  %s\n' "$BOLD" "$NC" "${dirty[*]}"
      fi
      ;;
    build)
      printf '%s不换源码，仅按当前检出重新构建部署%s\n\n' "$DIM" "$NC"
      printf '%s当前检出%s\n\n' "$BOLD" "$NC"
      printf '  位置   %s\n' "$(source_label)"
      printf '  仓库   %s\n' "$REPO"
      if [[ -n "$LOG_FILE" ]]; then printf '  日志   %s\n' "$LOG_FILE"; fi
      ;;
    start)
      printf '%s重启 KOS 用户服务，不需要注销%s\n\n' "$DIM" "$NC"
      printf '%s用户服务%s\n\n' "$BOLD" "$NC"
      have systemctl && systemctl --user list-units 'kos-*' --all --no-legend 2>/dev/null |
        sed 's/^/  /' || printf '  systemctl 不可用\n'
      ;;
    logs)
      printf '%s最近一次更新日志（尾部 30 行）%s\n\n' "$DIM" "$NC"
      local latest_log
      latest_log=$(latest_log_file || true)
      if [[ -n "$latest_log" ]]; then
        printf '%s%s%s\n\n' "$DIM" "$latest_log" "$NC"
        tail -n 30 "$latest_log"
      else
        printf '%s还没有更新日志%s\n' "$DIM" "$NC"
      fi
      ;;
    *)
      printf '无预览\n'
      ;;
  esac
}

# 更新说明：vX.Y.Z 的中文发布说明（随源码放在 docs/releases/）。
release_notes() {
  local tag=$1 cache="$STATE_DIR/releases/$1.zh-CN.md"
  [[ -n "$tag" && "$tag" != main ]] || return 1
  # 预览只读缓存：抓取动作留给 notes/ctrl-e，避免菜单卡顿和隐式副作用。
  if (( PREVIEW_MODE )); then
    [[ -s "$cache" ]] && { strip_markdown < "$cache"; return 0; }
    return 1
  fi
  if [[ -s "$cache" ]]; then strip_markdown < "$cache"; return 0; fi
  mkdir -p -- "$(dirname -- "$cache")"
  if curl -fsSL --max-time 8 \
      "https://raw.githubusercontent.com/SuceV587/NextKde/$tag/docs/releases/$tag.zh-CN.md" \
      -o "$cache.tmp" 2>/dev/null; then
    mv -- "$cache.tmp" "$cache"
    strip_markdown < "$cache"
    return 0
  fi
  rm -f -- "$cache.tmp"
  # 退回到当前检出里的历史说明（只对已检出的旧版本有效）。
  [[ -f "$REPO/docs/releases/$tag.zh-CN.md" ]] && { strip_markdown < "$REPO/docs/releases/$tag.zh-CN.md"; return 0; }
  return 1
}

# 预览/分页都是纯文本：剥掉 Markdown 链接语法与代码围栏，只留下人能直接读的内容。
strip_markdown() {
  sed -E -e 's#\[([^]]*)\]\([^)]*\)#\1#g' -e 's#^\x60\x60\x60[a-zA-Z]*$##'
}

# --- 命令实现 ---
cmd_status() {
  CACHE_ONLY=1
  if (( JSON )); then
    render_status_json
    return 0
  fi
  render_status
}

# 给脚本调用：一条 JSON，字段稳定，不依赖 jq。
render_status_json() {
  local inst rev kind head latest avail
  inst=$(installed_version)
  rev=$(installed_revision || true)
  kind=$(source_kind)
  head=$(source_head)
  latest=$(latest_tag 0 2>/dev/null || true)
  # 没核对过就不下结论：latest/updateAvailable 给 null，调用方自己决定怎么处理。
  avail=null
  if is_dev_source; then
    # dev 版看 main HEAD；缓存过期时不确定，给 null 而不是 false
    local rel=0 mage
    mage=$(main_cache_age)
    if (( mage < 0 || mage > LATEST_TTL )); then
      avail=null
    else
      main_behind || rel=$?
      case $rel in
        0) avail=true ;;
        1) avail=false ;;
        *) avail=null ;;
      esac
    fi
  elif [[ -n "$latest" ]]; then
    if [[ "$latest" == "v$inst" ]]; then avail=false; else avail=true; fi
  fi
  printf '{"installed":{"version":"%s","revision":"%s"},' "$inst" "${rev:-}"
  printf '"source":{"kind":"%s","head":"%s","version":"%s"},' "$kind" "$head" "$(source_version)"
  # checked：正式 tag 或 main 关系至少有一个可用，才算真的核对过
  local checked=false latest_json='null'
  if [[ -n "$latest" ]]; then
    checked=true
    latest_json="\"$latest\""
  fi
  if [[ "$avail" != null ]]; then checked=true; fi
  printf '"latest":%s,"updateAvailable":%s,"checked":%s,"dev":%s,' \
    "$latest_json" "$avail" "$checked" "$(is_dev_source && printf true || printf false)"
  printf '"patches":{"dirty":%d,"files":[' "$(dirty_files | grep -c . || true)"
  local first=1 path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    (( first )) && first=0 || printf ','
    printf '"%s"' "$(json_escape "$path")"
  done < <(dirty_files)
  printf ']},"main":%s,' "$(main_json)"
  printf '"apps":%s,"lockscreen":%s,' "$(apps_installed && printf true || printf false)" \
    "$(lockscreen_installed && printf true || printf false)"
  local log_file
  log_file=$(latest_log_file || true)
  if [[ -n "$log_file" ]]; then
    printf '"log":"%s"}\n' "$(json_escape "$log_file")"
  else
    printf '"log":null}\n'
  fi
}

main_json() {
  local up sha date deployed behind=false age stale
  if ! up=$(upstream_main 0 2>/dev/null); then printf 'null'; return 0; fi
  IFS='|' read -r sha date _ <<< "$up"
  deployed=$(installed_revision_full 2>/dev/null || true)
  [[ -n "$deployed" && "$sha" != "$deployed"* ]] && behind=true
  age=$(main_cache_age)
  stale=false
  if (( age > LATEST_TTL )); then
    stale=true
    behind=null   # 缓存过期就别断言"一致/有新提交"
  fi
  printf '{"head":"%s","date":"%s","deployed":"%s","behind":%s,"age":%s,"stale":%s}' \
    "$sha" "${date:-}" "${deployed:-}" "$behind" "$age" "$stale"
}

json_escape() {
  local s=${1:-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

cmd_check() {
  if (( JSON )); then
    local inst
    inst=$(installed_version)
    # dev 版：判定依据是 main HEAD
    if is_dev_source; then
      local up sha date deployed behind_json=null avail_json=null checked=false
      deployed=$(installed_revision_full 2>/dev/null || true)
      if up=$(upstream_main 1); then
        IFS='|' read -r sha date _ <<< "$up"
        checked=true
        if [[ -n "$deployed" && "$sha" == "$deployed"* ]]; then
          behind_json=false; avail_json=false
        else
          behind_json=true; avail_json=true
        fi
      else
        sha=""; date=""
      fi
      printf '{"installed":"%s","dev":true,"checked":%s,"main":{"head":%s,"date":%s,"deployed":%s,"behind":%s},"updateAvailable":%s}\n' \
        "$inst" "$checked" \
        "$([[ -n "$sha" ]] && printf '"%s"' "$sha" || printf 'null')" \
        "$([[ -n "$date" ]] && printf '"%s"' "$date" || printf 'null')" \
        "$([[ -n "$deployed" ]] && printf '"%s"' "$deployed" || printf 'null')" \
        "$behind_json" "$avail_json"
      [[ "$avail_json" == true ]] && return 10
      [[ "$checked" == true ]] || return 1
      return 0
    fi
    local latest avail=0
    if ! latest=$(latest_tag 1); then
      # 查不到就明确说"没核成"，不要伪装成"没有更新"
      printf '{"installed":"%s","dev":false,"checked":false,"latest":null,"updateAvailable":null}\n' "$inst"
      return 1
    fi
    [[ "$latest" == "v$inst" ]] || avail=1
    printf '{"installed":"%s","latest":"%s","updateAvailable":%s,"checked":true,"dev":false}\n' \
      "$inst" "$latest" "$( (( avail )) && printf true || printf false)"
    (( avail )) && return 10
    return 0
  fi
  render_check
}

resolve_target() {
  local channel=$1
  case "$channel" in
    stable)
      local tag
      tag=$(latest_tag 1) || die '取上游最新 tag 失败（网络不可用？）'
      printf '%s' "$tag"
      ;;
    main)
      printf 'main'
      ;;
    v[0-9]*)
      tag_exists "$channel" || die "上游没有 tag：$channel"
      printf '%s' "$channel"
      ;;
    *)
      die "未知通道：$channel（可用 stable | main | vX.Y.Z）"
      ;;
  esac
}

cmd_update() {
  local channel=${1:-$DEFAULT_CHANNEL}
  repo_require
  have git || die_missing 'git'

  local target
  target=$(resolve_target "$channel") || exit 1

  local inst same=0
  inst=$(installed_version)
  [[ "$target" == "v$inst" ]] && same=1

  # 计划先行：把会做什么、要不要提权、补丁怎么处理先摊开，再让用户点头。
  local -a plan_dirty=()
  mapfile -t plan_dirty < <(dirty_files)
  printf '\n%s计划%s\n' "$BOLD" "$NC"
  printf '  目标     %s（当前已装 %s）\n' "$target" "$inst"
  printf '  动作     保存补丁 → 切换源码 → 重打补丁 → 构建部署 → 注销后生效\n'
  printf '  本地改动 %s\n' "$([[ ${#plan_dirty[@]} -gt 0 ]] && printf '%d 个文件（会导出为补丁）' "${#plan_dirty[@]}" || printf '无')"
  printf '  提权     构建时经 gsudo 安装 KWin 插件到 /usr\n'
  (( same )) && printf '  注意     目标与已装版本相同，等于重新构建当前版本\n'
  if ! confirm '按上面的计划执行？'; then
    log '已取消'
    return 0
  fi

  acquire_lock
  start_log "update-${target//\//_}"
  stage "1/6 保存本地改动（$REPO）"
  save_patch
  local -a untracked=()
  mapfile -t untracked < <(untracked_files)
  if (( ${#untracked[@]} > 0 )); then
    printf '%s未跟踪文件会阻止切换版本%s\n' "$RED" "$NC" >&2
    printf '  %s\n' "${untracked[@]}" >&2
    die "请先移走或删除它们，然后重跑（删前先确认内容）"
  fi
  if (( DRY_RUN == 0 )); then
    git -C "$REPO" reset -q HEAD -- . 2>/dev/null || true
    git -C "$REPO" checkout -- .
  fi

  stage "2/6 选择源码：$target"
  kosctl_exec update "$target" || die 'kosctl update 失败（详见上方与日志）'

  stage "3/6 重打本地补丁"
  if ! (( DRY_RUN )) && ! apply_patches; then
    # 此刻源码已经切到新版本、补丁没打上，处在“源码与已装版本不一致”的中间态，
    # 必须把状态和出路一次说清，否则用户只会看到窗口关掉。
    printf '\n%s当前状态%s\n' "$BOLD" "$NC"
    printf '  源码     %s（已切换）\n' "$(source_label)"
    printf '  已装     %s（未重建，仍在用旧版本）\n' "$inst"
    printf '  补丁     %s 个在 %s，均未应用\n' "$(patch_list | wc -l)" "$PATCH_DIR"
    printf '\n%s出路（任选其一）%s\n' "$BOLD" "$NC"
    printf '  %s patch drop   放弃这些补丁，用当前源码原样重建\n' "$PROG"
    printf '  %s rollback     回到已装版本 %s 并重装\n' "$PROG" "$inst"
    printf '  %s update %s && %s patch apply   只恢复源码，不重建\n' "$PROG" "v$inst" "$PROG"
    die '本地补丁未能干净应用，已中止（源码已切换，见上方状态与出路）'
  fi

  stage "4/6 检查构建依赖"
  preauth
  kosctl_exec doctor || warn 'doctor 报告缺项，继续（install 会自动补缺失的构建依赖）'

  stage '5/6 构建并部署核心'
  kosctl_exec install || die 'kosctl install 失败（详见日志）'

  stage '6/6 独立应用 / 锁屏 / 快捷键'
  if apps_installed; then
    kosctl_exec install apps || warn '独立应用更新失败'
  else
    log '未检测到已安装的 KOS 独立应用，跳过'
  fi
  if lockscreen_installed; then
    kosctl_exec install lockscreen || warn '锁屏更新失败'
  else
    log '未检测到 KOS 锁屏，跳过'
  fi
  # 0.1.1 之后上游把快捷键注册搬进了 shell（D-Bus shortcuts.apply），
  # kosctl 的这个子命令只是遗留壳子，新版二进制会直接打印 usage，属预期。
  if ! kosctl_exec shortcuts install; then
    printf '%s  快捷键注册已由 shell 启动时通过守护进程完成（shortcuts.apply），\n' "$DIM"
    printf '  这条 kosctl 子命令在新版上已废弃，可忽略；重新登录后自动生效。%s\n' "$NC"
  fi

  if (( START_AFTER )); then
    kosctl_exec start || warn 'kosctl start 失败'
  fi

  archive_applied_patches
  render_summary
  if (( NOTIFY )); then
    have notify-send && notify-send --app-name='KOS 更新' --icon=system-software-update \
      "KOS 桌面已更新到 $(installed_version)" '注销并重新登录后生效。' || true
  fi
  release_lock
}

cmd_rollback() {
  repo_require
  have fzf || die_missing 'fzf（sudo pacman -S fzf）'
  local tag
  set +e
  tag=$(
    remote_tags | tail -n 20 |
      fzf --height=60% --border=rounded --border-label=' 选择要回退的版本 ' \
        --layout=reverse --prompt='版本 ▸ ' \
        --header="$(printf '当前已装 %s，当前源码 %s' "$(installed_version)" "$(source_kind)@$(source_head)")"
  )
  set -e
  [[ -n "$tag" ]] || { log '已取消'; return 0; }
  confirm "回退到 $tag 并重新构建？" || { log '已取消'; return 0; }
  cmd_update "$tag"
}

cmd_patch_menu() {
  repo_require
  local choice
  # 显式给了子命令就直接执行，不再弹菜单（方便脚本里 kos patch list）。
  if [[ -z "${1:-}" ]] && [[ -t 0 ]] && have fzf; then
    set +e
    choice=$(
      printf '%s\n' \
        $'save\t导出当前未提交改动为补丁' \
        $'apply\t重打补丁库里的补丁' \
        $'list\t列出补丁库与当前改动' \
        $'drop\t丢弃当前未提交改动（不可恢复）' |
        fzf --ansi --height=50% --border=rounded --border-label=' 本地补丁 ' \
          --layout=reverse --prompt='补丁 ▸ ' --delimiter=$'\t' --with-nth=2
    )
    set -e
  else
    choice="${1:-}"
  fi
  [[ -n "${choice:-}" ]] || { log '已取消'; return 0; }
  case "${choice%%$'\t'*}" in
    save)  save_patch ;;
    apply) apply_patches ;;
    list)  cmd_preview patch ;;
    drop)
      if (( DRY_RUN )); then
        log "[dry-run] 会丢弃 $(dirty_files | grep -c . || true) 处未提交改动（补丁库保留）"
        return 0
      fi
      confirm '丢弃工作区的未提交改动？（补丁库里的补丁保留，可 apply 回来）' || { log '已取消'; return 0; }
      acquire_lock
      git -C "$REPO" reset -q HEAD -- . 2>/dev/null || true
      git -C "$REPO" checkout -- .
      ok '已恢复到检出状态'
      release_lock
      ;;
    *) warn '未知选择' ;;
  esac
}

cmd_build() {
  repo_require
  acquire_lock
  start_log 'rebuild'
  stage "重新构建并部署当前检出（$(source_label)）"
  preauth
  kosctl_exec doctor || warn 'doctor 报告缺项，继续'
  kosctl_exec install || die 'kosctl install 失败'
  if apps_installed; then kosctl_exec install apps || warn '独立应用更新失败'; fi
  if lockscreen_installed; then kosctl_exec install lockscreen || warn '锁屏更新失败'; fi
  archive_applied_patches
  render_summary
  release_lock
}

cmd_start() {
  [[ -x "$REPO/tools/kosctl" ]] || die_missing "kosctl（$REPO/tools/kosctl，先跑一次 ~/arch-kde/install.sh）"
  kosctl_exec start
}

cmd_logs() {
  local mode=${1:-}
  local latest_log
  latest_log=$(latest_log_file || true)
  [[ -n "$latest_log" ]] || { log '还没有更新日志'; return 0; }
  printf '%s%s%s\n\n' "$DIM" "$latest_log" "$NC"
  case "$mode" in
    --all) cat -- "$latest_log" ;;
    -f)    tail -f -- "$latest_log" ;;
    *)     tail -n 60 -- "$latest_log" ;;
  esac
}

# 菜单里的 ? / ctrl-e 会把它交给 less：自带分页，不占菜单的一帧。
cmd_notes() {
  local tag=${1:-}
  if [[ -z "$tag" ]]; then
    tag=$(latest_tag 0 2>/dev/null || true)
    [[ -n "$tag" ]] || die "还没有最新 tag 缓存；先跑 $PROG check"
  fi
  printf '%s发布说明 %s%s\n\n' "$BOLD" "$tag" "$NC"
  release_notes "$tag" || die "拿不到 $tag 的说明（离线，或该版本未随源码发布文档）"
}

cmd_help() { usage; }

# --- 主逻辑 ---
main() {
  local command="" cmd_args=()
  # 单循环解析：选项写在子命令前后都有效，不再静默丢弃子命令。
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -n|--dry-run) DRY_RUN=1 ;;
      --start) START_AFTER=1 ;;
      --notify) NOTIFY=1 ;;
      --hold) HOLD=1 ;;
      -q|--quiet) QUIET=1 ;;
      --json) JSON=1 ;;
      --all|-f) cmd_args+=("$1") ;;
      --) shift; while [[ $# -gt 0 ]]; do cmd_args+=("$1"); shift; done; break ;;
      -*) die_usage "未知选项：$1" ;;
      *)
        if [[ -z "$command" ]]; then
          case "$1" in
            status|check|update|rollback|patch|build|start|logs|menu|notes|help|__preview|__header) command=$1 ;;
            *) die_usage "未知命令：$1" ;;
          esac
        else
          cmd_args+=("$1")
        fi ;;
    esac
    shift
  done

  trap 'on_exit' EXIT

  if (( JSON )) && [[ "${command:-menu}" != status && "${command:-menu}" != check ]]; then
    die_usage "--json 只支持 status / check"
  fi
  case "${command:-menu}" in
    status|check|build|start|rollback|menu|help)
      (( ${#cmd_args[@]} == 0 )) || die_usage "多余参数：${cmd_args[*]}" ;;
  esac

  case "${command:-menu}" in
    menu)      cmd_menu ;;
    status)    cmd_status ;;
    check)     cmd_check ;;
    update)    cmd_update "${cmd_args[0]:-$DEFAULT_CHANNEL}" ;;
    rollback)  cmd_rollback ;;
    patch)     cmd_patch_menu "${cmd_args[0]:-}" ;;
    build)     cmd_build ;;
    start)     cmd_start ;;
    logs)      cmd_logs "${cmd_args[0]:-}" ;;
    notes)     cmd_notes "${cmd_args[0]:-}" ;;
    help)      cmd_help ;;
    __preview) cmd_preview "${cmd_args[0]:-status}" ;;
    __header)  menu_header ;;
    *)         die "未知命令：$command" ;;
  esac
}

main "$@"

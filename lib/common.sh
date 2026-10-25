#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

if [ -z "$BASH_VERSION" ]; then echo "Please run this script with bash"; exit 1; fi

STATE_DIR="$HOME/.local/state/kos-installer"
LOG_DIR="$STATE_DIR/log"
BACKUP_ROOT="$STATE_DIR/backup"
RUN_ID=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/$RUN_ID"
LOG_FILE="$LOG_DIR/install-$RUN_ID.log"
MANIFEST="$BACKUP_DIR/manifest.txt"
SUDO_KEEPALIVE_PID=

init_state() {
  mkdir -p "$LOG_DIR"
  if [ "$DRY_RUN" -eq 1 ] || [ "${CHECK_ONLY:-0}" -eq 1 ]; then
    # 演练 / 只预检都不产生备份：否则 ~/.local/state/kos-installer/backup 会被
    # 空目录塞满，回滚工具（kos-undo）里全是 “0 个文件” 的噪音。
    MANIFEST=/dev/null
    log "Log: $LOG_FILE"
    log "Backup: skipped (dry-run / --check)"
    prune_state_artifacts "$LOG_DIR" "install"
    prune_state_artifacts "$STATE_DIR" "doctor"
    return 0
  fi
  mkdir -p "$BACKUP_DIR"
  : > "$MANIFEST"
  log "Log: $LOG_FILE"
  log "Backup: $BACKUP_DIR"
  prune_state_artifacts "$LOG_DIR" "install"
  prune_state_artifacts "$STATE_DIR" "doctor"
}

log() {
  echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"
}

warn() {
  echo "[$(date +%H:%M:%S)] WARNING: $*" | tee -a "$LOG_FILE" >&2
}

die() {
  echo "[$(date +%H:%M:%S)] ERROR: $*" | tee -a "$LOG_FILE" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] $*"
    return 0
  fi
  if [ "$VERBOSE" -eq 1 ]; then log "+ $*"; fi
  "$@"
}

sudo_run() {
  run sudo "$@"
}

confirm() {
  if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
  local ans
  read -r -p "$1 [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

start_sudo_keepalive() {
  # 正常 TTY 会弹密码；非交互（SSH/CI）且已配置 NOPASSWD 时用 sudo -n 兜底。
  if ! sudo -v 2>/dev/null; then
    sudo -n true 2>/dev/null || die "sudo authentication failed"
  fi
  ( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
  SUDO_KEEPALIVE_PID=$!
}

cleanup() {
  if [ -n "$SUDO_KEEPALIVE_PID" ]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
}

# 每次 --check / --dry-run 都会留一份日志和 doctor 报告，长期会把状态目录撑满。
# 只保留最近 STATE_KEEP 份（默认 20，可用 KOS_STATE_KEEP 覆盖），按修改时间排序。
STATE_KEEP="${KOS_STATE_KEEP:-20}"

prune_state_artifacts() {
  local dir="$1" prefix="$2" f
  [ -d "$dir" ] || return 0
  local -a old=()
  while IFS= read -r f; do
    [ -n "$f" ] && old+=("$f")
  done < <(
    find "$dir" -maxdepth 1 -type f -name "${prefix}-[0-9]*" -printf '%T@ %p\n' 2>/dev/null |
      sort -rn | tail -n "+$((STATE_KEEP + 1))" | cut -d' ' -f2-
  )
  [ "${#old[@]}" -eq 0 ] && return 0
  for f in "${old[@]}"; do
    rm -f -- "$f"
  done
}

# 安装真正开始前，把现有包清单留一份。回滚时拿它和当前 pacman -Qq 做差集，
# 就能知道“这次到底新装了哪些包”，进而把它们卸掉——光靠文件备份退不干净。
record_baseline() {
  [ "${DRY_RUN:-0}" -eq 1 ] && return 0
  [ "${CHECK_ONLY:-0}" -eq 1 ] && return 0
  have pacman || return 0
  mkdir -p "$STATE_DIR/baseline"
  pacman -Qq | sort > "$STATE_DIR/baseline/$RUN_ID-pacman-Qq.txt"
  log "Baseline: $STATE_DIR/baseline/$RUN_ID-pacman-Qq.txt ($(wc -l < "$STATE_DIR/baseline/$RUN_ID-pacman-Qq.txt") packages)"
}

# 记下“本来就存在、被我们覆盖”的文件（还原时拷回）之外，还要记下“安装器新建”
# 的文件（还原时删掉），否则回滚只能恢复旧文件、留下半套新配置。
record_created() {
  local dest="$1"
  [ -n "${MANIFEST:-}" ] || return 0
  [ -d "$(dirname "$MANIFEST")" ] || return 0
  [ -e "$dest" ] && return 0
  grep -qxF "created $dest" "$MANIFEST" 2>/dev/null && return 0
  echo "created $dest" >> "$MANIFEST"
}

backup_file() {
  local src="$1"
  local rel dst sum
  if [ ! -e "$src" ]; then return 0; fi
  rel="${src#"$HOME"/}"
  dst="$BACKUP_DIR/$rel"
  if [ -e "$dst" ]; then return 0; fi
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
  sum=$(sha256sum "$src" | awk '{print $1}')
  echo "$src $sum $dst" >> "$MANIFEST"
}

# --keep-user-configs 时，目标已存在就不动它（只跳过配置文件，不动安装出来的可执行脚本）。
KEEP_USER_CONFIGS="${KEEP_USER_CONFIGS:-0}"

install_file() {
  local src="$1" dest="$2" mode=644
  if [ "$#" -ge 3 ]; then mode="$3"; fi
  if [ ! -f "$src" ]; then die "Missing file: $src"; fi
  if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] install $src -> $dest"; return 0; fi
  if [ "${KEEP_USER_CONFIGS:-0}" -eq 1 ] && [ -e "$dest" ]; then
    log "keep (--keep-user-configs): $dest"
    return 0
  fi
  record_created "$dest"
  backup_file "$dest"
  mkdir -p "$(dirname "$dest")"
  install -Dm"$mode" "$src" "$dest"
}

write_file() {
  local dest="$1"
  if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] write $dest"; cat > /dev/null; return 0; fi
  record_created "$dest"
  backup_file "$dest"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest"
}

sudo_write_file() {
  local dest="$1" tmp
  if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] sudo write $dest"; cat > /dev/null; return 0; fi
  record_created "$dest"
  backup_file "$dest"
  tmp=$(mktemp)
  cat > "$tmp"
  sudo install -Dm644 "$tmp" "$dest"
  rm -f "$tmp"
}

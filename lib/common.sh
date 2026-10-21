#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

if [ -z "$BASH_VERSION" ]; then echo "请用 bash 运行"; exit 1; fi

STATE_DIR="$HOME/.local/state/kos-installer"
LOG_DIR="$STATE_DIR/log"
BACKUP_ROOT="$STATE_DIR/backup"
RUN_ID=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/$RUN_ID"
LOG_FILE="$LOG_DIR/install-$RUN_ID.log"
MANIFEST="$BACKUP_DIR/manifest.txt"
SUDO_KEEPALIVE_PID=

init_state() {
  mkdir -p "$LOG_DIR" "$BACKUP_DIR"
  : > "$MANIFEST"
  log "日志: $LOG_FILE"
  log "备份: $BACKUP_DIR"
}

log() {
  echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"
}

warn() {
  echo "[$(date +%H:%M:%S)] 警告: $*" | tee -a "$LOG_FILE" >&2
}

die() {
  echo "[$(date +%H:%M:%S)] 错误: $*" | tee -a "$LOG_FILE" >&2
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
    sudo -n true 2>/dev/null || die "sudo 认证失败"
  fi
  ( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
  SUDO_KEEPALIVE_PID=$!
}

cleanup() {
  if [ -n "$SUDO_KEEPALIVE_PID" ]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
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

install_file() {
  local src="$1" dest="$2" mode=644
  if [ "$#" -ge 3 ]; then mode="$3"; fi
  if [ ! -f "$src" ]; then die "缺少文件: $src"; fi
  if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] install $src -> $dest"; return 0; fi
  backup_file "$dest"
  mkdir -p "$(dirname "$dest")"
  install -Dm"$mode" "$src" "$dest"
}

write_file() {
  local dest="$1"
  if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] write $dest"; cat > /dev/null; return 0; fi
  backup_file "$dest"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest"
}

sudo_write_file() {
  local dest="$1" tmp
  if [ "$DRY_RUN" -eq 1 ]; then log "[dry-run] sudo write $dest"; cat > /dev/null; return 0; fi
  backup_file "$dest"
  tmp=$(mktemp)
  cat > "$tmp"
  sudo install -Dm644 "$tmp" "$dest"
  rm -f "$tmp"
}

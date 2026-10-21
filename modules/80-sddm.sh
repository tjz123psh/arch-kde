#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# SDDM 主题：SilentSDDM（第三方，AUR: sddm-silent-theme）
#   https://github.com/uiriansan/SilentSDDM
# 要求 SDDM >= 0.21、Qt >= 6.5；Arch 的 sddm 0.21 满足。

setup_sddm_theme() {
  if [ "$NO_SDDM_THEME" -eq 1 ]; then
    log "跳过 SDDM 主题（--no-sddm-theme）"
    return 0
  fi
  if [ "$NO_AUR" -eq 1 ]; then
    warn "SDDM 主题走 AUR，已给 --no-aur，跳过"
    return 0
  fi

  log "安装 SDDM 主题依赖..."
  local p missing=()
  for p in sddm qt6-svg qt6-virtualkeyboard qt6-multimedia qt6-imageformats; do
    pkg_installed "$p" || missing+=("$p")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    sudo_run pacman -S --needed --noconfirm "${missing[@]}"
  fi

  log "安装 sddm-silent-theme（AUR）"
  if ! run "$AUR_CMD" -S --needed --noconfirm sddm-silent-theme; then
    warn "SilentSDDM 安装失败，保留现有登录主题"
    return 0
  fi

  log "写入 /etc/sddm.conf.d/90-silent.conf"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 写 sddm 配置（Current=silent）"
    return 0
  fi
  sudo mkdir -p /etc/sddm.conf.d
  sudo tee /etc/sddm.conf.d/90-silent.conf >/dev/null <<'CONF'
[General]
InputMethod=qtvirtualkeyboard
GreeterEnvironment=QML2_IMPORT_PATH=/usr/share/sddm/themes/silent/components/,QT_IM_MODULE=qtvirtualkeyboard

[Theme]
Current=silent
CONF
  log "SDDM 主题已切换到 silent（可到主题目录跑 ./test.sh 预览）"
}

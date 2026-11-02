#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

setup_ime() {
  if [ "$IME" = none ]; then
    log "跳过输入法（--ime none）"
    return 0
  fi
  log "配置 fcitx5 中文输入法（KWin Wayland 模式）..."

  # --ime rime 装的是 fcitx5-rime；profile 的 DefaultIM 也得跟着换，
  # 否则 fcitx5 按 profile 里的 DefaultIM 启动，装完还是拼音。
  local fcitx_profile="profile"
  if [ "$IME" = rime ]; then
    fcitx_profile="profile-rime"
  fi
  install_file "$CONFIG_DIR/fcitx5/$fcitx_profile" "$HOME/.config/fcitx5/profile"
  install_file "$CONFIG_DIR/fcitx5/classicui.conf" "$HOME/.config/fcitx5/conf/classicui.conf"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 禁用 fcitx5 XDG autostart（由 KWin 启动）"
    log "[dry-run] kwinrc [Wayland] InputMethod=/usr/share/applications/org.fcitx.Fcitx5.desktop"
    return 0
  fi

  write_file "$HOME/.config/autostart/org.fcitx.Fcitx5.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5
Exec=/usr/bin/fcitx5
Hidden=true
EOF

  if have kwriteconfig6; then
    # kwinrc 在 configure_kos_motion 里才备份；这里先改的 InputMethod 会把原值顶掉。
    backup_file "$HOME/.config/kwinrc"
    kwriteconfig6 --file kwinrc --group Wayland --key InputMethod /usr/share/applications/org.fcitx.Fcitx5.desktop
  else
    warn "缺少 kwriteconfig6，无法写 KWin InputMethod"
  fi
}

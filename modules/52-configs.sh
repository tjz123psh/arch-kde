#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# 用户应用配置：yazi / fastfetch / mpv / fuzzel。
# 逐文件走 install_file，已有文件会先备份到 kos-installer/backup。

install_config_tree() {
  local src="$1" dest="$2" f rel
  while IFS= read -r -d '' f; do
    rel="${f#"$src"/}"
    install_file "$f" "$dest/$rel"
  done < <(find "$src" -type f -print0)
}

install_user_configs() {
  log "安装应用配置（yazi / fastfetch / mpv / fuzzel）..."
  install_config_tree "$CONFIG_DIR/yazi" "$HOME/.config/yazi"
  install_config_tree "$CONFIG_DIR/fastfetch" "$HOME/.config/fastfetch"
  install_config_tree "$CONFIG_DIR/mpv" "$HOME/.config/mpv"
  install_config_tree "$CONFIG_DIR/fuzzel" "$HOME/.config/fuzzel"
  install_config_tree "$CONFIG_DIR/btop" "$HOME/.config/btop"
  # btop 是 TUI；系统包的 Terminal=true 依赖 KDE 默认终端，改成显式 kitty。
  install_file "$CONFIG_DIR/applications/btop.desktop" "$HOME/.local/share/applications/btop.desktop"
  install_file "$CONFIG_DIR/applications/fuzzel-launcher.desktop" "$HOME/.local/share/applications/fuzzel-launcher.desktop"
  if have kbuildsycoca6; then kbuildsycoca6 --noincremental >/dev/null 2>&1 || true; fi

  # mpv 的 assrt token 不进公开仓库：首次安装只放示例，已有配置不覆盖。
  if [ ! -e "$HOME/.config/mpv/script-opts/assrt.conf" ]; then
    install_file "$CONFIG_DIR/mpv/script-opts/assrt.conf.example" "$HOME/.config/mpv/script-opts/assrt.conf"
  fi
}

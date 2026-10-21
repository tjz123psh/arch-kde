#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# 收尾：壁纸库、KOS 默认外观。

install_wallpapers() {
  # KOS 的壁纸选择器只认托管图集目录：$XDG_DATA_HOME/kos/gallery
  # （apps/settings/src/WallpaperLibrary.cpp::galleryDirPath，按 mtime 倒序展示）
  local dst="${XDG_DATA_HOME:-$HOME/.local/share}/kos/gallery"
  log "安装壁纸库 → $dst"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 复制 $ASSET_DIR/wallpapers → $dst"
    return 0
  fi
  mkdir -p "$dst"
  cp -n "$ASSET_DIR"/wallpapers/* "$dst"/ 2>/dev/null || true
  chmod 644 "$dst"/* 2>/dev/null || true
  log "图集壁纸数：$(find "$dst" -maxdepth 1 -type f | wc -l)"
}

# 环境变量 / GTK / 字体：从老项目的 kde.sh 抽出来，只保留与桌面观感相关的部分
install_desktop_config() {
  log "写入桌面环境配置（环境变量 / GTK / 字体）..."
  install_file "$CONFIG_DIR/environment/90-kos.conf" "$HOME/.config/environment.d/90-kos.conf"
  install_file "$CONFIG_DIR/gtk/settings.ini" "$HOME/.config/gtk-3.0/settings.ini"
  install_file "$CONFIG_DIR/gtk/settings.ini" "$HOME/.config/gtk-4.0/settings.ini"
  install_file "$CONFIG_DIR/fontconfig/fonts.conf" "$HOME/.config/fontconfig/fonts.conf"
}

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

# KOS 首次启动前预置的组件外观；已有配置绝不覆盖。
# widgetStyle=glass 是官方视频里的液体玻璃桌面组件，glassStyle=liquid 是默认液体材质。
seed_kos_widget_style() {
  local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/kos/appearance"
  local config="$state_dir/config.json"

  log "预置 KOS 桌面组件样式（Glass / Liquid）..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 写入 $config（仅当文件不存在）"
    return 0
  fi
  if [ -e "$config" ]; then
    log "已有 KOS 外观配置，保留用户设置：$config"
    return 0
  fi

  mkdir -p "$state_dir"
  write_file "$config" <<'EOF'
{
  "version": 30,
  "widgetStyle": "glass",
  "glassStyle": "liquid"
}
EOF
}

# 用户要求动态主题在窗口打开时也继续动画。KOS 的 ThemeWallpaperService
# 默认只在“桌面无窗口且空闲 10 秒”时运行；这里把 themeAnimated=true 接入
# running 条件，并写入 wallpaper.ini。只改已安装的 shell 副本，不改上游 checkout。
enable_kos_theme_animation() {
  local qml="$HOME/.config/quickshell/kos/desktop/modules/wallpaper/ThemeWallpaperService.qml"
  local ini="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/kos/wallpaper.ini"

  log "开启 KOS 动态主题常驻动画（有窗口时也不停）..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 修改 ThemeWallpaperService.running 并写入 themeAnimated=true"
    return 0
  fi
  if [ ! -f "$qml" ]; then
    warn "找不到 ThemeWallpaperService.qml，跳过动态主题常驻动画"
    return 0
  fi

  python3 - "$qml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = "readonly property bool running: active && cadence>0 && (preview || idleReady && idleEligible)"
new = "readonly property bool running: active && cadence>0 && (preview || WallpaperService.themeAnimated || (idleReady && idleEligible))"
if old in source:
    path.write_text(source.replace(old, new, 1))
elif new not in source:
    print("ThemeWallpaperService: unexpected running line; leaving file unchanged", file=sys.stderr)
PY

  if have kwriteconfig6; then
    kwriteconfig6 --file "$ini" --group Wallpaper --key themeAnimated true --notify
  fi
  log "动态主题：themeAnimated=true，窗口打开时继续渲染"
}

# 环境变量 / GTK / 字体：从老项目的 kde.sh 抽出来，只保留与桌面观感相关的部分
install_desktop_config() {
  log "写入桌面环境配置（环境变量 / GTK / 字体）..."
  install_file "$CONFIG_DIR/environment/90-kos.conf" "$HOME/.config/environment.d/90-kos.conf"
  install_file "$CONFIG_DIR/gtk/settings.ini" "$HOME/.config/gtk-3.0/settings.ini"
  install_file "$CONFIG_DIR/gtk/settings.ini" "$HOME/.config/gtk-4.0/settings.ini"
  install_file "$CONFIG_DIR/fontconfig/fonts.conf" "$HOME/.config/fontconfig/fonts.conf"

  # 首次登录把主屏设成 1920x1080（安装器在 TTY 里改不了 Wayland 输出）
  install_file "$CONFIG_DIR/display/kos-display-1920x1080.sh" "$HOME/.local/bin/kos-display-1920x1080" 755
  install_file "$CONFIG_DIR/display/kos-display-1920x1080.desktop" "$HOME/.config/autostart/kos-display-1920x1080.desktop"
  enable_kos_theme_animation
}

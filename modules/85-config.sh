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
    mkdir -p "$(dirname "$ini")"
    kwriteconfig6 --file "$ini" --group Wallpaper --key themeAnimated true --notify
  fi
  log "动态主题：themeAnimated=true，窗口打开时继续渲染"
}

# 只在新安装、还没有 Dock 配置时预置；已有配置保留，避免覆盖用户自己的 Dock。
# visibilityMode=smart 对应设置里的“智能隐藏”。
seed_kos_dock_visibility() {
  local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/kos/dock"
  local config="$state_dir/config.json"

  log "预置 KOS Dock 显示方式（智能隐藏）..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 写入 $config（仅当文件不存在）"
    return 0
  fi
  if [ -e "$config" ]; then
    log "已有 Dock 配置，保留用户设置：$config"
    return 0
  fi

  mkdir -p "$state_dir"
  write_file "$config" <<'EOF'
{
  "visibilityMode": "smart"
}
EOF
}

# 环境变量 / GTK / 字体：从老项目的 kde.sh 抽出来，只保留与桌面观感相关的部分
# 终端只保留内容：用 KWin 规则把 kitty 的标题栏/窗口边框隐藏。
# KWin 6.8 用 decorationpolicy=none 表达无边框（旧的 noborder 键不再适用）。
install_kitty_no_decorations() {
  log "配置 kitty 无标题栏（KWin 窗口规则）..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 写入 kwinrulesrc：kitty_no_decorations（decorationpolicy=none）"
    return 0
  fi
  if ! have kwriteconfig6; then
    warn "缺少 kwriteconfig6，跳过 kitty 窗口规则"
    return 0
  fi

  backup_file "$HOME/.config/kwinrulesrc"
  kwriteconfig6 --file kwinrulesrc --group kitty_no_decorations --key Description "Kitty: no window decorations" --notify
  kwriteconfig6 --file kwinrulesrc --group kitty_no_decorations --key decorationpolicy none --notify
  kwriteconfig6 --file kwinrulesrc --group kitty_no_decorations --key decorationpolicyrule 2 --notify
  kwriteconfig6 --file kwinrulesrc --group kitty_no_decorations --key types 1 --notify
  kwriteconfig6 --file kwinrulesrc --group kitty_no_decorations --key wmclass kitty --notify
  kwriteconfig6 --file kwinrulesrc --group kitty_no_decorations --key wmclasscomplete false --notify
  kwriteconfig6 --file kwinrulesrc --group kitty_no_decorations --key wmclassmatch 1 --notify

  local order
  order=$(kreadconfig6 --file kwinrulesrc --group General --key Order 2>/dev/null || true)
  case ",$order," in
    *,kitty_no_decorations,*) ;;
    *) kwriteconfig6 --file kwinrulesrc --group General --key Order "${order:+$order,}kitty_no_decorations" --notify ;;
  esac

  if have qdbus6; then
    qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
  fi
  log "kitty 窗口规则已写入；新开终端只显示内容"
}

# 让智能隐藏的 Dock 提示条更低调：降低白色主体和黑色 scrim，并略微变细。
enable_kos_subtle_dock_reveal() {
  local qml="$HOME/.config/quickshell/kos/desktop/modules/dock/DockRevealHandle.qml"

  log "调低 Dock 隐藏提示条的灰暗/存在感..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 修改 DockRevealHandle：半透明 0.30、scrim 0.25、厚度 5"
    return 0
  fi
  if [ ! -f "$qml" ]; then
    warn "找不到 DockRevealHandle.qml，跳过 Dock 提示条调整"
    return 0
  fi

  python3 - "$qml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
replacements = [
    ("barBaseColor: Qt.rgba(1, 1, 1, 0.55)",
     "barBaseColor: Qt.rgba(1, 1, 1, 0.30)"),
    ("readonly property real visualThickness: 6",
     "readonly property real visualThickness: 5"),
    ("scrimCap: 0.90", "scrimCap: 0.25"),
]
for old, new in replacements:
    if old in source:
        source = source.replace(old, new, 1)
path.write_text(source)
PY
  log "Dock 隐藏提示条已调低"
}

# 三个设置/监视器窗口的轻量磨砂玻璃近似：KWin 只负责半透明窗口 +
# 既有 Glass 背景模糊；不是 KOS Shell 的完整液体折射。
frosted_window_rule() {
  local group="$1" wmclass="$2" match="${3:-1}"
  kwriteconfig6 --file kwinrulesrc --group "$group" --key Description "Frosted glass: $wmclass" --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key opacityactive 86 --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key opacityactiverule 2 --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key opacityinactive 86 --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key opacityinactiverule 2 --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key types 1 --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key wmclass "$wmclass" --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key wmclasscomplete false --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key wmclassmatch "$match" --notify
}

enable_frosted_kde_windows() {
  log "配置 KDE 设置/系统监视器/Dolphin 的磨砂玻璃窗口..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 写入 kwinrulesrc：systemsettings / plasma-systemmonitor / kos-settings 半透明规则"
    return 0
  fi
  if ! have kwriteconfig6; then
    warn "缺少 kwriteconfig6，跳过磨砂玻璃窗口规则"
    return 0
  fi

  backup_file "$HOME/.config/kwinrulesrc"
  frosted_window_rule frosted_systemsettings systemsettings
  frosted_window_rule frosted_systemmonitor plasma-systemmonitor 2
  # 系统监视器窗口面积大，单独再透一点，别看起来像一整块暗色板。
  kwriteconfig6 --file kwinrulesrc --group frosted_systemmonitor --key opacityactive 75 --notify
  kwriteconfig6 --file kwinrulesrc --group frosted_systemmonitor --key opacityinactive 80 --notify
  frosted_window_rule frosted_kos_settings kos-settings
  frosted_window_rule frosted_dolphin org.kde.dolphin
  # 文件管理器阅读为主，保留更实的底，不跟系统监视器一样透。
  kwriteconfig6 --file kwinrulesrc --group frosted_dolphin --key opacityactive 90 --notify
  kwriteconfig6 --file kwinrulesrc --group frosted_dolphin --key opacityinactive 92 --notify

  local order group
  order=$(kreadconfig6 --file kwinrulesrc --group General --key Order 2>/dev/null || true)
  for group in frosted_systemsettings frosted_systemmonitor frosted_kos_settings frosted_dolphin; do
    case ",$order," in
      *,$group,*) ;;
      *) order="${order:+$order,}$group" ;;
    esac
  done
  kwriteconfig6 --file kwinrulesrc --group General --key Order "$order" --notify

  if have qdbus6; then
    qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
  fi
  log "磨砂玻璃窗口规则已写入"
}

# KOS 设置是自绘 QML 窗口；让 ApplicationWindow 底色透明，交给 KWin Glass 模糊。
enable_kos_frosted_settings() {
  local qml="$HOME/.local/share/kos/settings/main.qml"

  log "让 KOS 设置背景透明以接入磨砂玻璃..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 修改 KOS Settings main.qml 背景 alpha=0.78"
    return 0
  fi
  if [ ! -f "$qml" ]; then
    warn "找不到 KOS Settings main.qml，跳过磨砂设置背景"
    return 0
  fi

  python3 - "$qml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = "    color: theme.background"
new = "    color: Qt.rgba(theme.background.r, theme.background.g, theme.background.b, 0.78)"
if old in source:
    path.write_text(source.replace(old, new, 1))
elif new not in source:
    print("KOS Settings main.qml: unexpected background color line", file=sys.stderr)
PY
  log "KOS 设置背景已改为半透明"
}

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
  install_kitty_no_decorations
  enable_kos_subtle_dock_reveal
  enable_frosted_kde_windows
  enable_kos_frosted_settings
}

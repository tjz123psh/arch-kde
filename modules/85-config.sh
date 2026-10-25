#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# 收尾：壁纸库、KOS 默认外观。

install_wallpapers() {
  # KOS 的壁纸选择器只认托管图集目录：$XDG_DATA_HOME/kos/gallery
  # （apps/settings/src/WallpaperLibrary.cpp::galleryDirPath，按 mtime 倒序展示）
  local dst="${XDG_DATA_HOME:-$HOME/.local/share}/kos/gallery"
  log "Installing the wallpaper gallery -> $dst"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] copy $ASSET_DIR/wallpapers -> $dst"
    return 0
  fi
  mkdir -p "$dst"
  cp -n "$ASSET_DIR"/wallpapers/* "$dst"/ 2>/dev/null || true
  chmod 644 "$dst"/* 2>/dev/null || true
  log "Wallpapers in gallery: $(find "$dst" -maxdepth 1 -type f | wc -l)"
}

# 默认壁纸：把 Plasma 桌面和 KOS 都指到图集里的一张，别让新系统先露出 KDE 的默认壁纸。
# 只写“还没配过”的情况；重跑安装器时，用户自己在图集里选过的图不会被换掉。
# 首次登录再设一次 Plasma 壁纸：安装器在 TTY 里跑，碰不到运行中的 plasmashell；
# 全新机器的 appletsrc 也不存在，硬写进去 Plasma 不认。这里用自启动 + 标记文件兜底。
install_wallpaper_first_login() {
  local dest="$1"
  local script="$HOME/.local/bin/kos-wallpaper-first-login"
  local entry="$HOME/.config/autostart/kos-wallpaper-first-login.desktop"

  mkdir -p "$HOME/.local/bin" "$HOME/.config/autostart"
  write_file "$script" <<EOF
#!/usr/bin/env bash
# 由 KOS 安装器生成：首次登录把 Plasma 壁纸设成图集里的图，成功一次后不再动。
set -u
STATE="\${XDG_STATE_HOME:-\$HOME/.local/state}/kos-installer"
MARKER="\$STATE/wallpaper-applied.done"
LOG="\$STATE/log/wallpaper-first-login.log"
note() { mkdir -p "\$(dirname "\$LOG")"; printf '%s %s\\n' "\$(date '+%F %T')" "\$*" >> "\$LOG"; }
[ -e "\$MARKER" ] && exit 0
WANT="$dest"
[ -f "\$WANT" ] || { note "skip: wallpaper missing"; exit 0; }
command -v plasma-apply-wallpaperimage >/dev/null 2>&1 || { note "skip: plasma-apply-wallpaperimage missing"; exit 0; }
for _ in \$(seq 1 60); do
  pgrep -x plasmashell >/dev/null 2>&1 && break
  sleep 1
done
sleep 2
cur=\$(kreadconfig6 --file plasma-org.kde.plasma.desktop-appletsrc \
  --group Containments --group 1 --group Wallpaper --group org.kde.image --group General \
  --key Image 2>/dev/null || true)
case "\$cur" in
  */kos/gallery/*)
    mkdir -p "\$(dirname "\$MARKER")"; : > "\$MARKER"
    note "keep: already \$cur"
    exit 0
    ;;
esac
if plasma-apply-wallpaperimage "\$WANT" >/dev/null 2>&1; then
  mkdir -p "\$(dirname "\$MARKER")"
  : > "\$MARKER"
  note "applied: \$WANT"
else
  note "failed: plasma-apply-wallpaperimage \$WANT"
fi
exit 0
EOF
  chmod 755 "$script"

  write_file "$entry" <<'EOF'
[Desktop Entry]
Type=Application
Name=KOS Wallpaper
Comment=Apply the bundled wallpaper on first login
Exec=/bin/sh -c "exec ~/.local/bin/kos-wallpaper-first-login"
Terminal=false
X-KDE-autostart-after=panel
OnlyShowIn=KDE;
EOF
  log "First-login wallpaper autostart installed"
}

seed_default_wallpaper() {
  local gallery="${XDG_DATA_HOME:-$HOME/.local/share}/kos/gallery"
  local pick="${WALLPAPER:-樱吹雪.png}"
  local dest ini applets current=""

  log "Setting the default wallpaper ($pick)..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] point the Plasma desktop and the KOS wallpaper at $gallery/$pick"
    return 0
  fi

  if [ ! -f "$gallery/$pick" ] && [ -f "$gallery/$pick.png" ]; then
    pick="$pick.png"
  fi
  if [ ! -f "$gallery/$pick" ]; then
    pick=$(find "$gallery" -maxdepth 1 -type f -name '*.png' -printf '%f\n' 2>/dev/null | sort | head -n 1 || true)
    if [ -z "$pick" ]; then
      warn "No wallpaper in $gallery; leaving the wallpaper alone"
      return 0
    fi
    warn "Wallpaper not found; falling back to $pick"
  fi
  dest="$gallery/$pick"

  # Plasma 桌面壁纸分两种情况：
  #   a) 已经有 Plasma 配置（重装 / 二次运行）→ 直接改 appletsrc，登录后立刻是这张
  #   b) 全新系统还没有 appletsrc → **不要**伪造 [Containments][1]：Plasma 第一次启动时
  #      会自己建一个带 activityId/plugin 的 containment，我们写的那个没人认领，结果
  #      还是 KDE 默认壁纸。这种情况改为装一个“首次登录自启动”，进桌面后再设置。
  applets="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
  if [ -f "$applets" ] && have kwriteconfig6; then
    if have kreadconfig6; then
      current=$(kreadconfig6 --file plasma-org.kde.plasma.desktop-appletsrc \
        --group Containments --group 1 --group Wallpaper --group org.kde.image --group General \
        --key Image 2>/dev/null || true)
    fi
    case "$current" in
      */kos/gallery/*)
        if [ "${WALLPAPER_FORCE:-0}" -ne 1 ]; then
          log "Plasma wallpaper already picked from the gallery; keeping $current"
          applets=""
        fi
        ;;
    esac
    if [ -n "$applets" ]; then
      if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] && have plasma-apply-wallpaperimage; then
        plasma-apply-wallpaperimage "$dest" >/dev/null 2>&1 ||
          warn "plasma-apply-wallpaperimage failed; writing the config instead"
      fi
      record_created "$applets"
      backup_file "$applets"
      kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc \
        --group Containments --group 1 --group Wallpaper --key wallpaperplugin org.kde.image --notify
      kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc \
        --group Containments --group 1 --group Wallpaper --group org.kde.image --group General \
        --key Image "file://$dest" --notify
      log "Plasma desktop wallpaper -> $dest"
    fi
  else
    log "No Plasma config yet (first login ahead); wallpaper will be applied by autostart"
  fi

  install_wallpaper_first_login "$dest"

  # KOS 自己的壁纸配置：只在还没生成时预置，免得覆盖用户已经在设置里选好的壁纸。
  ini="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/kos/wallpaper.ini"
  if [ -e "$ini" ] && [ "${WALLPAPER_FORCE:-0}" -ne 1 ]; then
    log "Existing KOS wallpaper config found; keeping it: $ini"
    return 0
  fi
  mkdir -p "$(dirname "$ini")"
  write_file "$ini" <<EOF
[Wallpaper]
image=$dest
mode=image
fitMode=crop
takeoverEnabled=true
themeAnimated=true
libraryMigrated=true
EOF
  log "KOS wallpaper -> $dest"
}

# KOS 首次启动前预置的组件外观；已有配置绝不覆盖。
# widgetStyle=glass 是官方视频里的液体玻璃桌面组件，glassStyle=liquid 是默认液体材质。
seed_kos_widget_style() {
  local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/kos/appearance"
  local config="$state_dir/config.json"

  log "Seeding the KOS desktop widget style (Glass / Liquid)..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] write $config (only if missing)"
    return 0
  fi
  if [ -e "$config" ]; then
    log "Existing KOS appearance config found; keeping user settings: $config"
    return 0
  fi

  mkdir -p "$state_dir"
  write_file "$config" <<'EOF'
{
  "version": 30,
  "widgetStyle": "glass",
  "glassStyle": "liquid",
  "barMacStyle": false,
  "barMacTint": 0.30,
  "barLayoutMode": "transparent",
  "barVisibilityMode": "always",
  "hiddenDeskCenterWidgets": ["todo"]
}
EOF
}

# 用户要求动态主题在窗口打开时也继续动画。KOS 的 ThemeWallpaperService
# 默认只在“桌面无窗口且空闲 10 秒”时运行；这里把 themeAnimated=true 接入
# running 条件，并写入 wallpaper.ini。只改已安装的 shell 副本，不改上游 checkout。
enable_kos_theme_animation() {
  local qml="$HOME/.config/quickshell/kos/desktop/modules/wallpaper/ThemeWallpaperService.qml"
  local ini="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/kos/wallpaper.ini"

  log "Keeping the KOS animated theme running even with windows open..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] patch ThemeWallpaperService.running and write themeAnimated=true"
    return 0
  fi
  if [ ! -f "$qml" ]; then
    warn "ThemeWallpaperService.qml not found; skipping the animated-theme patch"
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
  log "Animated theme: themeAnimated=true, keeps rendering with windows open"
}

# 只在新安装、还没有 Dock 配置时预置；已有配置保留，避免覆盖用户自己的 Dock。
# visibilityMode=smart 对应设置里的“智能隐藏”。
seed_kos_dock_visibility() {
  local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/kos/dock"
  local config="$state_dir/config.json"

  log "Seeding the KOS dock visibility (smart hide)..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] write $config (only if missing)"
    return 0
  fi
  if [ -e "$config" ]; then
    log "Existing dock config found; keeping user settings: $config"
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
# 终端能不能用鼠标拖边缩放，取决于窗口有没有"能抓的边缘"：
# KWin 对没有窗口装饰的窗口不提供缩放把手（鼠标贴边也只会是文本光标），
# 而 KOS 自带的窗口装饰（kos_decoration）正好是"细标题栏 + 看不见的缩放边框"。
# 所以这里不再关掉 kitty 的装饰，而是反向清理：旧版本写过的
# kitty_no_decorations 规则（decorationpolicy=none）如果还在，就删掉。
remove_kitty_no_decorations() {
  local rules="$HOME/.config/kwinrulesrc" tmp
  log "Removing the kitty no-decoration rule (keeping resizable borders)..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] remove kitty_no_decorations from kwinrulesrc if present"
    return 0
  fi
  if [ ! -f "$rules" ] || ! grep -qxF '[kitty_no_decorations]' "$rules"; then
    return 0
  fi
  if ! have kwriteconfig6; then
    warn "kwriteconfig6 missing; cannot clean kwinrulesrc"
    return 0
  fi

  backup_file "$rules"
  tmp=$(mktemp)
  # 整段删掉规则，并从 General/Order 里摘掉它的名字；留空段会被 KWin 当成空条件规则。
  awk '
    $0 == "[kitty_no_decorations]" { skip = 1; next }
    skip && /^\[/ { skip = 0 }
    skip { next }
    /^Order=/ {
      n = split(substr($0, 7), parts, ",")
      keep = ""
      for (i = 1; i <= n; i++) {
        if (parts[i] == "" || parts[i] == "kitty_no_decorations") continue
        keep = (keep == "" ? parts[i] : keep "," parts[i])
      }
      print "Order=" keep
      next
    }
    { print }
  ' "$rules" > "$tmp" && mv "$tmp" "$rules"

  if have qdbus6; then
    qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
  fi
  log "kitty no-decoration rule removed; new terminals can be resized with the mouse"
}

# 让智能隐藏的 Dock 提示条更低调：降低白色主体和黑色 scrim，并略微变细。
enable_kos_subtle_dock_reveal() {
  local qml="$HOME/.config/quickshell/kos/desktop/modules/dock/DockRevealHandle.qml"

  log "Toning down the dock reveal hint..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] patch DockRevealHandle: opacity 0.30, scrim 0.25, thickness 5"
    return 0
  fi
  if [ ! -f "$qml" ]; then
    warn "DockRevealHandle.qml not found; skipping the dock hint tweak"
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
  log "Dock reveal hint toned down"
}

# 三个设置/监视器窗口的轻量磨砂玻璃近似：KWin 只负责半透明窗口 +
# 既有 Glass 背景模糊；不是 KOS Shell 的完整液体折射。
frosted_window_rule() {
  local group="$1" wmclass="$2" match="${3:-1}" types="${4:-1}"
  kwriteconfig6 --file kwinrulesrc --group "$group" --key Description "Frosted glass: $wmclass" --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key opacityactive 86 --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key opacityactiverule 2 --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key opacityinactive 86 --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key opacityinactiverule 2 --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key types "$types" --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key wmclass "$wmclass" --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key wmclasscomplete false --notify
  kwriteconfig6 --file kwinrulesrc --group "$group" --key wmclassmatch "$match" --notify
}

enable_frosted_kde_windows() {
  log "Frosting the KDE Settings / KCM / System Monitor / Dolphin windows..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] write kwinrulesrc opacity rules for systemsettings / plasma-systemmonitor / kos-settings"
    return 0
  fi
  if ! have kwriteconfig6; then
    warn "kwriteconfig6 missing; skipping the frosted-window rules"
    return 0
  fi

  backup_file "$HOME/.config/kwinrulesrc"
  frosted_window_rule frosted_systemsettings systemsettings
  frosted_window_rule frosted_systemmonitor plasma-systemmonitor 2
  # 系统监视器窗口面积大，单独再透一点，别看起来像一整块暗色板。
  kwriteconfig6 --file kwinrulesrc --group frosted_systemmonitor --key opacityactive 75 --notify
  kwriteconfig6 --file kwinrulesrc --group frosted_systemmonitor --key opacityinactive 80 --notify
  frosted_window_rule frosted_kos_settings kos-settings
  frosted_window_rule frosted_kinfocenter org.kde.kinfocenter
  frosted_window_rule frosted_dolphin org.kde.dolphin
  frosted_window_rule frosted_kcm_bluetooth kcm_bluetooth
  frosted_window_rule frosted_kcm_networkmanagement kcm_networkmanagement
  frosted_window_rule frosted_kcmshell6 kcmshell6 2
  frosted_window_rule frosted_kcm_all kcm_ 2
  frosted_window_rule frosted_bluedevil_wizard bluedevil-wizard
  frosted_window_rule frosted_plasma_nm plasma-nm
  frosted_window_rule frosted_systemsettings_dialog systemsettings 1 2
  # 文件管理器阅读为主，保留更实的底，不跟系统监视器一样透。
  kwriteconfig6 --file kwinrulesrc --group frosted_dolphin --key opacityactive 90 --notify
  kwriteconfig6 --file kwinrulesrc --group frosted_dolphin --key opacityinactive 92 --notify

  local order group
  order=$(kreadconfig6 --file kwinrulesrc --group General --key Order 2>/dev/null || true)
  for group in frosted_systemsettings frosted_systemmonitor frosted_kos_settings frosted_kinfocenter frosted_dolphin frosted_kcm_bluetooth frosted_kcm_networkmanagement frosted_kcmshell6 frosted_kcm_all frosted_bluedevil_wizard frosted_plasma_nm frosted_systemsettings_dialog; do
    case ",$order," in
      *,$group,*) ;;
      *) order="${order:+$order,}$group" ;;
    esac
  done
  kwriteconfig6 --file kwinrulesrc --group General --key Order "$order" --notify

  if have qdbus6; then
    qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
  fi
  log "Frosted-window rules written"
}

# KOS 设置是自绘 QML 窗口；让 ApplicationWindow 底色透明，交给 KWin Glass 模糊。
enable_kos_frosted_settings() {
  local qml="$HOME/.local/share/kos/settings/main.qml"

  log "Making the KOS Settings background translucent for the frosted effect..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] patch KOS Settings main.qml background alpha=0.78"
    return 0
  fi
  if [ ! -f "$qml" ]; then
    warn "KOS Settings main.qml not found; skipping the translucent background"
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
  log "KOS Settings background made translucent"
}

# 默认应用：文本/语言文件用 Neovim，PDF 用 WPS，图片用 nomacs，
# 文件夹用 Dolphin；不覆盖这里没列出的关联。
install_default_apps() {
  log "Setting default apps (Neovim / WPS / nomacs / Dolphin)..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] write mimeapps.list and kdeglobals defaults"
    return 0
  fi
  if ! have xdg-mime; then
    warn "xdg-mime missing; skipping default apps"
    return 0
  fi

  backup_file "$HOME/.config/mimeapps.list"
  backup_file "$HOME/.config/kdeglobals"

  local mime desktop
  while IFS='|' read -r mime desktop; do
    [ -n "$mime" ] || continue
    if [ -f "/usr/share/applications/$desktop" ]; then
      xdg-mime default "$desktop" "$mime" || warn "Default app failed: $mime -> $desktop"
    else
      warn "Desktop file missing: $desktop (skipping $mime)"
    fi
  done <<'EOF'
text/plain|nvim.desktop
text/x-python|nvim.desktop
application/json|nvim.desktop
application/x-shellscript|nvim.desktop
text/x-c|nvim.desktop
text/x-c++src|nvim.desktop
text/x-c++hdr|nvim.desktop
text/x-chdr|nvim.desktop
text/x-java|nvim.desktop
text/x-makefile|nvim.desktop
text/x-tex|nvim.desktop
application/xml|nvim.desktop
text/xml|nvim.desktop
application/pdf|wps-office-pdf.desktop
image/png|org.nomacs.ImageLounge.desktop
image/jpeg|org.nomacs.ImageLounge.desktop
image/webp|org.nomacs.ImageLounge.desktop
image/gif|org.nomacs.ImageLounge.desktop
image/avif|org.nomacs.ImageLounge.desktop
image/bmp|org.nomacs.ImageLounge.desktop
image/heic|org.nomacs.ImageLounge.desktop
image/heif|org.nomacs.ImageLounge.desktop
image/tiff|org.nomacs.ImageLounge.desktop
image/jxl|org.nomacs.ImageLounge.desktop
image/svg+xml|org.nomacs.ImageLounge.desktop
image/x-icon|org.nomacs.ImageLounge.desktop
inode/directory|org.kde.dolphin.desktop
EOF

  if have kwriteconfig6; then
    kwriteconfig6 --file kdeglobals --group General --key TerminalApplication kitty --notify
    kwriteconfig6 --file kdeglobals --group General --key TerminalService kitty.desktop --notify
  fi
  log "Default apps written"
}

# 统一 KDE / Qt / GTK 外观：BreezeDark + WhiteSur-dark 图标 + WhiteSur 光标。
# 这里不强行改 KWin 窗口装饰，避免覆盖 KOS 的窗口风格。
configure_kde_global_appearance() {
  log "Unifying the global look (BreezeDark + WhiteSur-dark + WhiteSur cursors)..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] write kdeglobals / kcminputrc and apply the WhiteSur look"
    return 0
  fi
  if ! have kwriteconfig6; then
    warn "kwriteconfig6 missing; skipping the global look"
    return 0
  fi

  backup_file "$HOME/.config/kdeglobals"
  backup_file "$HOME/.config/kcminputrc"
  kwriteconfig6 --file kdeglobals --group General --key ColorScheme BreezeDark --notify
  kwriteconfig6 --file kdeglobals --group Icons --key Theme WhiteSur-dark --notify
  kwriteconfig6 --file kdeglobals --group General --key cursorTheme WhiteSur-cursors --notify
  # KDE 全局字体必须显式设成 CJK 字体：不设时 KDE 用内置默认 Noto Sans（非 CJK），
  # 而 kde-gtk-config 会把这个字体原样写进 ~/.config/gtk-{3,4}.0/settings.ini，
  # 把安装器写的 gtk-font-name 覆盖掉（2026-10-25 实测：gtk-font-name 从
  # "Noto Sans CJK SC 10" 变成 "Noto Sans,  10"）。设在这里，KDE 界面和 GTK 应用
  # 才会用同一套中文字形，也不会再被 kded 改回去。
  # 格式是 QFont::toString：字体,字号,像素大小,styleHint,字重,斜体,下划线,删除线,等宽,rawMode
  local cjk_font="Noto Sans CJK SC,10,-1,5,50,0,0,0,0,0"
  local mono_font="Maple Mono NF CN,10,-1,5,50,0,0,0,0,0"
  local small_font="Noto Sans CJK SC,8,-1,5,50,0,0,0,0,0"
  kwriteconfig6 --file kdeglobals --group General --key font "$cjk_font" --notify
  kwriteconfig6 --file kdeglobals --group General --key fixed "$mono_font" --notify
  kwriteconfig6 --file kdeglobals --group General --key smallestReadableFont "$small_font" --notify
  kwriteconfig6 --file kdeglobals --group General --key menuFont "$cjk_font" --notify
  kwriteconfig6 --file kdeglobals --group General --key toolBarFont "$cjk_font" --notify
  kwriteconfig6 --file kdeglobals --group General --key taskbarFont "$cjk_font" --notify
  kwriteconfig6 --file kdeglobals --group General --key activeFont "$cjk_font" --notify
  kwriteconfig6 --file kcminputrc --group Mouse --key cursorTheme WhiteSur-cursors --notify

  if have plasma-apply-colorscheme; then
    plasma-apply-colorscheme BreezeDark >/dev/null 2>&1 || true
  fi
  if have plasma-apply-cursortheme; then
    plasma-apply-cursortheme WhiteSur-cursors >/dev/null 2>&1 || true
  fi
  if have kbuildsycoca6; then
    kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
  fi
  log "Global look unified"
}

# 新装时的桌面小组件布局：时钟大卡、天气横向、日历/系统两列、活动/音乐底部。
# 已有 deskcenter-widgets.ini 时保留用户布局。
seed_kos_widget_layout() {
  local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/kos"
  local config="$state_dir/deskcenter-widgets.ini"

  log "Seeding the KOS desktop widget layout..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] write $config (only if missing)"
    return 0
  fi
  if [ -e "$config" ]; then
    log "Existing widget layout found; keeping user settings: $config"
    return 0
  fi

  mkdir -p "$state_dir"
  write_file "$config" <<'EOF'
[Widgets]
desktopLyricsEnabled=true
desktopLyricsX=0.5
desktopLyricsY=1
orderJson=["clock","weather","calendar","system","activity","music","todo"]
schemaVersion=2
sizesJson={"clock":"large","weather":"small","calendar":"large","system":"large","activity":"medium","music":"medium"}
EOF
}

# 窗口动效：KOS 的 dock-window-animation 负责打开/关闭/最小化/恢复；
# 玻璃部分只轻加全局模糊，保持 liquid 的清晰折射。
configure_kos_motion() {
  log "Configuring window effects and glass parameters..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] write kwinrc effects (genie + durations + wobbly windows) and glass blur=0.10"
    return 0
  fi
  if ! have kwriteconfig6; then
    warn "kwriteconfig6 missing; skipping window effects"
    return 0
  fi

  backup_file "$HOME/.config/kwinrc"
  # 动画风格：最小化/恢复走 macOS 那种 genie（吸进 Dock），打开永远是缩放（效果里写死）。
  kwriteconfig6 --file kwinrc --group Effect-kos_dock_window_animation --key AnimationStyle genie --notify
  kwriteconfig6 --file kwinrc --group Effect-kos_dock_window_animation --key HideAnimation genie --notify
  kwriteconfig6 --file kwinrc --group Effect-kos_dock_window_animation --key CloseAnimation scale --notify
  # 时长按 macOS 手感：genie ~0.34s，入场比退场快，关窗最短。
  kwriteconfig6 --file kwinrc --group Effect-kos_dock_window_animation --key OpenDuration 250 --notify
  kwriteconfig6 --file kwinrc --group Effect-kos_dock_window_animation --key GenieDuration 340 --notify
  kwriteconfig6 --file kwinrc --group Effect-kos_dock_window_animation --key RestoreDuration 220 --notify
  kwriteconfig6 --file kwinrc --group Effect-kos_dock_window_animation --key CloseDuration 180 --notify

  # 摆动窗口（Wobbly Windows，Compiz 同源）：拖动/缩放时窗口做弹簧形变。
  # KDE 自带效果，只暴露三档幅度 + 两个开关，没有 friction/mass 那种数值。
  kwriteconfig6 --file kwinrc --group Plugins --key wobblywindowsEnabled true --notify
  kwriteconfig6 --file kwinrc --group Effect-wobblywindows --key WobblynessLevel 2 --notify
  kwriteconfig6 --file kwinrc --group Effect-wobblywindows --key MoveWobble true --notify
  kwriteconfig6 --file kwinrc --group Effect-wobblywindows --key ResizeWobble true --notify

  if have qdbus6; then
    # KWin 6.8 起 /org/kde/KWin 上不再导出 org.kde.kwin.Effects（见 60-kos.sh 里
    # Settings 集成探针的说明），旧的 reconfigureEffect 调用必然失败；改成让 KWin
    # 重读 kwinrc，效果自己会按新配置重载。
    qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
  fi

  local config="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/kos/appearance/config.json"
  if [ -f "$config" ]; then
    python3 - "$config" <<'PY'
from pathlib import Path
import json
import sys
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except Exception:
    raise SystemExit
if isinstance(data, dict):
    data["globalBlurStrength"] = 0.10
    data["globalLiquidStrength"] = 1
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
  fi
  log "Window effects and glass parameters written"
}

# Dolphin 默认详情视图：16px 图标、紧凑行距、完整路径、小状态栏。
# Places 侧栏保持 Dolphin 默认显示；不写 places 数据，避免覆盖用户书签。
configure_dolphin_layout() {
  log "Configuring the Dolphin details view and compact layout..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] write dolphinrc details view and global view properties"
    return 0
  fi
  if ! have kwriteconfig6; then
    warn "kwriteconfig6 missing; skipping the Dolphin layout"
    return 0
  fi

  backup_file "$HOME/.config/dolphinrc"
  kwriteconfig6 --file dolphinrc --group General --key ShowFullPath true --notify
  kwriteconfig6 --file dolphinrc --group General --key ShowStatusBar Small --notify
  kwriteconfig6 --file dolphinrc --group General --key FilterBar false --notify
  kwriteconfig6 --file dolphinrc --group General --key ShowToolTips false --notify
  kwriteconfig6 --file dolphinrc --group DetailsMode --key IconSize 16 --notify
  kwriteconfig6 --file dolphinrc --group DetailsMode --key PreviewSize 64 --notify
  kwriteconfig6 --file dolphinrc --group DetailsMode --key ExpandableFolders false --notify
  kwriteconfig6 --file dolphinrc --group DetailsMode --key HighlightEntireRow true --notify
  kwriteconfig6 --file dolphinrc --group DetailsMode --key LeftPadding 8 --notify
  kwriteconfig6 --file dolphinrc --group DetailsMode --key RightPadding 8 --notify
  kwriteconfig6 --file dolphinrc --group MainWindow --key MenuBar Disabled --notify

  local view="${XDG_DATA_HOME:-$HOME/.local/share}/dolphin/view_properties/global/.directory"
  mkdir -p "$(dirname "$view")"
  if [ ! -e "$view" ]; then
    write_file "$view" <<'EOF'
[Dolphin]
GroupedSorting=false
PreviewsShown=true
SortFoldersFirst=true
SortOrder=0
SortRole=text
ViewMode=1
EOF
  fi
  log "Dolphin details view written"
}

# KOS 锁屏：ds2 背景、时钟+天气+歌词、密码框圆角不再做成胶囊。
# 只改 kscreenlocker greeter 的 QML；PAM/认证逻辑不动。
configure_kos_lockscreen() {
  local dir="$HOME/.local/share/plasma/shells/org.kos.desktop/contents/lockscreen"

  if [ ! -f "$dir/LockScreen.qml" ]; then
    log "KOS lock screen not installed; skipping its styling"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] write the KOS lock screen: ds2 background, 14px password corners, hidden calendar/dial"
    return 0
  fi

  install_file "$ASSET_DIR/wallpapers/ds2.png" "$dir/ds2.png"
  backup_file "$dir/LockScreen.qml"
  backup_file "$dir/LockWidgets.qml"

  python3 - "$dir/LockScreen.qml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
s = path.read_text()
if "property bool customWallpaper" not in s:
    s = s.replace("    property bool hasWallpaper: false",
                  "    property bool hasWallpaper: false\n"
                  "    // Use the KOS lock-screen wallpaper instead of the desktop wallpaper.\n"
                  "    property bool customWallpaper: true")
s = s.replace("    function syncWallpaperSource() {\n        if (!wallpaper)\n            return",
              "    function syncWallpaperSource() {\n"
              "        if (root.customWallpaper) {\n"
              "            root.wallpaperSource = \"\"\n"
              "            return\n"
              "        }\n"
              "        if (!wallpaper)\n            return")
s = s.replace("            visible: root.wallpaperSource != \"\"\n            source: root.wallpaperSource",
              "            visible: root.customWallpaper || root.wallpaperSource != \"\"\n"
              "            source: root.customWallpaper ? \"ds2.png\" : root.wallpaperSource")
s = s.replace("            wallpaper.z = -1\n        }",
              "            wallpaper.z = -1\n            wallpaper.visible = false\n        }")
s = s.replace("                readonly property int cornerRadius: Math.round(pane.height * 0.5)",
              "                readonly property int cornerRadius: Math.min(14, Math.round(pane.height * 0.5))")
path.write_text(s)
PY

  python3 - "$dir/LockWidgets.qml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
s = path.read_text()
if "Column {\n            spacing: 4\n            visible: false" not in s:
    s = s.replace("        Column {\n            spacing: 4\n",
                  "        Column {\n            spacing: 4\n            visible: false\n", 1)
if "Canvas {\n            id: dial\n            visible: false" not in s:
    s = s.replace("        Canvas {\n            id: dial\n",
                  "        Canvas {\n            id: dial\n            visible: false\n", 1)
path.write_text(s)
PY
  log "KOS lock screen styled: ds2 background, clock+weather+lyrics, rounded password box"
}


# Chrome 启动时会通过 KDE 的密钥服务（ksecretd）取 cookie 加密密钥；系统里还没有钱包时，
# 会弹「KDE 密码库服务 - 请求新建 kwallet」，点取消才能继续用。把 Chrome 换成自己的基础
# 存储（--password-store=basic），它就不再碰密钥服务，弹窗也就没了。
install_chrome_password_store_override() {
  local src="/usr/share/applications/google-chrome.desktop"
  local dst="$HOME/.local/share/applications/google-chrome.desktop"
  log "Keeping Chrome off the KDE wallet (stops the per-launch prompt)..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] create $dst (Exec gets --password-store=basic)"
    return 0
  fi
  if [ ! -f "$src" ]; then
    log "Chrome not installed; skipping the wallet override"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  backup_file "$dst"
  sed 's|^Exec=/usr/bin/google-chrome-stable|Exec=/usr/bin/google-chrome-stable --password-store=basic|' \
    "$src" > "$dst"
  if have kbuildsycoca6; then
    kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
  fi
  log "Chrome launcher updated (takes effect on next start)"
}
# VS Code 是另一个 Electron 应用，它自己也会去找 KDE keyring：钱包不存在时
# 每次启动都弹“OS keyring 不可用于加密”。和 Chrome 一样钉到 basic 存储，两层保险：
#   1. ~/.config/code-flags.conf —— /usr/bin/code 包装脚本启动时读
#   2. ~/.config/Code/User/argv.json —— VS Code 自己读的运行时参数（直接跑二进制也生效）
# 想改用钱包加密就把这两处删掉。
install_vscode_password_store_override() {
  local flags="$HOME/.config/code-flags.conf"
  local argv="$HOME/.config/Code/User/argv.json"
  log "Keeping VS Code off the KDE wallet (stops the keyring warning)..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] ensure $flags and $argv carry --password-store=basic"
    return 0
  fi
  if [ ! -e /usr/bin/code ] && ! have code; then
    log "VS Code not installed; skipping the keyring override"
    return 0
  fi

  if [ -f "$flags" ] && grep -qxF -- "--password-store=basic" "$flags"; then
    log "VS Code launcher flags already pinned"
  else
    backup_file "$flags"
    if [ -f "$flags" ]; then
      printf '%s\n' "--password-store=basic" >> "$flags"
    else
      mkdir -p "$(dirname "$flags")"
      write_file "$flags" <<'EOF'
# KDE 下没有可用的 keyring 时，Electron/VS Code 会反复弹
# “OS keyring 不可用于加密”。basic 存储不依赖钱包；想改用钱包加密就删掉这一行。
--password-store=basic
EOF
    fi
    log "VS Code launcher flags updated (takes effect on next start)"
  fi

  if [ -f "$argv" ]; then
    if grep -q '"password-store"' "$argv"; then
      log "VS Code argv.json already sets password-store"
    else
      warn "Please add \"password-store\": \"basic\" to $argv by hand (left untouched)"
    fi
    return 0
  fi
  mkdir -p "$(dirname "$argv")"
  write_file "$argv" <<'EOF'
// 由 KOS 安装器添加：KDE 环境下没有可用的 keyring，VS Code 会提示
// “你正在 KDE 环境中运行，但 OS keyring 不可用于加密”。
// 这里固定用 basic 存储；想改用钱包加密就删掉下面这一行。
{
	"password-store": "basic"
}
EOF
  log "VS Code argv.json written (takes effect on next start)"
}

install_desktop_config() {
  log "Writing desktop environment config (env / GTK / fonts)..."
  install_file "$CONFIG_DIR/environment/90-kos.conf" "$HOME/.config/environment.d/90-kos.conf"
  install_file "$CONFIG_DIR/gtk/settings.ini" "$HOME/.config/gtk-3.0/settings.ini"
  install_file "$CONFIG_DIR/gtk/settings.ini" "$HOME/.config/gtk-4.0/settings.ini"
  install_file "$CONFIG_DIR/fontconfig/fonts.conf" "$HOME/.config/fontconfig/fonts.conf"

  # 首次登录把主屏设成 1920x1080（安装器在 TTY 里改不了 Wayland 输出）
  install_file "$CONFIG_DIR/display/kos-display-1920x1080.sh" "$HOME/.local/bin/kos-display-1920x1080" 755
  install_file "$CONFIG_DIR/display/kos-display-1920x1080.desktop" "$HOME/.config/autostart/kos-display-1920x1080.desktop"
  enable_kos_theme_animation
  remove_kitty_no_decorations
  enable_kos_subtle_dock_reveal
  enable_frosted_kde_windows
  enable_kos_frosted_settings
  install_chrome_password_store_override
  install_vscode_password_store_override
  install_default_apps
  configure_kde_global_appearance
  configure_kos_motion
  configure_dolphin_layout
  configure_kos_lockscreen
}

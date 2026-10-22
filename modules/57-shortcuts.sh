#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# KDE 全局快捷键：
#   Win+Shift+C -> kitty -e term-menu
#   Alt+Enter   -> 打开 kitty
#   Alt+Q       -> 关闭当前窗口（KWin Window Close）
#   Alt+W       -> 打开全屏壁纸预览
# 使用 KGlobalAccel 的 command shortcut desktop 文件，不依赖 KOS 私有快捷键。

install_wallpaper_shortcut() {
  log "配置 Alt+W 打开全屏壁纸预览..."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 写入 kos-wallpaper-preview.desktop 并设置 Alt+W"
    return 0
  fi
  if ! have kwriteconfig6; then
    warn "缺少 kwriteconfig6，跳过壁纸快捷键"
    return 0
  fi

  backup_file "$HOME/.config/kglobalshortcutsrc"
  # 清理上一版误用 KOS Settings id 的入口，避免下一次登录出现两个 Alt+W。
  rm -f "$HOME/.local/share/applications/kos-settings-wallpaper.desktop"
  kwriteconfig6 --file kglobalshortcutsrc --group services --group kos-settings-wallpaper.desktop --key _launch --delete --notify >/dev/null 2>&1 || true
  write_file "$HOME/.local/bin/kos-wallpaper-preview" <<'SCRIPT'
#!/usr/bin/env bash
# Open the KOS fullscreen wallpaper preview for the current wallpaper.
set -euo pipefail
snapshot=$(qs -c kos ipc call wallpaper-settings snapshot 2>/dev/null) || exit 1
exec python3 - "$snapshot" <<'PY'
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

try:
    state = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)

image = str(state.get("image") or "")
raw_catalog = state.get("previewCatalog") or "[]"
try:
    catalog = json.loads(raw_catalog) if isinstance(raw_catalog, str) else list(raw_catalog)
except Exception:
    catalog = []

# The Shell's snapshot only has the active image until Settings opens its
# gallery; merge the managed gallery so the full-screen grid is complete.
data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
gallery_dir = data_home / "kos" / "gallery"
extensions = {".png", ".jpg", ".jpeg", ".webp", ".avif"}
if gallery_dir.is_dir():
    for path in sorted(gallery_dir.iterdir()):
        if path.is_file() and path.suffix.lower() in extensions:
            value = str(path)
            if value not in catalog:
                catalog.append(value)
if image and image not in catalog:
    catalog.insert(0, image)
if not image and catalog:
    image = catalog[0]
if not image:
    sys.exit(1)

qs = shutil.which("qs") or "qs"
# qs ipc splits comma-separated argv; pass the catalog as a JSON string
# whose commas are escaped, then KOS parses it back into a list.
catalog_arg = json.dumps(json.dumps(catalog, separators=(",", ":")),
                         ensure_ascii=False).replace(",", "\\u002c")
subprocess.run([qs, "-c", "kos", "ipc", "call", "wallpaper-settings",
                "previewImage", image, catalog_arg], check=False)
PY
SCRIPT
  chmod 755 "$HOME/.local/bin/kos-wallpaper-preview"

  write_file "$HOME/.local/share/applications/kos-wallpaper-preview.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=KOS Wallpaper Preview
Comment=Open the fullscreen wallpaper preview
Exec=$HOME/.local/bin/kos-wallpaper-preview
Icon=preferences-desktop-wallpaper
Terminal=false
NoDisplay=true
StartupNotify=true
X-KDE-GlobalAccel-CommandShortcut=true
EOF

  kwriteconfig6 --file kglobalshortcutsrc --group services --group kos-wallpaper-preview.desktop --key _launch "Alt+W" --notify
  if have kbuildsycoca6; then
    kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
  fi
  log "Alt+W → 全屏壁纸预览"
}

configure_launcher_shortcuts() {
  log "配置启动器快捷键（Win / Win+O）..."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 写入 KOS 快捷方式覆盖与 plasmashell 的 Meta 禁用"
    return 0
  fi

  if have kwriteconfig6; then
    backup_file "$HOME/.config/kglobalshortcutsrc"
    # KDE 的 Meta 单键会抢在 KOS 启动器之前打开 Plasma 应用菜单，先释放它。
    kwriteconfig6 --file kglobalshortcutsrc --group plasmashell --key "activate application launcher" "none" --notify
    # 立即让 KGlobalAccel 释放已被 KDE 占用的 Meta 单键；下次登录会从配置恢复。
    qdbus6 org.kde.kglobalaccel /kglobalaccel org.kde.KGlobalAccel.unregister plasmashell "activate application launcher" >/dev/null 2>&1 || true
    qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
  fi

  local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/kos/shortcuts"
  local config="$state_dir/config.json"
  mkdir -p "$state_dir"
  python3 - "$config" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
data = {"version": 1, "overrides": {}}
if path.exists():
    try:
        loaded = json.loads(path.read_text())
        if isinstance(loaded, dict):
            data.update(loaded)
    except Exception:
        pass
overrides = data.get("overrides")
if not isinstance(overrides, dict):
    overrides = {}
overrides["net.local.kos-launcher"] = "Meta"
overrides["net.local.kos-window-switcher"] = "Meta+O"
data["version"] = 1
data["overrides"] = overrides
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
  log "Win → Dock 应用启动器，Win+O → KOS 快速搜索/启动器"
}

install_vellum_shortcuts() {
  log "配置 Vellum 截图快捷键（Print / Ctrl+Print）..."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 写入 vellum-region/long.desktop 并设置 Print / Ctrl+Print"
    return 0
  fi
  if ! have kwriteconfig6; then
    warn "缺少 kwriteconfig6，跳过 Vellum 快捷键"
    return 0
  fi

  backup_file "$HOME/.config/kglobalshortcutsrc"
  write_file "$HOME/.local/share/applications/vellum-region.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Vellum Region Screenshot
Comment=Capture a region with Vellum
Exec=$HOME/.local/bin/vellum region
Icon=ai.vellum
Terminal=false
NoDisplay=true
StartupNotify=true
X-KDE-GlobalAccel-CommandShortcut=true
EOF

  write_file "$HOME/.local/share/applications/vellum-long.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Vellum Long Screenshot
Comment=Start or finish a scrolling screenshot with Vellum
Exec=$HOME/.local/bin/vellum long
Icon=ai.vellum
Terminal=false
NoDisplay=true
StartupNotify=true
X-KDE-GlobalAccel-CommandShortcut=true
EOF

  kwriteconfig6 --file kglobalshortcutsrc --group services --group vellum-region.desktop --key _launch "Print" --notify
  kwriteconfig6 --file kglobalshortcutsrc --group services --group vellum-long.desktop --key _launch "Ctrl+Print" --notify
  if have kbuildsycoca6; then
    kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
  fi
  log "Vellum：Print → 区域截图，Ctrl+Print → 长截图"
}

configure_keyboard_repeat() {
  log "配置键盘重复延迟/速率（250ms / 50Hz）..."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 写入 kcminputrc：Keyboard.RepeatDelay=250，RepeatRate=50"
    return 0
  fi
  if ! have kwriteconfig6; then
    warn "缺少 kwriteconfig6，跳过键盘重复设置"
    return 0
  fi

  backup_file "$HOME/.config/kcminputrc"
  kwriteconfig6 --file kcminputrc --group Keyboard --key RepeatDelay "250" --notify
  kwriteconfig6 --file kcminputrc --group Keyboard --key RepeatRate "50" --notify

  # 当前会话有 KWin 时立即重读；安装器里 KWin 尚未启动，失败可忽略。
  if have qdbus6; then
    qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
  fi
  log "键盘重复：延迟 250ms，速率 50 次/秒"
}

install_kde_shortcuts() {
  log "配置 KDE 快捷键（term-menu / 终端 / btop / fuzzel / 关闭窗口）..."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 写入 term-menu / kitty-terminal / btop / fuzzel-launcher 的 desktop 并设置 KGlobalAccel"
    return 0
  fi
  if ! have kwriteconfig6; then
    warn "缺少 kwriteconfig6，跳过 KDE 快捷键"
    return 0
  fi

  backup_file "$HOME/.config/kglobalshortcutsrc"

  write_file "$HOME/.local/share/applications/term-menu.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=KOS Maintenance
Comment=Open the maintenance menu
Exec=/usr/bin/kitty --title "KOS Maintenance" -e $HOME/bin/term-menu
Icon=utilities-terminal
Terminal=false
NoDisplay=true
StartupNotify=true
X-KDE-GlobalAccel-CommandShortcut=true
EOF

  write_file "$HOME/.local/share/applications/kitty-terminal.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Terminal
Comment=Open kitty terminal
Exec=/usr/bin/kitty
Icon=utilities-terminal
Terminal=false
NoDisplay=true
StartupNotify=true
X-KDE-GlobalAccel-CommandShortcut=true
EOF

  kwriteconfig6 --file kglobalshortcutsrc --group services --group term-menu.desktop --key _launch "Meta+Shift+C" --notify
  kwriteconfig6 --file kglobalshortcutsrc --group services --group kitty-terminal.desktop --key _launch "Alt+Return" --notify
  kwriteconfig6 --file kglobalshortcutsrc --group services --group btop.desktop --key _launch "Meta+M" --notify
  kwriteconfig6 --file kglobalshortcutsrc --group services --group fuzzel-launcher.desktop --key _launch "Ctrl+M" --notify
  kwriteconfig6 --file kglobalshortcutsrc --group kwin --key "Window Close" "Alt+Q,Alt+F4,关闭窗口" --notify

  if have kbuildsycoca6; then
    kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
  fi
  log "KDE 快捷键已写入（注销/重新登录后由 KGlobalAccel 生效）"
}

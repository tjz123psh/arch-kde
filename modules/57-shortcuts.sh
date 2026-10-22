#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# KDE 全局快捷键：
#   Win+Shift+C -> kitty -e term-menu
#   Alt+Enter   -> 打开 kitty
#   Alt+Q       -> 关闭当前窗口（KWin Window Close）
# 使用 KGlobalAccel 的 command shortcut desktop 文件，不依赖 KOS 私有快捷键。

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

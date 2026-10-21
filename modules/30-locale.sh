#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

setup_locale() {
  log "配置中文 locale（系统英文 / 桌面中文: $LOCALE_MODE）..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 修改 /etc/locale.gen 并运行 locale-gen"
    log "[dry-run] 写 /etc/locale.conf"
    log "[dry-run] 写 ~/.config/plasma-localerc（KDE 界面语言 zh_CN）"
    return 0
  fi
  backup_file /etc/locale.gen
  backup_file /etc/locale.conf
  sudo sed -i 's/^#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
  sudo sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
  sudo locale-gen

  if [ "$LOCALE_MODE" = zh ]; then
    sudo_write_file /etc/locale.conf <<'EOF'
LANG=zh_CN.UTF-8
EOF
  else
    sudo_write_file /etc/locale.conf <<'EOF'
LANG=en_US.UTF-8
EOF
  fi
  # KDE 界面语言（与系统 locale 解耦）：plasma-localerc 的 Translations 决定 KDE/Qt 翻译。
  # 默认系统英文、桌面中文（和本机基线一致）；--locale zh 时格式也切中文。
  local formats="zh_CN.UTF-8"
  if [ "$LOCALE_MODE" = en ]; then formats="en_US.UTF-8"; fi
  write_file "$HOME/.config/plasma-localerc" <<EOF
[Formats]
LANG=$formats

[Translations]
LANGUAGE=zh_CN
EOF
  log "locale 完成（KDE 界面语言: zh_CN，格式: $formats）"
}

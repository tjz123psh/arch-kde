#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

setup_locale() {
  log "配置中文 locale（系统英文 / 桌面中文: $LOCALE_MODE）..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 修改 /etc/locale.gen 并运行 locale-gen"
    log "[dry-run] 写 /etc/locale.conf"
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
  log "locale 完成"
}

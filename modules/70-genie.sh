#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# genie 最小化/还原动效：构建归档插件并写 kwinrc。
# 失败时回退到 KWin 自带 Magic Lamp（警告，不中断安装）。

build_genie_effect() {
  log "构建 genie 动效（原生 KWin 6.8 插件）..."

  # 动效是可选项，但写 kwinrc 依赖 kconfig 的 kwriteconfig6。缺它的时候必须
  # 在动手前就退出：否则第一次 kwriteconfig6 调用就是 command not found，
  # set -e 会把整个安装停在"可选动效"上（干净容器里实测过）。
  if ! have kwriteconfig6; then
    warn "缺少 kwriteconfig6（kconfig 包），跳过 genie：插件不装、kwinrc 不动"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] $ASSET_DIR/genie/build.sh"
    log "[dry-run] kwinrc: genie 开 / magiclamp 关 / Duration=700 / GridResolution=50"
    return 0
  fi

  if "$ASSET_DIR/genie/build.sh"; then
    kwriteconfig6 --file kwinrc --group Plugins --key kwin4_effect_linuxmacosgenieEnabled true
    kwriteconfig6 --file kwinrc --group Plugins --key libkwin4_effect_yetanothermagiclampEnabled false
    kwriteconfig6 --file kwinrc --group Plugins --key magiclampEnabled false
    kwriteconfig6 --file kwinrc --group Effect-LinuxMacOSGenie --key Duration 700
    kwriteconfig6 --file kwinrc --group Effect-LinuxMacOSGenie --key GridResolution 50
    log "genie 已启用（700ms）"
  else
    warn "genie 构建失败，回退 Magic Lamp"
    kwriteconfig6 --file kwinrc --group Plugins --key kwin4_effect_linuxmacosgenieEnabled false
    kwriteconfig6 --file kwinrc --group Plugins --key magiclampEnabled true
  fi
}

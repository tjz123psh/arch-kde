#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# 可选：清理上一个桌面（linux-macos）留下的专属包。
#
# 这些包不是 arch-kde/KOS 需要的，也不应该被新安装器装进来；但 pacman 不会
# 自动卸载已经装上的包，所以在被旧桌面污染过的系统上需要显式加
# --clean-old-desktop 才会删。默认不动任何包。
#
# 只列旧桌面专属、且新桌面不依赖的包；VS Code / pi / Chrome 等常用软件不在此列。

OLD_DESKTOP_PKGS="
aurorae
breeze-gtk
kvantum
sassc
optipng
fuzzel
plasma6-applets-window-title
kwin-effect-rounded-corners-git
kwin-effects-better-blur-dx
latte-dock-ng
crystal-dock-git
"

cleanup_old_desktop() {
  if [ "${CLEAN_OLD:-0}" -ne 1 ]; then
    return 0
  fi
  local p installed=()
  for p in $OLD_DESKTOP_PKGS; do
    if pkg_installed "$p"; then installed+=("$p"); fi
  done
  if [ ${#installed[@]} -eq 0 ]; then
    log "旧桌面清理：没有发现旧桌面专属包"
    return 0
  fi
  log "旧桌面清理：发现 ${#installed[@]} 个旧桌面专属包：${installed[*]}"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] sudo pacman -Rns --noconfirm ${installed[*]}"
    return 0
  fi
  confirm "卸载这些旧桌面专属包？" || { warn "已跳过旧桌面清理"; return 0; }
  if sudo pacman -Rns --noconfirm "${installed[@]}"; then
    log "旧桌面包已卸载"
  else
    warn "卸载旧桌面包失败，可稍后手动处理：${installed[*]}"
  fi
}

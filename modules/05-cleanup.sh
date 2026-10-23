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

# aurorae 是 kwin 的运行依赖，不能当旧桌面包删；放在这里会让整条
# pacman -Rns 事务失败，所以单独排除。
OLD_DESKTOP_PKGS="
breeze-gtk
kvantum
sassc
optipng
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
  local p installed=() required
  for p in $OLD_DESKTOP_PKGS; do
    pkg_installed "$p" || continue
    # 仍被其他包依赖的不能删（例如 KWin 装饰引擎）；先跳过，避免
    # pacman -Rns 整条事务回滚，留下一个都没删掉的假成功。
    required=$(pacman -Qi "$p" 2>/dev/null | sed -n 's/^Required By *: *//p')
    if [ -n "$required" ] && [ "$required" != "None" ]; then
      warn "Old-desktop cleanup: skipping $p (still required by: $required)"
      continue
    fi
    installed+=("$p")
  done
  if [ ${#installed[@]} -eq 0 ]; then
    log "Old-desktop cleanup: no leftover packages found"
    return 0
  fi
  log "Old-desktop cleanup: found ${#installed[@]} leftover package(s): ${installed[*]}"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] sudo pacman -Rns --noconfirm ${installed[*]}"
    return 0
  fi
  confirm "Remove these leftover packages?" || { warn "Old-desktop cleanup skipped"; return 0; }
  if sudo pacman -Rns --noconfirm "${installed[@]}"; then
    log "Old-desktop packages removed"
  else
    warn "Failed to remove old-desktop packages; handle them manually later: ${installed[*]}"
  fi
}

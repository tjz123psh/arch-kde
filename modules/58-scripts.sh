#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# 用户常驻工具：maintenance / package / share 三组脚本。
# 源文件在 assets/scripts，安装到 ~/scripts，
# 再把命令软链接到 ~/bin；这样脚本更新不会丢用户配置。

install_user_scripts() {
  local src="$ASSET_DIR/scripts"
  local dest="$HOME/scripts"
  local bin="$HOME/bin"
  local f name

  if [ ! -d "$src" ]; then
    warn "找不到脚本资源：$src"
    return 1
  fi

  log "安装维护 / 包管理脚本..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 复制 $src -> $dest"
    log "[dry-run] 链接 term-menu / pac / pacr / pacd / gsudo 及维护工具到 $bin"
    return 0
  fi

  mkdir -p "$dest" "$bin"
  if ! cp -a "$src/." "$dest/"; then
    warn "复制脚本到 $dest 失败"
    return 1
  fi

  link_user_script() {
    local cmd="$1" target="$2" link="$bin/$1"
    if [ -L "$link" ] && [ "$(readlink -f "$link" 2>/dev/null || true)" = "$(readlink -f "$target" 2>/dev/null || true)" ]; then
      return 0
    fi
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      warn "跳过 $cmd：$link 已存在且不是软链接"
      return 0
    fi
    ln -sfn "$target" "$link"
  }

  # maintenance：统一菜单 + 所有顶层工具；run 是测试入口，不装到 PATH。
  for f in "$dest"/maintenance/*; do
    if [ ! -f "$f" ] || [ ! -x "$f" ]; then continue; fi
    name=$(basename "$f")
    [ "$name" = "run" ] && continue
    link_user_script "$name" "$f"
  done

  # package：pac / pacr / pacd；lib 与 share 由相对路径定位。
  for name in pac pacr pacd; do
    link_user_script "$name" "$dest/package/$name"
  done

  # desktop：gsudo 使用同目录的 fuzzel-askpass（内部脚本不单独暴露命令）。
  link_user_script gsudo "$dest/desktop/gsudo"

  log "常驻脚本已安装：term-menu、pac、pacr、pacd、gsudo"
}

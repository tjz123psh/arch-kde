#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# 用户常驻工具：maintenance / package / desktop / media / kos 五组链到 ~/bin，
# share 只随目录复制、不建命令（被 maintenance 脚本按相对路径读取）。
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
    log "[dry-run] 链接 term-menu / pac / pacr / pacd / gsudo / b23 / kos 及维护工具到 $bin"
    log "[dry-run] write ~/.local/share/applications/kos-update.desktop 与 kos-update-check.{service,timer}，并启用定时器"
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

  # desktop：除 fuzzel-askpass（gsudo 的内部助手）外，全部链到 ~/bin。
  # 以后往 assets/scripts/desktop 里加脚本，这里不用再改。
  for f in "$dest"/desktop/*; do
    if [ ! -f "$f" ] || [ ! -x "$f" ]; then continue; fi
    name=$(basename "$f")
    [ "$name" = "fuzzel-askpass" ] && continue
    link_user_script "$name" "$f"
  done

  # media：b23（B 站链接 -> mpv）。规则同 desktop：目录里的可执行脚本都链到 ~/bin。
  for f in "$dest"/media/*; do
    if [ ! -f "$f" ] || [ ! -x "$f" ]; then continue; fi
    name=$(basename "$f")
    link_user_script "$name" "$f"
  done

  # kos：KOS 桌面更新器（update.sh 链成 ~/bin/kos；tests/ 只是回归测试，不链）。
  if [ -x "$dest/kos/update.sh" ]; then
    link_user_script kos "$dest/kos/update.sh"
  else
    warn "找不到 $dest/kos/update.sh，跳过 kos 命令"
  fi
  install_kos_updater_extras

  log "常驻脚本已安装：maintenance 工具、pac/pacr/pacd、gsudo/shortcuts/record-menu、b23、kos（desktop / media 下的可执行脚本都会链到 ~/bin）"
}

# kos 命令之外的两块入口：桌面启动器与每日检查定时器。
# 桌面的 Exec 必须写绝对路径（Desktop Entry 不展开 ~ / 环境变量），所以模板里的
# @HOME@ 在安装时替换成本机 HOME，而不是在仓库里写死用户名。
install_kos_updater_extras() {
  local src="$ASSET_DIR/config/kos"
  local desktop="$HOME/.local/share/applications/kos-update.desktop"
  local unit_dir="$HOME/.config/systemd/user"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] write $desktop and $unit_dir/kos-update-check.{service,timer}"
    log "[dry-run] systemctl --user enable --now kos-update-check.timer"
    return 0
  fi
  if [ ! -f "$src/kos-update.desktop" ]; then
    warn "缺少 $src/kos-update.desktop；kos 命令可用，但没有桌面启动器"
  else
    mkdir -p "$(dirname "$desktop")"
    sed "s|@HOME@|$HOME|g" "$src/kos-update.desktop" | write_file "$desktop"
  fi

  install_file "$src/kos-update-check.service" "$unit_dir/kos-update-check.service"
  install_file "$src/kos-update-check.timer" "$unit_dir/kos-update-check.timer"
  if have systemctl; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if systemctl --user enable --now kos-update-check.timer; then
      log "KOS 更新检查定时器已启用（每日 12:00，只检查不安装）"
    else
      warn "无法启用 kos-update-check.timer；登录桌面后运行 systemctl --user enable --now kos-update-check.timer"
    fi
  fi
}

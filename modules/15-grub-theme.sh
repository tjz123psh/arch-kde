#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# GRUB 启动菜单主题（Elegant-mojave-window-left-dark）
# 背景：虚拟机验收时发现安装器完全没管 GRUB，默认只有 starfield。
# 这里把主题装进 /boot/grub/themes，把 GRUB_THEME/超时/分辨率写进 /etc/default/grub，
# 最后用 grub-mkconfig 重新生成 grub.cfg。改前备份，失败只 warn 不中断安装。

setup_grub_theme() {
  local theme_name="Elegant-mojave-window-left-dark"
  local theme_src="$ASSET_DIR/grub-theme"
  local theme_dir="/boot/grub/themes/$theme_name"
  local grub_default=/etc/default/grub
  local grub_cfg=/boot/grub/grub.cfg

  if [ ! -f "$grub_cfg" ] && ! command -v grub-mkconfig >/dev/null 2>&1; then
    log "GRUB not detected, skipping GRUB theme"
    return 0
  fi
  if [ ! -f "$theme_src/theme.txt" ]; then
    warn "GRUB theme assets missing: $theme_src/theme.txt"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] install GRUB theme $theme_name, update /etc/default/grub, run grub-mkconfig"
    return 0
  fi

  backup_file "$grub_default"
  backup_file "$grub_cfg"

  log "安装 GRUB 主题：$theme_name"
  # /boot 可能是 vfat，不能放符号链接：用 -L 跟随链接复制。
  # 不再 rm -rf 整个目录：用户可能把 background.jpg 换成了自己的图，删了没有备份能救。
  # 原地覆盖仓库里的文件即可，主题用不到的旧文件留着也无害。
  sudo mkdir -p "$theme_dir"
  if ! sudo cp -rL "$theme_src/." "$theme_dir/"; then
    warn "复制 GRUB 主题文件失败"
    return 0
  fi

  grub_set_kv() {
    local key="$1" value="$2"
    if sudo grep -qE "^[#[:space:]]*$key=" "$grub_default" 2>/dev/null; then
      sudo sed -i -E "s|^[#[:space:]]*$key=.*|$key=$value|" "$grub_default"
    else
      printf '%s=%s\n' "$key" "$value" | sudo tee -a "$grub_default" >/dev/null
    fi
  }

  grub_set_kv GRUB_THEME "\"/boot/grub/themes/$theme_name/theme.txt\""
  grub_set_kv GRUB_TIMEOUT "5"
  grub_set_kv GRUB_TIMEOUT_STYLE "menu"
  grub_set_kv GRUB_GFXMODE "1920x1080,auto"

  # 键盘：旧版本往 GRUB_PRELOAD_MODULES 里塞了 "usb usb_keyboard"。笔记本内置键盘是
  # AT/PS2（不是 USB），UEFI 下再加载 usb_keyboard 会把输入抢掉，表现就是菜单里
  # 上下键完全没反应、只能等超时。这里把它换成 at_keyboard（对内置键盘有效），
  # 用户自己改过的其它模块保持不动。
  local preload value new_preload
  preload=$(sudo grep -E '^GRUB_PRELOAD_MODULES=' "$grub_default" 2>/dev/null | head -n1 || true)
  case "$preload" in
    *usb_keyboard*)
      # 只摘掉 usb_keyboard，其余模块原样保留（part_gpt / part_msdos / lvm / cryptodisk /
      # 用户自己加的）。以前是整串重写成固定值 "at_keyboard"，加密根分区那种机器
      # 重跑一次就可能少掉 cryptodisk、进不了系统，所以这里按"词"处理。
      value=$(printf '%s' "$preload" | sed -E 's/^[^=]*=//; s/^"//; s/"$//')
      new_preload=$(printf '%s\n' "$value" | tr -s ' ' '\n' | grep -vx 'usb_keyboard' | paste -sd' ' - || true)
      case " $new_preload " in
        *" at_keyboard "*) ;;
        *) new_preload="${new_preload:+$new_preload }at_keyboard" ;;
      esac
      log "GRUB_PRELOAD_MODULES 含 usb_keyboard（会抢走内置键盘），改成：$new_preload"
      grub_set_kv GRUB_PRELOAD_MODULES "\"$new_preload\""
      ;;
  esac

  log "重新生成 grub.cfg ..."
  if ! sudo grub-mkconfig -o "$grub_cfg"; then
    warn "grub-mkconfig 失败，GRUB 主题可能未生效"
    return 0
  fi
  sudo sync
  if sudo grep -q "themes/$theme_name" "$grub_cfg"; then
    log "GRUB 主题已生效：$theme_dir"
  else
    warn "grub.cfg 里没有找到主题路径，请检查 /etc/default/grub"
  fi
}

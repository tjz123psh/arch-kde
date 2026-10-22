#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# SDDM 主题：SilentSDDM（第三方，AUR: sddm-silent-theme）
#   https://github.com/uiriansan/SilentSDDM
# 要求 SDDM >= 0.21、Qt >= 6.5；Arch 的 sddm 0.21 满足。

# 登录页外观：Silent 主题的 configs/default.conf；登录/锁屏共用当前壁纸，
# 头像同步到 SDDM，登录框改为圆角半透明。认证逻辑完全不动。
customize_sddm_theme() {
  local theme=/usr/share/sddm/themes/silent
  local cfg="$theme/configs/default.conf"
  local tmp
  if [ ! -f "$cfg" ]; then
    warn "找不到 Silent 主题配置：$cfg"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 写入 Silent 登录页背景/模糊/头像配置"
    return 0
  fi

  backup_file "$cfg"
  tmp=$(mktemp)
  cp "$cfg" "$tmp"
  python3 - "$tmp" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
sections = {}
order = []
cur = None
for line in lines:
    s = line.strip()
    if s.startswith("[") and s.endswith("]"):
        cur = s[1:-1]
        if cur not in sections:
            sections[cur] = {}
            order.append(cur)
    elif "=" in line and cur:
        k, v = line.split("=", 1)
        sections[cur][k.strip()] = v.strip()

def set_key(section, key, value):
    if section not in sections:
        sections[section] = {}
        order.append(section)
    sections[section][key] = str(value)

set_key("LoginScreen", "background", '"kos-wallpaper.png"')
set_key("LoginScreen", "blur", "16")
set_key("LoginScreen", "brightness", "-0.25")
set_key("LoginScreen", "saturation", "0.05")
set_key("LoginScreen.LoginArea.Avatar", "shape", '"circle"')
set_key("LoginScreen.LoginArea.Avatar", "active-size", "112")
set_key("LoginScreen.LoginArea.Avatar", "active-border-size", "2")
set_key("LoginScreen.LoginArea.Avatar", "active-border-color", '"#FFFFFF"')
set_key("LoginScreen.LoginArea.PasswordInput", "width", "240")
set_key("LoginScreen.LoginArea.PasswordInput", "height", "34")
set_key("LoginScreen.LoginArea.PasswordInput", "background-opacity", "0.22")
set_key("LoginScreen.LoginArea.PasswordInput", "border-size", "1")
set_key("LoginScreen.LoginArea.PasswordInput", "border-color", '"#FFFFFF"')
set_key("LoginScreen.LoginArea.PasswordInput", "border-radius-left", "12")
set_key("LoginScreen.LoginArea.PasswordInput", "border-radius-right", "12")
set_key("LoginScreen.LoginArea.LoginButton", "background-opacity", "0.22")
set_key("LoginScreen.LoginArea.LoginButton", "active-background-opacity", "0.35")
set_key("LoginScreen.LoginArea.LoginButton", "border-radius-left", "12")
set_key("LoginScreen.LoginArea.LoginButton", "border-radius-right", "12")
set_key("LockScreen", "background", '"kos-wallpaper.png"')
set_key("LockScreen", "blur", "28")
set_key("LockScreen", "brightness", "-0.20")
set_key("LockScreen", "saturation", "0.05")
set_key("LockScreen.Clock", "position", '"top-center"')
set_key("LockScreen.Clock", "font-size", "64")
set_key("LockScreen.Date", "locale", '"zh_CN"')
set_key("LockScreen.Message", "text", '"按任意键继续"')
out = []
for sec in order:
    out.append(f"[{sec}]")
    for k, v in sections[sec].items():
        out.append(f"{k} = {v}")
    out.append("")
path.write_text("\n".join(out).rstrip() + "\n")
PY
  if [ -f "$ASSET_DIR/wallpapers/樱吹雪.png" ]; then
    sudo_run install -Dm644 "$ASSET_DIR/wallpapers/樱吹雪.png" "$theme/backgrounds/kos-wallpaper.png" || warn "复制 SDDM 壁纸失败"
  fi
  if [ -f "$HOME/.face" ]; then
    sudo_run install -Dm644 "$HOME/.face" "/usr/share/sddm/faces/$(id -un).face.icon" || warn "写入 SDDM 头像失败"
  fi
  sudo_run install -Dm644 "$tmp" "$cfg" || warn "写入 SDDM 主题配置失败"
  rm -f "$tmp"
  log "Silent 登录页已应用背景 / 模糊 / 头像 / 圆角登录框"
}

setup_sddm_theme() {
  if [ "$NO_SDDM_THEME" -eq 1 ]; then
    log "跳过 SDDM 主题（--no-sddm-theme）"
    return 0
  fi
  if [ "$NO_AUR" -eq 1 ]; then
    warn "SDDM 主题走 AUR，已给 --no-aur，跳过"
    return 0
  fi

  log "安装 SDDM 主题依赖..."
  local p missing=()
  for p in sddm qt6-svg qt6-virtualkeyboard qt6-multimedia qt6-imageformats; do
    pkg_installed "$p" || missing+=("$p")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    sudo_run pacman -S --needed --noconfirm "${missing[@]}"
  fi

  log "安装 sddm-silent-theme（AUR）"
  if ! run "$AUR_CMD" -S --needed --noconfirm sddm-silent-theme; then
    warn "SilentSDDM 安装失败，保留现有登录主题"
    return 0
  fi

  log "写入 /etc/sddm.conf.d/90-silent.conf"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 写 sddm 配置（Current=silent）"
    return 0
  fi
  sudo mkdir -p /etc/sddm.conf.d
  sudo tee /etc/sddm.conf.d/90-silent.conf >/dev/null <<'CONF'
[General]
InputMethod=qtvirtualkeyboard
GreeterEnvironment=QML2_IMPORT_PATH=/usr/share/sddm/themes/silent/components/,QT_IM_MODULE=qtvirtualkeyboard

[Theme]
Current=silent
CONF
  customize_sddm_theme
  log "SDDM 主题已切换到 silent（可到主题目录跑 ./test.sh 预览）"
}

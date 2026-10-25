#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# SDDM 主题：SilentSDDM（第三方，AUR: sddm-silent-theme）
#   https://github.com/uiriansan/SilentSDDM
# 要求 SDDM >= 0.21、Qt >= 6.5；Arch 的 sddm 0.21 满足。


# SDDM 实际会用哪个主题：/etc/sddm.conf.d/*.conf 按文件名排序、后读的覆盖先读的，
# /etc/sddm.conf 优先级更高（会盖掉 conf.d）。只解析 [Theme] 段里的 Current=。
sddm_effective_theme() {
  local f v current=""
  if [ -d /etc/sddm.conf.d ]; then
    while IFS= read -r f; do
      v=$(awk -F= '/^\[Theme\]/{t=1;next} /^\[/{t=0} t && $1=="Current"{gsub(/[ \t]/,"",$2);c=$2} END{print c}' "$f" 2>/dev/null || true)
      [ -n "$v" ] && current="$v"
    done < <(find /etc/sddm.conf.d -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort)
  fi
  if [ -f /etc/sddm.conf ]; then
    v=$(awk -F= '/^\[Theme\]/{t=1;next} /^\[/{t=0} t && $1=="Current"{gsub(/[ \t]/,"",$2);c=$2} END{print c}' /etc/sddm.conf 2>/dev/null || true)
    [ -n "$v" ] && current="$v"
  fi
  printf '%s\n' "$current"
}

# 登录头像：用户自备 ~/.face 优先；没有就用仓库里的默认头像（assets/avatar/default.png）。
# 三处同步：~/.face（Plasma 认）、/usr/share/sddm/faces/<user>.face.icon（SDDM 认）、
# /var/lib/AccountsService/icons/<user> + users 文件里的 Icon=（KDE 用户页 / 登录页认）。
install_user_avatar() {
  local user face asset
  user=$(id -un)
  face="$HOME/.face"
  asset="$ASSET_DIR/avatar/default.png"

  if [ ! -f "$face" ] && [ -f "$asset" ]; then
    install -Dm644 "$asset" "$face" || { warn "写入 ~/.face 失败"; return 0; }
    install -Dm644 "$asset" "$HOME/.face.icon" || true
  fi
  if [ ! -f "$face" ]; then
    warn "没有可用的头像（缺 ~/.face 和 assets/avatar/default.png）"
    return 0
  fi

  sudo_run install -Dm644 "$face" "/usr/share/sddm/faces/$user.face.icon" || warn "写入 SDDM 头像失败"
  sudo_run install -Dm644 "$face" "/var/lib/AccountsService/icons/$user" || warn "写入 AccountsService 头像失败"

  sudo mkdir -p /var/lib/AccountsService/users 2>/dev/null || true
  sudo python3 - "$user" <<'PY' 2>/dev/null || warn "更新 AccountsService 用户配置失败"
from pathlib import Path
import sys

user = sys.argv[1]
p = Path("/var/lib/AccountsService/users") / user
lines = p.read_text().splitlines() if p.exists() else []
out, inside = [], False
for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        inside = stripped == "[User]"
        out.append(line)
        continue
    if inside and stripped.startswith("Icon="):
        out.append("Icon=/var/lib/AccountsService/icons/" + user)
        continue
    out.append(line)
if not any(l.strip() == "[User]" for l in out):
    out.append("[User]")
if not any(l.strip().startswith("Icon=") for l in out):
    out.append("Icon=/var/lib/AccountsService/icons/" + user)
p.write_text("\n".join(out).rstrip() + "\n")
PY
  log "登录头像已安装（$user）"
}

# 登录页外观：Silent 主题的 configs/default.conf；登录/锁屏共用当前壁纸，
# 头像同步到 SDDM，登录框改为圆角半透明。认证逻辑完全不动。
customize_sddm_theme() {
  # 定制写在 /etc 下的自管副本里（setup_sddm_theme 负责从 /usr/share 复制过来）：
  # /usr/share 那份归 sddm-silent-theme 包，升级时会被 pacman 直接覆盖。
  local theme=/etc/sddm/themes/silent
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
  install_user_avatar
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

  # 文件名要排在所有 *.conf 之后（z > k），否则 KDE 写的 kde_settings.conf 会把
  # Current 盖回去——那正是“装了主题却还是默认登录页”的常见原因。
  log "写入 /etc/sddm.conf.d/zz-kos-silent.conf"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 复制 /usr/share/sddm/themes/silent -> /etc/sddm/themes/silent 并写 sddm 配置"
    return 0
  fi

  # 把主题整份复制到 /etc/sddm/themes/silent，让登录页定制活过包升级：
  # /usr/share/sddm/themes/silent 归 sddm-silent-theme 包所有，而定制写在主题目录里的
  # configs/default.conf。复制一份我们自己的、把 ThemeDir 指到 /etc 后，包升级只动
  # /usr/share 那份，背景/圆角/头像设置就不会被 pacman 悄悄抹掉。
  local src_theme=/usr/share/sddm/themes/silent
  if [ ! -f "$src_theme/Main.qml" ]; then
    warn "找不到 $src_theme/Main.qml，跳过登录页定制"
    return 0
  fi
  log "复制登录主题到 /etc/sddm/themes/silent（自管副本）..."
  sudo mkdir -p /etc/sddm/themes/silent
  if ! sudo cp -a "$src_theme/." /etc/sddm/themes/silent/; then
    warn "复制主题到 /etc/sddm/themes/silent 失败，登录页可能仍用包自带的默认配置"
  fi

  sudo mkdir -p /etc/sddm.conf.d
  if [ -f /etc/sddm.conf.d/90-silent.conf ]; then
    backup_file /etc/sddm.conf.d/90-silent.conf
    sudo rm -f /etc/sddm.conf.d/90-silent.conf
    log "已移除旧的 90-silent.conf（改名成 zz-kos-silent.conf）"
  fi
  # 走 sudo_write_file：它会先备份再写，并记进 manifest，kos-undo 才能把它删掉。
  # 以前这里是 sudo tee，文件绕过了备份/台账，回滚时会留下一个没人认领的 drop-in。
  # DisplayServer=wayland：sddm 0.21 的包默认是 x11（/usr/lib/sddm/sddm.conf.d/default.conf），
  # 验收机上是手工加的 10-wayland.conf 让登录页跑 kwin_wayland。安装器不写的话，
  # 干净装完登录页是 X11 greeter，和验收状态不是一回事（不会黑屏，sddm 依赖 xorg-server）。
  sudo_write_file /etc/sddm.conf.d/zz-kos-silent.conf <<'CONF'
[General]
DisplayServer=wayland
InputMethod=qtvirtualkeyboard
GreeterEnvironment=QML2_IMPORT_PATH=/etc/sddm/themes/silent/components/,QT_IM_MODULE=qtvirtualkeyboard

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts

[Theme]
ThemeDir=/etc/sddm/themes
Current=silent
CONF
  # /etc/sddm.conf 的优先级比 /etc/sddm.conf.d/*.conf 高：如果它存在并且设了 Theme，
  # 会把上面写的 Current=silent 盖回去。这里备份后把 Current 改成 silent。
  if [ -f /etc/sddm.conf ]; then
    backup_file /etc/sddm.conf
    if sudo grep -q '^\[Theme\]' /etc/sddm.conf; then
      sudo sed -i '/^\[Theme\]/,/^\[/ s/^Current=.*/Current=silent/' /etc/sddm.conf
      sudo grep -q '^Current=silent' /etc/sddm.conf ||
        printf 'Current=silent\n' | sudo tee -a /etc/sddm.conf >/dev/null
    else
      printf '\n[Theme]\nCurrent=silent\n' | sudo tee -a /etc/sddm.conf >/dev/null
    fi
    log "已处理 /etc/sddm.conf 的 Theme 覆盖（Current=silent）"
  fi

  customize_sddm_theme

  # 自检：写进去的配置到底生不生效。以前 AUR 装失败只 warn 一句就继续，
  # 结果登录页还是默认主题，从日志里很难看出是包没装上还是被别的 conf 覆盖。
  local effective
  effective=$(sddm_effective_theme)
  if ! pkg_installed sddm-silent-theme; then
    warn "sddm-silent-theme 没装上（AUR 构建失败？），登录页会退回 SDDM 默认主题；装好后重跑 install.sh 即可"
  elif [ ! -f /etc/sddm/themes/silent/Main.qml ]; then
    warn "主题包在，但自管副本 /etc/sddm/themes/silent/Main.qml 不存在，SDDM 会退回默认主题（重跑安装器重建）"
  elif [ "$effective" != "silent" ]; then
    warn "SDDM 实际生效的主题是 '${effective:-未配置}'，不是 silent —— 检查 /etc/sddm.conf.d/*.conf 有没有更靠后的文件设了 Current="
  else
    log "SDDM 自检通过：生效主题 = silent"
  fi
  log "SDDM 主题已切换到 silent（可到主题目录跑 ./test.sh 预览）"
}

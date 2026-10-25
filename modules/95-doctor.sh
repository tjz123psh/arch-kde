#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

run_doctor() {
  local mode="$1" gallery kos_dir="" ml ml_n ml_first ml_skip
  local wallpaper_ini kos_wp plasma_wp sddm_theme_effective
  local report="$STATE_DIR/doctor-$RUN_ID.txt"
  mkdir -p "$STATE_DIR"
  {
    echo "KOS 安装器 doctor"
    echo "时间: $(date)"
    echo "用户: $(id -un)  内核: $(uname -r)"
    echo "会话: XDG_CURRENT_DESKTOP=$(printenv XDG_CURRENT_DESKTOP 2>/dev/null || echo none) XDG_SESSION_TYPE=$(printenv XDG_SESSION_TYPE 2>/dev/null || echo none)"
    echo "locale: LANG=$(printenv LANG 2>/dev/null || echo unset)"
    echo
    echo "== 关键包 =="
    pacman -Q kwin plasma-workspace sddm kitty fish fcitx5 quickshell github-cli docker docker-compose npm jdk25-openjdk 2>&1 || true
    echo
    echo "== KOS 外观 =="
    if have kreadconfig6; then
      echo -n "Decoration:  "; kreadconfig6 --file kwinrc --group org.kde.kdecoration2 --key theme
      echo -n "InputMethod: "; kreadconfig6 --file kwinrc --group Wayland --key InputMethod
      echo -n "KOS 动画:    "; kreadconfig6 --file kwinrc --group Plugins --key kos_dock_window_animationEnabled
      echo -n "键盘重复:    "; kreadconfig6 --file kcminputrc --group Keyboard --key RepeatDelay; echo -n "ms / "; kreadconfig6 --file kcminputrc --group Keyboard --key RepeatRate; echo " 次/秒"
      echo -n "动态主题:    "; kreadconfig6 --file "$HOME/.local/state/quickshell/kos/wallpaper.ini" --group Wallpaper --key themeAnimated
      echo -n "Dock 显示:    "; grep -o '"visibilityMode"[[:space:]]*:[[:space:]]*"[^"]*"' "$HOME/.local/state/quickshell/kos/dock/config.json" 2>/dev/null | head -1
      echo -n "kitty 无标题栏: "; grep -q "decorationpolicy=none" "$HOME/.config/kwinrulesrc" 2>/dev/null && echo "已配置" || echo "未配置"
      echo -n "Glass:       "; kreadconfig6 --file kwinrc --group Plugins --key glassEnabled
    fi
    if declare -F kos_repo_dir >/dev/null 2>&1; then kos_dir=$(kos_repo_dir); fi
    if [ -n "$kos_dir" ] && [ -x "$kos_dir/tools/kosctl" ]; then
      echo -n "KOS:         "; "$kos_dir/tools/kosctl" version 2>/dev/null | head -1 || true
    fi
    echo
    echo "== 文件 =="
    test -d "$HOME/.config/quickshell/kos" && echo "  KOS shell 配置: yes" || echo "  KOS shell 配置: no"
    test -f "$HOME/.config/fcitx5/profile" && echo "  fcitx5 profile: yes" || echo "  fcitx5 profile: no"
    gallery="${XDG_DATA_HOME:-$HOME/.local/share}/kos/gallery"
    if [ -d "$gallery" ]; then
      echo "  壁纸库: yes ($(find "$gallery" -maxdepth 1 -type f | wc -l) 张)"
    else
      echo "  壁纸库: no"
    fi
    systemctl --user is-enabled kos-shell.service >/dev/null 2>&1 && echo "  kos-shell.service: enabled" || echo "  kos-shell.service: 未启用"
    for unit in kos-platform.service kos-data.service; do
      systemctl --user is-enabled "$unit" >/dev/null 2>&1 && echo "  $unit: enabled" || echo "  $unit: 未启用"
    done
    test -f "$HOME/.config/systemd/user/kos-pim-service.service" && echo "  kos-pim-service.service: unit present" || echo "  kos-pim-service.service: unit missing"
    echo
    echo "== KOS 运行时 =="
    for p in wl-clipboard cliphist brightnessctl python-gobject; do
      if pkg_installed "$p"; then echo "  [OK]   $p"; else echo "  [MISS] $p"; fi
    done
    if [ "${KOS_WITH_APPS:-1}" -eq 1 ]; then
      if pkg_installed kcalendarcore; then echo "  [OK]   kcalendarcore"; else echo "  [MISS] kcalendarcore"; fi
      for app in kos-calendar kos-calculator kos-todo kos-weather; do
        if test -x "$HOME/.local/bin/$app"; then echo "  [OK]   $app"; else echo "  [MISS] $app"; fi
      done
    fi
    echo
    echo "== 常驻脚本 =="
    for cmd in term-menu pac pacr pacd gsudo shortcuts record-menu hotspot; do
      if test -x "$HOME/bin/$cmd"; then echo "  [OK]   $cmd"; else echo "  [MISS] $cmd"; fi
    done
    test -d "$HOME/scripts" && echo "  脚本目录: yes" || echo "  脚本目录: no"
    echo
    echo "== 应用配置 =="
    for dir in yazi fastfetch mpv fuzzel btop; do
      test -d "$HOME/.config/$dir" && echo "  [OK]   $dir" || echo "  [MISS] $dir"
    done
    test -f "$HOME/.config/starship.toml" && echo "  [OK]   starship.toml" || echo "  [MISS] starship.toml"
    pkg_installed imagemagick && echo "  [OK]   imagemagick（fastfetch 图片 logo）" || echo "  [MISS] imagemagick（fastfetch 图片 logo 需要它）"

    # 桌面配置文件：缺一个都会让对应组件回到默认外观
    for f in \
      "$HOME/.config/kitty/kitty.conf" \
      "$HOME/.config/fish/config.fish" \
      "$HOME/.config/environment.d/90-kos.conf" \
      "$HOME/.config/gtk-3.0/settings.ini" \
      "$HOME/.config/gtk-4.0/settings.ini" \
      "$HOME/.config/fontconfig/fonts.conf" \
      "$HOME/.config/autostart/kos-display-1920x1080.desktop"; do
      if test -f "$f"; then echo "  [OK]   ${f#"$HOME"/}"; else echo "  [MISS] ${f#"$HOME"/}"; fi
    done

    echo
    echo "== 登录/外观 =="
    if pkg_installed sddm-silent-theme && test -f /usr/share/sddm/themes/silent/Main.qml; then
      # 登录页的定制写在主题包自己的 configs/default.conf 里，sddm-silent-theme 一升级
      # 就会被覆盖（该文件不在 pacman 的 backup 数组里，不会留 .pacnew），只能靠这里报出来。
      if grep -q 'kos-wallpaper.png' /usr/share/sddm/themes/silent/configs/default.conf 2>/dev/null; then
        echo "  [OK]   Silent 主题包与主题目录（登录页定制在位）"
      else
        echo "  [MISS] Silent 主题配置被包升级覆盖（背景/圆角/头像设置丢失）：重跑 install.sh 恢复"
      fi
    else
      echo "  [MISS] Silent 主题包/目录（sddm-silent-theme、/usr/share/sddm/themes/silent）"
    fi
    sddm_theme_effective=$(sddm_effective_theme 2>/dev/null || true)
    if [ "${sddm_theme_effective:-}" = silent ]; then
      echo "  [OK]   SDDM 生效主题（silent）"
    else
      echo "  [MISS] SDDM 生效主题（当前：${sddm_theme_effective:-空}）"
    fi
    if test -f "/usr/share/sddm/faces/${USER:-$(id -un)}.face.icon"; then
      echo "  [OK]   SDDM 登录头像"
    else
      echo "  [MISS] SDDM 登录头像（/usr/share/sddm/faces/${USER:-$(id -un)}.face.icon）"
    fi
    if test -f /boot/grub/grub.cfg; then
      if grep -q 'Elegant-mojave-window-left-dark' /boot/grub/grub.cfg; then
        echo "  [OK]   GRUB 主题（Elegant-mojave-window-left-dark）"
      else
        echo "  [MISS] GRUB 主题（grub.cfg 里没有主题路径）"
      fi
    fi
    if grep -qE '^GRUB_PRELOAD_MODULES=.*usb_keyboard' /etc/default/grub 2>/dev/null; then
      echo "  [WARN] GRUB_PRELOAD_MODULES 含 usb_keyboard：笔记本内置键盘会被抢，菜单上下键失效"
    fi
    echo
    echo "== 快捷键 =="
    for f in term-menu kitty-terminal btop fuzzel-launcher kos-wallpaper-preview kos-record; do
      test -f "$HOME/.local/share/applications/$f.desktop" && echo "  [OK]   $f.desktop" || echo "  [MISS] $f.desktop"
    done
    test -x "$HOME/.local/bin/kos-wallpaper-preview" && echo "  [OK]   kos-wallpaper-preview" || echo "  [MISS] kos-wallpaper-preview"
    pkg_installed gpu-screen-recorder && echo "  [OK]   gpu-screen-recorder" || echo "  [MISS] gpu-screen-recorder"
    echo
    echo "== 快照 =="
    snapper list-configs 2>&1 || true
    systemctl is-enabled snapper-timeline.timer 2>&1 || true
    systemctl is-enabled snapper-cleanup.timer 2>&1 || true
    pkg_installed btrfs-assistant && echo "  [OK]   btrfs-assistant" || echo "  [MISS] btrfs-assistant"
    echo
    echo "== 壁纸 =="
    wallpaper_ini="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/kos/wallpaper.ini"
    if [ -f "$wallpaper_ini" ]; then
      kos_wp=$(sed -n 's/^image=//p' "$wallpaper_ini" 2>/dev/null | head -n 1)
      if [ -n "$kos_wp" ] && [ -f "$kos_wp" ]; then
        echo "  [OK]   KOS 壁纸：$kos_wp"
      else
        echo "  [MISS] KOS 壁纸（wallpaper.ini 里的 image 不存在：${kos_wp:-空}）"
      fi
    else
      echo "  [MISS] KOS 壁纸配置（$wallpaper_ini）"
    fi
    plasma_wp=$(kreadconfig6 --file plasma-org.kde.plasma.desktop-appletsrc \
      --group Containments --group 1 --group Wallpaper --group org.kde.image --group General \
      --key Image 2>/dev/null || true)
    case "$plasma_wp" in
      *"/kos/gallery/"*) echo "  [OK]   Plasma 桌面壁纸：$plasma_wp" ;;
      "")
        if [ -f "$HOME/.config/autostart/kos-wallpaper-first-login.desktop" ]; then
          echo "  [OK]   Plasma 桌面壁纸：首次登录时由自启动设置"
        else
          echo "  [MISS] Plasma 桌面壁纸（还没设置，也没有首登自启动）"
        fi
        ;;
      *)                 echo "  [MISS] Plasma 桌面壁纸仍是 $plasma_wp（不在 KOS 图集里）" ;;
    esac
    echo
    echo "== 字体 =="
    fc-match "Noto Sans CJK SC" 2>/dev/null | head -1 || true
    fc-match "Maple Mono NF CN" 2>/dev/null | head -1 || true
    echo
    echo "== 服务 =="
    systemctl is-enabled sddm 2>&1 || true
    systemctl is-enabled NetworkManager 2>&1 || true
    echo
    echo "== 镜像 =="
    for ml in /etc/pacman.d/mirrorlist /etc/pacman.d/archlinuxcn-mirrorlist; do
      [ -f "$ml" ] || continue
      ml_n=$(grep -c '^Server = ' "$ml" 2>/dev/null || true)
      ml_first=$(grep -m1 '^Server = ' "$ml" 2>/dev/null | sed 's/^Server = //' || true)
      # 标记由 10-packages.sh 的 _mirror_demote_first 写入，格式是 "# downgraded: Server = "；
      # 这里原来找的是 "# 降级跳过"，永远匹配不到，降级计数恒为 0。
      ml_skip=$(grep -c '^# downgraded: Server = ' "$ml" 2>/dev/null || true)
      echo "  $ml: ${ml_n:-0} 个 Server，首个: ${ml_first:-无}"
      if [ "${ml_skip:-0}" -gt 0 ]; then
        echo "    已降级跳过 ${ml_skip} 个（重跑安装器会重写并复原）"
      fi
    done
    echo
    echo "== 时间/内存压缩 =="
    timedatectl 2>/dev/null | sed -n '1,7p' || true
    if have zramctl; then
      if zramctl 2>/dev/null | grep -q zram; then
        zramctl 2>/dev/null | head -3
      else
        echo "  zram: 未启用（archinstall 没开 zram 时可忽略）"
      fi
    fi
    echo
    # 硬件探测与驱动复查（逻辑在 20-hardware.sh；这里只负责把结果放进报告）
    if declare -F hw_doctor_check >/dev/null 2>&1; then
      if [ "${HW_DETECTED:-0}" -ne 1 ]; then hw_detect || true; fi
      echo "== 硬件 =="
      echo " CPU: ${CPU_MODEL:-unknown} (${CPU_VENDOR:-unknown})  机器: $([ "${IS_LAPTOP:-0}" -eq 1 ] && echo 笔记本 || echo 台式/未知)  VIRT=${VIRT:-unknown}"
      echo " GPU: ${GPU_VENDORS:-none}  NVIDIA_GEN=${NVIDIA_GEN:-unknown}"
      [ -n "${GPU_AMD_NAME:-}" ] && echo "   AMD: $GPU_AMD_NAME"
      [ -n "${GPU_NVIDIA_NAME:-}" ] && echo "   NVIDIA: $GPU_NVIDIA_NAME"
      echo " 外设: 摄像头=${HAS_CAMERA:-0}"
      echo " Wi-Fi: ${HAS_WIFI:-0} ${WIFI_NAME:-} ${WIFI_IDS:-}"
      echo " 蓝牙: ${HAS_BT:-0}"
      echo " bootloader: ${BOOTLOADER:-unknown}  微码: $(hw_microcode_pkg)/$(hw_microcode_state)  microcode-hook=${MICROCODE_HOOK:-0}"
      echo
      echo "== 驱动复查 =="
      hw_doctor_check
      echo
    fi
    if [ "$mode" = quick ]; then
      echo "== 快速模式：跳过进程检查 =="
    else
      echo "== 进程 =="
      pgrep -a kwin_wayland 2>/dev/null | head -2 || true
      pgrep -a plasmashell 2>/dev/null | head -2 || true
      pgrep -a qs 2>/dev/null | head -2 || true
      pgrep -a fcitx5 2>/dev/null | head -2 || true
      echo
      echo "== KWin 支持信息 =="
      if have qdbus6; then
        qdbus6 org.kde.KWin /KWin supportInformation 2>/dev/null | head -40 || true
      fi
    fi
  } | tee "$report"

  if [ "$DRY_RUN" -eq 0 ]; then
    log "doctor 报告: $report"
  fi
}

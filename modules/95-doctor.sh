#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

doctor_check() {
  local label="$1" ok="$2" detail="$3"
  if [ "$ok" -eq 1 ]; then
    echo "  [OK]   $label $detail"
  else
    echo "  [MISS] $label $detail"
  fi
}

run_doctor() {
  local mode="$1" gallery kos_dir="" ml ml_n ml_first ml_skip
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
    pacman -Q kwin plasma-workspace sddm kitty fish fcitx5 quickshell 2>&1 || true
    echo
    echo "== KOS 外观 =="
    if have kreadconfig6; then
      echo -n "Decoration:  "; kreadconfig6 --file kwinrc --group org.kde.kdecoration2 --key theme
      echo -n "InputMethod: "; kreadconfig6 --file kwinrc --group Wayland --key InputMethod
      echo -n "KOS 动画:    "; kreadconfig6 --file kwinrc --group Plugins --key kos_dock_window_animationEnabled
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
      ml_skip=$(grep -c '^# 降级跳过' "$ml" 2>/dev/null || true)
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

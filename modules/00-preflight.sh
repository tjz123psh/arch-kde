#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

# 硬件探测（hw_detect / hw_microcode_state / hw_doctor_check）在 20-hardware.sh。
# install.sh 会把 modules/*.sh 全部 source 进来，所以这里不需要自己加载。

KERNELS=
HEADERS=
HAS_NVIDIA=0
HAS_AMD=0

detect_kernels() {
  local k
  KERNELS=
  for k in linux linux-lts linux-zen linux-hardened; do
    if pacman -Qq "$k" >/dev/null 2>&1; then
      KERNELS="${KERNELS:+$KERNELS }$k"
    fi
  done
  [ -n "$KERNELS" ] || die "No kernel detected; finish archinstall first"
}

detect_headers() {
  local k
  HEADERS=
  for k in $KERNELS; do
    case "$k" in
      linux) HEADERS="$HEADERS linux-headers" ;;
      linux-lts) HEADERS="$HEADERS linux-lts-headers" ;;
      linux-zen) HEADERS="$HEADERS linux-zen-headers" ;;
      linux-hardened) HEADERS="$HEADERS linux-hardened-headers" ;;
    esac
  done
}

detect_gpu() {
  local f v
  HAS_NVIDIA=0
  HAS_AMD=0
  for f in /sys/class/drm/card*/device/vendor; do
    [ -e "$f" ] || continue
    v=$(cat "$f" 2>/dev/null || true)
    case "$v" in
      0x10de) HAS_NVIDIA=1 ;;
      0x1002) HAS_AMD=1 ;;
    esac
  done
}

check_network() {
  if ! getent ahostsv4 archlinux.org >/dev/null 2>&1; then
    die "Cannot resolve archlinux.org; connect to the network first (nmtui / iwctl)"
  fi
  if ! timeout 8 bash -c 'exec 3<>/dev/tcp/archlinux.org/443' 2>/dev/null; then
    warn "Cannot reach archlinux.org:443 directly; the install may fail (check proxy/mirrors)"
  fi
}

check_disk() {
  local avail
  avail=$(df -Pk /var/cache/pacman/pkg 2>/dev/null | awk 'NR==2 {print $4}')
  if [ -z "$avail" ]; then return 0; fi
  if [ "$avail" -lt 8388608 ]; then
    die "Less than 8G free on disk ($avail K); free some space first"
  fi
}

# ---------------------------------------------------------------------------
# archinstall 之后的前置状态检查
#
# 下面这些是用户装机流程里 archinstall 已经处理过的：分区/挂载、bootloader、
# linux-lts 或 linux-zen + headers、时区、时间同步、zram。安装器不重做这些
# 破坏性动作（分区/引导器绝不碰），但动手前要确认它们在位：
#   - 缺 headers 会进官方包列表补（detect_headers）
#   - 时间同步没开由 40-system.sh 兜底启用 systemd-timesyncd
#   - 时区/引导器只报告，不改（改时区会影响用户预期）
# 全部只读，失败只 warn，不 die。
# ---------------------------------------------------------------------------
check_prereqs() {
  local tz='' ntp='' u
  if [ -e /etc/localtime ]; then
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    if [ -z "$tz" ]; then
      tz=$(readlink -f /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || true)
    fi
    case "$tz" in
      ""|UTC)
        warn "Timezone is ${tz:-unknown} (archinstall defaults to UTC); the installer leaves it alone; after install run: sudo timedatectl set-timezone Asia/Shanghai"
        ;;
      *)
        log "Timezone: $tz (set by archinstall; installer leaves it alone)"
        ;;
    esac
  else
    warn "No /etc/localtime: timezone is unset, the desktop clock will be wrong (installer does not change it)"
  fi

  for u in chronyd ntpd openntpd systemd-timesyncd; do
    if systemctl is-enabled --quiet "$u" 2>/dev/null; then ntp=$u; break; fi
  done
  if [ -n "$ntp" ]; then
    log "Time sync: $ntp enabled"
  else
    warn "No time sync service enabled; 40-system will fall back to systemd-timesyncd"
  fi

  if [ -e /sys/block/zram0 ]; then
    log "zram: /dev/zram0 active"
  elif [ -e /etc/systemd/zram-generator.conf ]; then
    warn "Found /etc/systemd/zram-generator.conf but /dev/zram0 is not up (archinstall zram not active? check zramctl after install)"
  fi

  if [ "${BOOTLOADER:-unknown}" = unknown ]; then
    warn "Could not detect the bootloader (GRUB/systemd-boot); the installer does not touch it, but make sure the machine reboots fine"
  else
    log "bootloader: $BOOTLOADER (not touched)"
  fi
  if [ -n "$HEADERS" ]; then
    log "Kernel headers: $HEADERS"
  else
    warn "Could not derive kernel header packages (empty kernel list?)"
  fi
  if [ ! -d /boot ]; then
    warn "No /boot directory: kernel, initramfs and microcode cannot be installed (archinstall should have created it)"
  fi
  if systemctl is-enabled --quiet reflector.timer 2>/dev/null; then
    warn "reflector.timer is enabled: it periodically rewrites /etc/pacman.d/mirrorlist and will override the domestic mirror list; run sudo systemctl disable --now reflector.timer to keep it"
  fi
}

preflight() {
  if [ "$(id -u)" -eq 0 ]; then die "Do not run as root (the script uses sudo internally)"; fi
  [ -f /etc/arch-release ] || die "Only Arch Linux is supported"
  [ "$(uname -m)" = x86_64 ] || die "Only x86_64 is supported"
  have pacman || die "pacman not found"
  have sudo || die "sudo not found"
  have git || warn "git is not installed; the script will install it first"

  if [ ! -t 0 ]; then warn "Not an interactive terminal; confirmation prompts may not work (add --yes)"; fi
  if [ -n "$(printenv XDG_CURRENT_DESKTOP 2>/dev/null || true)" ]; then
    warn "Graphical session detected; this script expects to run on a TTY"
  fi
  if pacman -Qq plasma-desktop >/dev/null 2>&1; then
    warn "plasma-desktop is already installed; the script will overwrite part of its config (backed up)"
  fi

  check_network
  check_disk
  detect_kernels
  detect_headers
  detect_gpu
  # 全量硬件探测（CPU/GPU/Wi-Fi/蓝牙/摄像头/bootloader/微码 hook）。
  # 只读、不装任何东西；失败也只会让字段留空，不会中断安装。
  if declare -F hw_detect >/dev/null 2>&1; then
    hw_detect || true
    # 兼容变量：install.sh 的 print_plan 还在读这两个旧名字
    if [ "${HAS_AMD_GPU:-0}" -eq 1 ]; then HAS_AMD=1; fi
    if [ "${HAS_NVIDIA_GPU:-0}" -eq 1 ]; then HAS_NVIDIA=1; fi
  fi
  check_prereqs
  log "Kernel: $KERNELS"
  log "NVIDIA: $HAS_NVIDIA  AMD: $HAS_AMD"
  if [ "${HW_DETECTED:-0}" -eq 1 ]; then
    log "Hardware: CPU=$CPU_VENDOR  GPU=[${GPU_VENDORS}]  Wi-Fi=$HAS_WIFI BT=$HAS_BT Camera=$HAS_CAMERA"
    log "Bootloader: $BOOTLOADER  Microcode: $(hw_microcode_pkg)/$(hw_microcode_state)  microcode-hook=$MICROCODE_HOOK"
  fi
}

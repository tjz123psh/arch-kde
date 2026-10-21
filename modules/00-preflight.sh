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
  [ -n "$KERNELS" ] || die "没有检测到内核，请先完成 archinstall"
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
    die "无法解析 archlinux.org，请先连接网络（nmtui / iwctl）"
  fi
  if ! timeout 8 bash -c 'exec 3<>/dev/tcp/archlinux.org/443' 2>/dev/null; then
    warn "无法直连 archlinux.org:443，安装可能失败（检查代理/镜像）"
  fi
}

check_disk() {
  local avail
  avail=$(df -Pk /var/cache/pacman/pkg 2>/dev/null | awk 'NR==2 {print $4}')
  if [ -z "$avail" ]; then return 0; fi
  if [ "$avail" -lt 8388608 ]; then
    die "磁盘可用空间不足 8G（当前 $avail K），请先清理"
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
        warn "时区是 ${tz:-未知}（archinstall 默认 UTC）；安装器不改时区，装完用 sudo timedatectl set-timezone Asia/Shanghai"
        ;;
      *)
        log "时区: $tz（archinstall 已设置，安装器不改）"
        ;;
    esac
  else
    warn "没有 /etc/localtime：时区没设置，桌面时间会不对（安装器不改时区）"
  fi

  for u in chronyd ntpd openntpd systemd-timesyncd; do
    if systemctl is-enabled --quiet "$u" 2>/dev/null; then ntp=$u; break; fi
  done
  if [ -n "$ntp" ]; then
    log "时间同步: $ntp 已启用"
  else
    warn "没有启用的时间同步服务；40-system 会兜底启用 systemd-timesyncd"
  fi

  if [ -e /sys/block/zram0 ]; then
    log "zram: /dev/zram0 已启用"
  elif [ -e /etc/systemd/zram-generator.conf ]; then
    warn "有 /etc/systemd/zram-generator.conf 但 /dev/zram0 没起来（archinstall 的 zram 没生效？装完看 zramctl）"
  fi

  if [ "${BOOTLOADER:-unknown}" = unknown ]; then
    warn "没识别出 bootloader（GRUB/systemd-boot）；安装器不改引导，但请确认机器能正常重启"
  else
    log "bootloader: $BOOTLOADER（安装器不改）"
  fi
  if [ -n "$HEADERS" ]; then
    log "内核 headers:$HEADERS"
  else
    warn "没算出内核 headers 包名（内核列表为空？）"
  fi
  if [ ! -d /boot ]; then
    warn "没有 /boot 目录：内核、initramfs、微码都装不进去（archinstall 应该已经建好）"
  fi
  if systemctl is-enabled --quiet reflector.timer 2>/dev/null; then
    warn "reflector.timer 已启用：它会定期重写 /etc/pacman.d/mirrorlist，覆盖本安装器的国内镜像列表；要固定就 sudo systemctl disable --now reflector.timer"
  fi
}

preflight() {
  if [ "$(id -u)" -eq 0 ]; then die "请不要用 root 运行（脚本内部会用 sudo）"; fi
  [ -f /etc/arch-release ] || die "只支持 Arch Linux"
  [ "$(uname -m)" = x86_64 ] || die "只支持 x86_64"
  have pacman || die "找不到 pacman"
  have sudo || die "找不到 sudo"
  have git || warn "git 未安装，脚本会先装 git"

  if [ ! -t 0 ]; then warn "当前不是交互终端，确认提示可能失效（可加 --yes）"; fi
  if [ -n "$(printenv XDG_CURRENT_DESKTOP 2>/dev/null || true)" ]; then
    warn "检测到图形会话，本脚本预期在 TTY 运行"
  fi
  if pacman -Qq plasma-desktop >/dev/null 2>&1; then
    warn "检测到 plasma-desktop 已安装，脚本会覆盖部分配置（已备份）"
  fi

  check_network
  check_disk
  detect_kernels
  detect_headers
  detect_gpu
  # 全量硬件探测（CPU/GPU/Wi-Fi/蓝牙/指纹/摄像头/打印/WWAN/bootloader/微码 hook）。
  # 只读、不装任何东西；失败也只会让字段留空，不会中断安装。
  if declare -F hw_detect >/dev/null 2>&1; then
    hw_detect || true
    # 兼容变量：install.sh 的 print_plan 还在读这两个旧名字
    if [ "${HAS_AMD_GPU:-0}" -eq 1 ]; then HAS_AMD=1; fi
    if [ "${HAS_NVIDIA_GPU:-0}" -eq 1 ]; then HAS_NVIDIA=1; fi
  fi
  check_prereqs
  log "内核: $KERNELS"
  log "NVIDIA: $HAS_NVIDIA  AMD: $HAS_AMD"
  if [ "${HW_DETECTED:-0}" -eq 1 ]; then
    log "硬件: CPU=$CPU_VENDOR  GPU=[${GPU_VENDORS}]  Wi-Fi=$HAS_WIFI 蓝牙=$HAS_BT 指纹=$HAS_FINGERPRINT 摄像头=$HAS_CAMERA 打印=$HAS_PRINTER"
    log "引导器: $BOOTLOADER  微码: $(hw_microcode_pkg)/$(hw_microcode_state)  microcode-hook=$MICROCODE_HOOK"
  fi
}

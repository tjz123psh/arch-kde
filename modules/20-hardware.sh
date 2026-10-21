#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# 硬件探测（只读）。本文件只负责“看清机器”，不做任何策略决定：
# 装不装、装哪套、走哪个开关，全部由 10-packages.sh 的 hw_policy_resolve() 决定。
#
# 由 install.sh 统一 source；00-preflight.sh 在预检里调 hw_detect()，
# 95-doctor.sh 用 hw_doctor_check() 做装后复查。
#
# 设计约束（真机“装错就黑屏 / 断网 / 没输入”的防线）：
#   1. 只用 /proc、/sys 探测，干净 Arch（没有 lspci、没有 X）也能跑；
#   2. 全程只读，--dry-run 安全；任何一项失败都只是留空，绝不 die；
#   3. 变量在文件顶部全部初始化，set -u 下直接读也安全；
#   4. 只描述事实（有没有这块硬件 / 内核有没有驱动），不猜该装什么包。
#
# 变量契约（hw_detect 填充）：
#   CPU_VENDOR      amd|intel|unknown
#   CPU_MODEL       /proc/cpuinfo 的 model name
#   IS_VM 0|1       VIRT  vmware|kvm|virtualbox|hyperv|physical|unknown
#   GPU_VENDORS     "amd intel nvidia"（探测到的，空格分隔；没有则为空串）
#   HAS_AMD_GPU / HAS_INTEL_GPU / HAS_NVIDIA_GPU   0|1
#   GPU_NVIDIA_NAME / GPU_AMD_NAME / GPU_INTEL_NAME  人读型号（无 lspci 时退回 PCI ID）
#   NVIDIA_GEN      turing_plus|pre_turing|unknown（pre_turing 不能装 nvidia-open-dkms；
#                   NVIDIA 615 起官方仓库只剩开源内核模块，nvidia-dkms 已不存在，
#                   老卡要 archlinuxcn 的 nvidia-580xx-dkms/-utils，安装器开关是 --nvidia-legacy）
#   HAS_WIFI 0|1    WIFI_IDS "10ec:b852"（多个用空格分隔）
#   WIFI_NAME       PCI ID 或 lspci 型号
#   WIFI_VENDOR     realtek|intel|broadcom|mediatek|atheros|other|""
#   HAS_BT / HAS_CAMERA / HAS_WWAN   0|1
#   IS_LAPTOP 0|1   有电池即视为笔记本
#   BOOTLOADER      grub|systemd-boot|refind|unknown
#   MICROCODE_HOOK  0|1（/etc/mkinitcpio.conf 的 HOOKS 里有没有 microcode）
#
# 函数契约：
#   hw_detect            幂等、只读、永远返回 0
#   hw_report            用 log() 打印中文硬件表（install.sh 的计划摘要里调）
#   hw_doctor_check      打印复查行（[OK]/[MISS]），给 doctor 用，永远返回 0
#   hw_microcode_state   echo early|configured|missing|n/a
#   hw_bootloader_hint   打印“装完微码还要做什么”的具体命令（不碰 bootloader）
# ---------------------------------------------------------------------------

CPU_VENDOR=unknown
CPU_MODEL=""
IS_VM=0
VIRT=""
GPU_VENDORS=""
HAS_AMD_GPU=0
HAS_INTEL_GPU=0
HAS_NVIDIA_GPU=0
GPU_NVIDIA_NAME=""
GPU_AMD_NAME=""
GPU_INTEL_NAME=""
NVIDIA_GEN=unknown
HAS_WIFI=0
WIFI_IDS=""
WIFI_NAME=""
WIFI_VENDOR=""
HAS_BT=0
HAS_CAMERA=0
HAS_ASUS=0
HAS_WWAN=0
IS_LAPTOP=0
BOOTLOADER=unknown
MICROCODE_HOOK=0
# hw_detect 跑过的标记（幂等用；也给 doctor 判断“探测器有没有跑起来”）
HW_DETECTED=0

# --------------------------------------------------------------------------
# 小工具（本文件自包含，不依赖 common.sh 的 helper）
# --------------------------------------------------------------------------

_hw_have() { command -v "$1" >/dev/null 2>&1; }

# 读一个 sysfs 文件的第一行；不存在/没权限就输出空
_hw_read() {
  if [ -r "$1" ]; then
    head -n1 "$1" 2>/dev/null || true
  fi
}

# 把 "0x10de" 之类规整成小写无前缀的 10de
_hw_hex() {
  local v="$1"
  v=${v#0x}
  v=${v#0X}
  printf '%s' "$v" | tr '[:upper:]' '[:lower:]'
}

# PCI 设备名：优先 lspci，没有 lspci（干净 Arch 常见）就退回 vendor:device
_hw_pci_name() {
  local ven="$1" dev="$2" name=""
  if _hw_have lspci; then
    # lspci 行格式: "01:00.0 VGA compatible controller: NVIDIA Corporation AD107M ... (rev a1)"
    # 依次去掉 slot、设备类前缀、末尾 rev
    name=$(lspci -d "$ven:$dev" 2>/dev/null | head -n1 \
      | sed -e 's/^[0-9a-f:.]* //' -e 's/^[^:]*: //' -e 's/ *(rev [^)]*)//' || true)
  fi
  if [ -z "$name" ]; then
    name="$ven:$dev"
  fi
  printf '%s' "$name"
}

# --------------------------------------------------------------------------
# CPU / 虚拟机 / 笔记本
# --------------------------------------------------------------------------

_hw_detect_cpu() {
  local vendor
  CPU_MODEL=$(awk -F': *' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
  vendor=$(awk -F': *' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
  case "$vendor" in
    GenuineIntel) CPU_VENDOR=intel ;;
    AuthenticAMD) CPU_VENDOR=amd ;;
    *) CPU_VENDOR=unknown ;;
  esac
}

_hw_detect_virt() {
  local dmi product
  IS_VM=0
  VIRT=physical
  dmi=$(_hw_read /sys/class/dmi/id/sys_vendor)
  product=$(_hw_read /sys/class/dmi/id/product_name)
  case "$dmi$product" in
    *VMware*|*VirtualBox*|*QEMU*|*KVM*|*innotek*|*Microsoft*Corporation*|*Bochs*|*Parallels*)
      IS_VM=1
      ;;
  esac
  case "$dmi" in
    *VMware*) VIRT=vmware ;;
    *VirtualBox*|*innotek*) VIRT=virtualbox ;;
    *QEMU*) VIRT=kvm ;;
    *Microsoft*) VIRT=hyperv ;;
  esac
  # hypervisor 标志兜底（某些机型 DMI 干净但跑在虚拟化里）
  if [ "$IS_VM" -eq 0 ] && grep -qw hypervisor /proc/cpuinfo 2>/dev/null; then
    IS_VM=1
    [ "$VIRT" = physical ] && VIRT=unknown
  fi
}

_hw_detect_laptop() {
  local f
  IS_LAPTOP=0
  for f in /sys/class/power_supply/BAT*; do
    [ -e "$f" ] || continue
    IS_LAPTOP=1
    break
  done
}

# --------------------------------------------------------------------------
# GPU
# --------------------------------------------------------------------------

_hw_detect_gpu() {
  local dir v id nvidia_id="" amd_id="" intel_id=""
  HAS_AMD_GPU=0
  HAS_INTEL_GPU=0
  HAS_NVIDIA_GPU=0
  for dir in /sys/class/drm/card[0-9]*/device; do
    [ -d "$dir" ] || continue
    v=$(_hw_read "$dir/vendor")
    id=$(_hw_read "$dir/device")
    case "$v" in
      0x1002)
        HAS_AMD_GPU=1
        [ -n "$amd_id" ] || amd_id=$(_hw_hex "$id")
        ;;
      0x8086)
        HAS_INTEL_GPU=1
        [ -n "$intel_id" ] || intel_id=$(_hw_hex "$id")
        ;;
      0x10de)
        HAS_NVIDIA_GPU=1
        [ -n "$nvidia_id" ] || nvidia_id=$(_hw_hex "$id")
        ;;
    esac
  done

  GPU_VENDORS=""
  if [ "$HAS_AMD_GPU" -eq 1 ]; then GPU_VENDORS="$GPU_VENDORS amd"; fi
  if [ "$HAS_INTEL_GPU" -eq 1 ]; then GPU_VENDORS="$GPU_VENDORS intel"; fi
  if [ "$HAS_NVIDIA_GPU" -eq 1 ]; then GPU_VENDORS="$GPU_VENDORS nvidia"; fi
  GPU_VENDORS=${GPU_VENDORS# }

  if [ -n "$amd_id" ]; then
    GPU_AMD_NAME=$(_hw_pci_name 1002 "$amd_id")
  fi
  if [ -n "$intel_id" ]; then
    GPU_INTEL_NAME=$(_hw_pci_name 8086 "$intel_id")
  fi

  NVIDIA_GEN=unknown
  if [ -n "$nvidia_id" ]; then
    GPU_NVIDIA_NAME=$(_hw_pci_name 10de "$nvidia_id")
    # 分代规则（保守）：Turing 及以后才支持开源内核模块 nvidia-open。
    # TU102/104/106/116 起设备号约从 0x1e00 开始；更小的（Kepler/Maxwell/Pascal）
    # 一律判为 pre_turing —— 宁可让用户手动选闭源驱动，也不要装完加载不了直接黑屏。
    case "$nvidia_id" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f])
        if [ $((16#$nvidia_id)) -ge $((16#1e00)) ]; then
          NVIDIA_GEN=turing_plus
        else
          NVIDIA_GEN=pre_turing
        fi
        ;;
      *) NVIDIA_GEN=unknown ;;
    esac
  fi
}

# --------------------------------------------------------------------------
# Wi-Fi / 蓝牙 / WWAN
# --------------------------------------------------------------------------

_hw_wifi_vendor_of() {
  case "$1" in
    10ec) printf 'realtek' ;;
    8086) printf 'intel' ;;
    14e4) printf 'broadcom' ;;
    14c3) printf 'mediatek' ;;
    168c) printf 'atheros' ;;
    *) printf 'other' ;;
  esac
}

_hw_detect_wifi() {
  local d cls ven dev ids="" id vid
  HAS_WIFI=0
  WIFI_IDS=""
  WIFI_NAME=""
  WIFI_VENDOR=""

  # 主路径：PCI 无线网卡（class 0x0280 = Network controller / Wireless）
  for d in /sys/bus/pci/devices/*; do
    [ -r "$d/class" ] || continue
    cls=$(_hw_read "$d/class")
    case "$cls" in
      0x0280*) ;;
      *) continue ;;
    esac
    ven=$(_hw_hex "$(_hw_read "$d/vendor")")
    dev=$(_hw_hex "$(_hw_read "$d/device")")
    [ -n "$ven" ] || continue
    ids="$ven:$dev"
    HAS_WIFI=1
    WIFI_IDS=${WIFI_IDS:+$WIFI_IDS }"$ids"
    if [ -z "$WIFI_NAME" ]; then WIFI_NAME=$(_hw_pci_name "$ven" "$dev"); fi
  done

  # 兜底：USB 网卡 / 内核已经建出无线接口但 PCI 类不是 0280
  if [ "$HAS_WIFI" -eq 0 ]; then
    for d in /sys/class/net/*; do
      [ -d "$d" ] || continue
      if [ -e "$d/wireless" ] || [ -e "$d/phy80211" ]; then
        HAS_WIFI=1
        break
      fi
    done
  fi

  # 厂商只用于报告；目标机 RTL8852BE 走内核 rtw89，不需要 AUR 机型驱动
  if [ "$HAS_WIFI" -eq 1 ] && [ -n "$WIFI_IDS" ]; then
    id=${WIFI_IDS%% *}
    vid=${id%%:*}
    WIFI_VENDOR=$(_hw_wifi_vendor_of "$vid")
    if [ -z "$WIFI_NAME" ]; then WIFI_NAME=$id; fi
  fi
}

_hw_detect_bt() {
  local f
  HAS_BT=0
  for f in /sys/class/bluetooth/hci*; do
    [ -e "$f" ] || continue
    HAS_BT=1
    break
  done
}

_hw_detect_wwan() {
  local f
  HAS_WWAN=0
  for f in /sys/class/wwan* /dev/cdc-wdm*; do
    [ -e "$f" ] || continue
    HAS_WWAN=1
    break
  done
}

# --------------------------------------------------------------------------
# 外设：摄像头
# --------------------------------------------------------------------------

_hw_detect_camera() {
  local f
  HAS_CAMERA=0
  for f in /sys/class/video4linux/video*; do
    [ -e "$f" ] || continue
    HAS_CAMERA=1
    break
  done
}

# --------------------------------------------------------------------------
# Bootloader / 微码 hook
# --------------------------------------------------------------------------

_hw_detect_bootloader() {
  local cmdline
  BOOTLOADER=unknown
  cmdline=$(_hw_read /proc/cmdline)
  # systemd-boot 会在命令行里带 initrd=…（GRUB 不会）
  case "$cmdline" in
    *initrd=*) BOOTLOADER=systemd-boot ;;
  esac
  if [ "$BOOTLOADER" = unknown ]; then
    if [ -f /boot/grub/grub.cfg ] || [ -f /etc/default/grub ]; then
      BOOTLOADER=grub
    elif [ -d /efi/loader ] || [ -d /boot/loader ]; then
      BOOTLOADER=systemd-boot
    elif [ -d /efi/EFI/refind ] || [ -d /boot/EFI/refind ]; then
      BOOTLOADER=refind
    fi
  fi
}

_hw_detect_microcode_hook() {
  local hooks f
  MICROCODE_HOOK=0
  hooks=""
  for f in /etc/mkinitcpio.conf /etc/mkinitcpio.conf.d/*.conf; do
    [ -r "$f" ] || continue
    hooks="$hooks $(sed -n 's/^[[:space:]]*HOOKS=(//p' "$f" 2>/dev/null | sed 's/).*//' || true)"
  done
  case " $hooks " in
    *" microcode "*) MICROCODE_HOOK=1 ;;
  esac
}

# --------------------------------------------------------------------------
# 主入口
# --------------------------------------------------------------------------

# ASUS / ROG 笔记本（决定要不要装 asusctl / rog-control-center / supergfxctl）
_hw_detect_asus() {
  HAS_ASUS=0
  local v
  v=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
  case "$v" in
    *ASUSTeK*|*ASUS*) HAS_ASUS=1 ;;
  esac
}

hw_detect() {
  # 幂等：重复调用只重算，不累积
  _hw_detect_cpu
  _hw_detect_virt
  _hw_detect_laptop
  _hw_detect_gpu
  _hw_detect_wifi
  _hw_detect_bt
  _hw_detect_wwan
  _hw_detect_camera
  _hw_detect_asus
  _hw_detect_bootloader
  _hw_detect_microcode_hook
  HW_DETECTED=1
  return 0
}

# --------------------------------------------------------------------------
# 微码状态与 bootloader 提示
# --------------------------------------------------------------------------

# 当前 CPU 对应的官方微码包（未知返回空）
hw_microcode_pkg() {
  case "$CPU_VENDOR" in
    intel) printf 'intel-ucode' ;;
    amd) printf 'amd-ucode' ;;
    *) printf '' ;;
  esac
}

# 微码是否已经进了 initramfs（mkinitcpio 合并 initramfs 里含 kernel/x86/microcode）
_hw_ucode_in_initrd() {
  local k img
  k=$(uname -r 2>/dev/null || true)
  _hw_have lsinitcpio || return 1
  for img in "/boot/initramfs-$k.img" /boot/initramfs-linux.img; do
    [ -r "$img" ] || continue
    if lsinitcpio "$img" 2>/dev/null | grep -q 'kernel/x86/microcode'; then
      return 0
    fi
  done
  return 1
}

# 内核启动日志里有没有“早期加载微码”的直接证据（最可靠，不依赖 /boot 可读）
# 注意：dmesg 可能被 kernel.dmesg_restrict 挡住，journalctl -k 需要 adm 组；
# 两条路都拿不到就当作“没有证据”，不影响后续判断。
_hw_ucode_early_evidence() {
  local hit=""
  hit=$(dmesg 2>/dev/null | grep -m1 -i 'microcode: updated early' || true)
  if [ -z "$hit" ] && _hw_have journalctl; then
    hit=$(journalctl -k -b --no-pager 2>/dev/null | grep -m1 -i 'microcode: updated early' || true)
  fi
  [ -n "$hit" ]
}

# 老式 GRUB 配置里单独 initrd 了 xxx-ucode.img
_hw_ucode_in_grub() {
  local f
  for f in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
    [ -r "$f" ] || continue
    if grep -q 'ucode\.img' "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# early      = 微码已经真正在早期加载（initramfs 里有 / grub 里 initrd 了 ucode.img）
# configured = 包已装 + 有 microcode hook，但 initramfs 还没重建（跑一次 mkinitcpio -P 就好）
# missing    = 包没装，或者没有 hook 也没在 bootloader 里 initrd
# n/a        = CPU 厂商未知（非 x86 / 读不到）
hw_microcode_state() {
  local pkg
  pkg=$(hw_microcode_pkg)
  if [ -z "$pkg" ]; then
    printf 'n/a\n'
    return 0
  fi
  if _hw_ucode_in_initrd || _hw_ucode_in_grub || _hw_ucode_early_evidence; then
    printf 'early\n'
    return 0
  fi
  if _hw_have pacman && pacman -Qq "$pkg" >/dev/null 2>&1 && [ "$MICROCODE_HOOK" -eq 1 ]; then
    printf 'configured\n'
    return 0
  fi
  printf 'missing\n'
}

# 装完微码还要做什么（安装器不改 bootloader，只把命令打出来）
hw_bootloader_hint() {
  local pkg state
  pkg=$(hw_microcode_pkg)
  state=$(hw_microcode_state)
  if [ -z "$pkg" ]; then
    echo "  CPU 厂商未识别，微码这一步跳过（不影响启动）。"
    return 0
  fi
  echo "  微码包: $pkg    状态: $state    bootloader: $BOOTLOADER    microcode hook: $MICROCODE_HOOK"
  case "$state" in
    early)
      echo "  微码已在早期加载，不需要改 bootloader。"
      ;;
    configured)
      echo "  已装包且有 microcode hook，只差重建 initramfs:"
      echo "    sudo mkinitcpio -P"
      echo "  重建后 initramfs 内自带微码，GRUB/systemd-boot 都不需要额外改动。"
      ;;
    missing)
      if [ "$MICROCODE_HOOK" -eq 1 ]; then
        echo "  装包后重建 initramfs 即可（hook 已在，不用改 bootloader）:"
        echo "    sudo pacman -S --needed $pkg && sudo mkinitcpio -P"
      else
        echo "  注意：/etc/mkinitcpio.conf 里没有 microcode hook，需要二选一："
        echo "    A) 推荐（和你现在的 Arch 默认一致）: 把 microcode 加到 HOOKS 里（autodetect 之后），再"
        echo "       sudo mkinitcpio -P     # 生成合并 initramfs，bootloader 不用改"
        case "$BOOTLOADER" in
          grub)
            echo "    B) 老式 GRUB 路线: 在 /etc/grub.d 里把 'initrd /$pkg.img' 放在真 initrd 之前，然后"
            echo "       sudo grub-mkconfig -o /boot/grub/grub.cfg"
            ;;
          systemd-boot)
            echo "    B) systemd-boot 路线: 在 /boot/loader/entries/*.conf 里加一行 'initrd /$pkg.img'（放在 linux 行之前）"
            ;;
          *)
            echo "    B) 或在 bootloader 里把 $pkg.img 作为第一个 initrd 加载"
            ;;
        esac
      fi
      ;;
  esac
  return 0
}

# --------------------------------------------------------------------------
# 报告
# --------------------------------------------------------------------------

_hw_yn() { if [ "$1" -eq 1 ]; then printf '有'; else printf '无'; fi; }

hw_report() {
  local gpu
  gpu=""
  [ "$HAS_AMD_GPU" -eq 1 ] && gpu="$gpu AMD[$GPU_AMD_NAME]"
  [ "$HAS_INTEL_GPU" -eq 1 ] && gpu="$gpu Intel[$GPU_INTEL_NAME]"
  [ "$HAS_NVIDIA_GPU" -eq 1 ] && gpu="$gpu NVIDIA[$GPU_NVIDIA_NAME/$NVIDIA_GEN]"
  [ -n "$gpu" ] || gpu=" 未检测到（或只有虚拟显卡）"

  log "---- 硬件探测 ----"
  log " CPU        : $CPU_MODEL ($CPU_VENDOR)"
  log " 机器       : $([ "$IS_LAPTOP" -eq 1 ] && echo 笔记本 || echo 台式/未知)  VIRT=$VIRT"
  log " 微码       : $(hw_microcode_pkg || true) 状态=$(hw_microcode_state) hook=$MICROCODE_HOOK"
  log " 显卡       :$gpu"
  if [ "$HAS_WIFI" -eq 1 ]; then
    log " Wi-Fi      : $WIFI_NAME [$WIFI_IDS] 厂商=$WIFI_VENDOR"
  else
    log " Wi-Fi      : 无（装机走有线，装完再插网卡也不会掉）"
  fi
  log " 蓝牙       : $(_hw_yn "$HAS_BT")    摄像头: $(_hw_yn "$HAS_CAMERA")    WWAN(4G/5G): $(_hw_yn "$HAS_WWAN")"
  log " Bootloader : $BOOTLOADER（安装器不改它）"
  if [ "$IS_VM" -eq 1 ]; then
    log " 提示       : 当前是虚拟机（$VIRT），部分硬件探测结果只代表虚拟硬件"
  fi
  # 需要人工确认的项
  if [ "$HAS_NVIDIA_GPU" -eq 1 ] && [ "$NVIDIA_GEN" = pre_turing ]; then
    log " 注意       : NVIDIA 卡是 Turing 之前的老卡，不能用 nvidia-open-dkms（会加载失败→黑屏）。"
    log "              官方仓库已不提供闭源驱动；要独显请用 --nvidia-legacy（archlinuxcn 的 nvidia-580xx-dkms），"
    log "              不想折腾就保持 nouveau 显示（默认）。"
  fi
  return 0
}

# --------------------------------------------------------------------------
# doctor 复查
# --------------------------------------------------------------------------

_hw_line() {
  # ok(1/0) 标签 详情
  if [ "$1" -eq 1 ]; then
    printf '  [OK]   %s %s\n' "$2" "$3"
  else
    printf '  [MISS] %s %s\n' "$2" "$3"
  fi
}

hw_doctor_check() {
  local pkg state driver ok

  # 1) 微码
  pkg=$(hw_microcode_pkg)
  state=$(hw_microcode_state)
  case "$state" in
    early)
      _hw_line 1 "微码" "$pkg 已在 initramfs 中早期加载"
      ;;
    configured)
      _hw_line 0 "微码" "$pkg 已装但 initramfs 未重建：sudo mkinitcpio -P"
      ;;
    missing)
      if [ -z "$pkg" ]; then
        _hw_line 1 "微码" "CPU 厂商未识别，跳过"
      elif [ "$MICROCODE_HOOK" -eq 1 ]; then
        _hw_line 0 "微码" "没装 $pkg：sudo pacman -S --needed $pkg && sudo mkinitcpio -P"
      else
        _hw_line 0 "微码" "$pkg 未生效：/etc/mkinitcpio.conf 的 HOOKS 里没有 microcode，加上后跑 sudo mkinitcpio -P"
      fi
      ;;
    *)
      _hw_line 1 "微码" "不适用"
      ;;
  esac

  # 2) GPU 驱动是否真的加载了
  for driver in amdgpu i915 xe nouveau nvidia; do
    if [ -d "/sys/module/$driver" ]; then
      _hw_line 1 "GPU 模块" "$driver 已加载"
    fi
  done
  if [ "$HAS_AMD_GPU" -eq 1 ] && [ ! -d /sys/module/amdgpu ]; then
    _hw_line 0 "GPU 模块" "检测到 AMD 显卡但 amdgpu 没加载（检查 linux-firmware / mesa）"
  fi
  if [ "$HAS_INTEL_GPU" -eq 1 ] && [ ! -d /sys/module/i915 ] && [ ! -d /sys/module/xe ]; then
    _hw_line 0 "GPU 模块" "检测到 Intel 显卡但 i915/xe 都没加载"
  fi
  if [ "$HAS_NVIDIA_GPU" -eq 1 ]; then
    if [ -d /sys/module/nvidia ]; then
      _hw_line 1 "NVIDIA" "nvidia 模块已加载（$GPU_NVIDIA_NAME）"
    elif [ "$NVIDIA_GEN" = pre_turing ]; then
      _hw_line 0 "NVIDIA" "$GPU_NVIDIA_NAME 是 Turing 之前的老卡：默认走 nouveau；要独显用 --nvidia-legacy（archlinuxcn nvidia-580xx-dkms）"
    else
      _hw_line 0 "NVIDIA" "检测到 $GPU_NVIDIA_NAME 但 nvidia 模块没加载（nouveau 兜底中）"
    fi
  fi

  # 3) 音频
  ok=0
  if _hw_have systemctl && systemctl --user is-active --quiet wireplumber 2>/dev/null; then
    ok=1
  elif [ -d /sys/module/snd_hda_intel ] || [ -d /sys/module/snd_sof ] || [ -d /sys/module/snd_usb_audio ]; then
    ok=1
  fi
  if [ "$ok" -eq 1 ]; then
    _hw_line 1 "音频" "内核声卡驱动已加载"
  else
    _hw_line 0 "音频" "没看到内核声卡驱动（/proc/asound 为空？检查 sof-firmware / alsa-ucm-conf）"
  fi

  # 4) Wi-Fi / 蓝牙
  if [ "$HAS_WIFI" -eq 1 ]; then
    ok=0
    if _hw_have iw && iw dev 2>/dev/null | grep -q Interface; then ok=1; fi
    if [ -e /sys/class/net/wlan0 ]; then ok=1; fi
    if [ "$ok" -eq 1 ]; then
      _hw_line 1 "Wi-Fi" "$WIFI_NAME 有无线接口"
    else
      _hw_line 0 "Wi-Fi" "$WIFI_NAME 没有无线接口（缺固件或驱动？）"
    fi
  fi
  # 蓝牙服务现在固定安装、固定启用；硬件有无只作为信息展示
  if _hw_have systemctl && systemctl is-enabled --quiet bluetooth 2>/dev/null; then
    _hw_line 1 "蓝牙" "bluetooth.service 已启用（硬件: $(_hw_yn "$HAS_BT")）"
  else
    _hw_line 0 "蓝牙" "bluetooth.service 没启用（sudo systemctl enable --now bluetooth）"
  fi

  # 5) 外设（只保留摄像头；打印/指纹已按用户要求移除）
  if [ "$HAS_CAMERA" -eq 1 ] && ! _hw_have v4l2-ctl; then
    _hw_line 0 "摄像头" "有摄像头但没装 v4l-utils（v4l2-ctl --list-devices 用）"
  fi

  return 0
}

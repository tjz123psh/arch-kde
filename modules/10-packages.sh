#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

AUR_CMD=

# ---------------------------------------------------------------------------
# 硬件策略：探测结果 + 命令行开关 → 最终装哪些驱动包
#
# 为什么把"探测"和"策略"分开：真机上装错驱动的代价是黑屏/断网/没输入，而探测
# （20-hardware.sh，只读 /sys、/proc、lspci）与"决定装什么"是两件事。本文件只读
# 下面这组 WANT_* 布尔量，不再自己判断硬件；40-system.sh 读同一组，保证"装了什么"
# 和"配了什么服务"不会打架。
#
# 六个坑，每一段条件都在防一个真机故障：
#   1. 没显卡却装 nvidia-open-dkms：DKMS 编译失败 / mkinitcpio 找不到模块时
#      initramfs 生成会失败 → 重启黑屏。
#   2. Maxwell/Pascal/Volta（GTX 10 系及更早）装 615 版驱动：模块加载失败，而
#      nvidia-utils 会把 nouveau 拉黑，只剩 TTY。官方仓库自 615 起只有开源内核模块
#      （nvidia-open*），旧卡要用 archlinuxcn 的 nvidia-580xx-*（--nvidia-legacy）。
#   3. 虚拟机里装微码/thermald：微码属于宿主，装进 guest 不会生效。
#   4. tlp 与 power-profiles-daemon 同装：两个都在改电源策略，互相覆盖。
#   5. iwd 与 wpa_supplicant 同装：抢 wlan0，NetworkManager 必须显式切后端。
#   6. AUR 机型固件（broadcom-wl-dkms / rtl8821ce-dkms-git）默认跳过：会和内核自带的
#      brcmfmac / rtw89 抢同一个 PCI 设备，装错的表现是"Wi-Fi 直接消失"。
# ---------------------------------------------------------------------------

# 三态开关：auto = 听探测的；1 = 强制装；0 = 强制不装
: "${HW_MODE:=auto}"              # none | auto | all
: "${HW_GPU_AMD:=auto}"
: "${HW_GPU_INTEL:=auto}"
: "${HW_GPU_NVIDIA:=auto}"
: "${HW_MICROCODE:=auto}"
: "${HW_PRINTERS:=auto}"
: "${HW_FP:=auto}"
: "${HW_WWAN:=auto}"
: "${HW_THERMALD:=auto}"
: "${HW_IRQBALANCE:=0}"
: "${HW_IWD:=0}"
: "${HW_POWER:=ppd}"              # ppd | tlp | none
: "${HW_NVIDIA_DRIVER:=open}"     # open | legacy
: "${HW_NVIDIA_FORCE:=0}"
: "${HW_XORG_NOUVEAU:=0}"
: "${HW_WIFI_AUR:=0}"

# 探测变量兜底：本文件可能被单独 source（tests/package-names.sh），也可能在 hw_detect
# 之前被读到。默认一律当"没有这块硬件"，装出来仍是最小可用系统。
: "${CPU_VENDOR:=unknown}"
: "${IS_VM:=0}"
: "${VIRT:=unknown}"
: "${HAS_AMD_GPU:=0}"
: "${HAS_INTEL_GPU:=0}"
: "${HAS_NVIDIA_GPU:=0}"
: "${HAS_FINGERPRINT:=0}"
: "${HAS_PRINTER:=0}"
: "${HAS_WWAN:=0}"
: "${HAS_CAMERA:=0}"
: "${GPU_NVIDIA_NAME:=}"
: "${NVIDIA_GEN:=unknown}"
: "${WIFI_IDS:=}"
: "${WIFI_NAME:=}"
: "${WIFI_AUR_PKG:=}"

# 策略结果：install.sh 打印、system.sh 配服务、doctor 只按包名复查
WANT_UCODE=0
UCODE_PKG=
WANT_AMD=0
WANT_INTEL=0
WANT_NVIDIA=0
NVIDIA_PKG=nvidia-open-dkms
NVIDIA_LEGACY_PKGS="nvidia-580xx-dkms nvidia-580xx-utils"
NVIDIA_SKIP_REASON=
WANT_XORG_NOUVEAU=0
WANT_PRINTERS=0
WANT_FP=0
WANT_WWAN=0
WANT_THERMALD=0
WANT_IRQBALANCE=0
WANT_IWD=0
WANT_TLP=0
WANT_PPD=0
WANT_WIFI_AUR=0
WIFI_AUR_LIST=

# 只在 archlinuxcn 里的可选应用：archlinuxcn 没配好时逐个跳过，
# 绝不让它们把官方包那条 pacman -S 整条拖垮（原因见 build_official_list 的注释）。
CN_EXTRA_PKGS="flclash nomacs"

# 已装包判断（pacman -Qq 只看本地库，不联网）
pkg_installed() {
  pacman -Qq "$1" >/dev/null 2>&1
}

# 三态 → 0/1：$1=开关（auto/1/0），$2=探测结果（0/1）
hw_pick() {
  case "${1:-auto}" in
    1) echo 1 ;;
    0) echo 0 ;;
    *) if [ "${2:-0}" -eq 1 ]; then echo 1; else echo 0; fi ;;
  esac
}

# 策略层输出：安装流程里有 log/warn 就用，单测里退回 echo
hw_note() {
  if declare -F log >/dev/null 2>&1; then log "$*"; else echo "$*"; fi
}
hw_alert() {
  if declare -F warn >/dev/null 2>&1; then warn "$*"; else echo "[警告] $*" >&2; fi
}

# 策略求解：把"探测到的硬件"与"--hw/--no-* 开关"合成 WANT_* 一组布尔量。
# 必须在 hw_detect 之后、build_official_list 之前调用一次（install.sh 的 main 里）。
hw_policy_resolve() {
  local has_amd="${HAS_AMD_GPU:-0}"
  local has_intel="${HAS_INTEL_GPU:-0}"
  local has_nvidia="${HAS_NVIDIA_GPU:-0}"
  local has_fp="${HAS_FINGERPRINT:-0}"
  local has_printer="${HAS_PRINTER:-0}"
  local has_wwan="${HAS_WWAN:-0}"
  local want_thermald=0

  # --hw none / all：一次性把所有厂商开关拨到底；单厂商开关仍可在之后覆盖
  case "${HW_MODE:-auto}" in
    all)
      has_amd=1; has_intel=1; has_nvidia=1
      has_fp=1; has_printer=1; has_wwan=1
      ;;
    none)
      has_amd=0; has_intel=0; has_nvidia=0
      has_fp=0; has_printer=0; has_wwan=0
      ;;
  esac

  WANT_AMD=$(hw_pick "${HW_GPU_AMD:-auto}" "$has_amd")
  WANT_INTEL=$(hw_pick "${HW_GPU_INTEL:-auto}" "$has_intel")
  WANT_NVIDIA=$(hw_pick "${HW_GPU_NVIDIA:-auto}" "$has_nvidia")

  # ---- NVIDIA：先过代际闸门，再决定装哪个包 ----
  NVIDIA_SKIP_REASON=
  if [ "$WANT_NVIDIA" -eq 1 ] && [ "${NVIDIA_GEN:-unknown}" = pre_turing ] && [ "${HW_NVIDIA_FORCE:-0}" -ne 1 ]; then
    WANT_NVIDIA=0
    NVIDIA_SKIP_REASON="检测到旧架构 NVIDIA 显卡（${GPU_NVIDIA_NAME:-型号未知}），官方 nvidia-open 只支持 Turing（RTX 20 系 / GTX 16 系）及更新"
    hw_alert "$NVIDIA_SKIP_REASON"
    hw_alert "已跳过 NVIDIA 驱动：内核自带的 nouveau 照常显示（能亮，性能低），不会黑屏"
    hw_alert "旧卡想用独显：重跑 ./install.sh --nvidia-legacy（archlinuxcn 的 nvidia-580xx-dkms）；确认要试 nvidia-open 就加 --nvidia-force"
  fi

  if [ "$WANT_NVIDIA" -eq 1 ]; then
    case "${HW_NVIDIA_DRIVER:-open}" in
      legacy)
        NVIDIA_PKG="$NVIDIA_LEGACY_PKGS"
        if [ "${NO_ARCHLINUXCN:-0}" -eq 1 ]; then
          hw_alert "nvidia-580xx 只在 archlinuxcn 仓库里，而本次带了 --no-archlinuxcn：请先配好 archlinuxcn，否则这一步会装失败"
        fi
        ;;
      *)
        NVIDIA_PKG=nvidia-open-dkms
        ;;
    esac
    # 已经装了预编译的 nvidia-open / nvidia-open-lts 时不要再点名 nvidia-open-dkms：
    # 三者 provides 同一个包名，pacman 会因为冲突整条事务失败（一个包都不装）。
    if [ "$NVIDIA_PKG" = nvidia-open-dkms ] && ! pkg_installed nvidia-open-dkms; then
      if pkg_installed nvidia-open || pkg_installed nvidia-open-lts; then
        NVIDIA_PKG=
        hw_note "已装预编译的 nvidia-open/nvidia-open-lts，保留它，不再装 nvidia-open-dkms"
      fi
    fi
  fi

  # ---- CPU 微码 ----
  UCODE_PKG=
  case "${CPU_VENDOR:-unknown}" in
    intel) UCODE_PKG=intel-ucode ;;
    amd)   UCODE_PKG=amd-ucode ;;
  esac
  WANT_UCODE=0
  if [ -n "$UCODE_PKG" ]; then
    if [ "${HW_MODE:-auto}" = none ] && [ "${HW_MICROCODE:-auto}" != 1 ]; then
      hw_note "--hw none：不装 CPU 微码（要装就加 --microcode）"
    elif [ "${IS_VM:-0}" -eq 1 ] && [ "${HW_MICROCODE:-auto}" != 1 ]; then
      hw_note "虚拟机（${VIRT:-unknown}）里跳过 CPU 微码：微码由宿主负责，装进 guest 不会生效"
    else
      WANT_UCODE=$(hw_pick "${HW_MICROCODE:-auto}" 1)
    fi
  elif [ "${HW_MICROCODE:-auto}" = 1 ]; then
    hw_alert "CPU 厂商没识别出来（${CPU_VENDOR:-unknown}），无法在 intel-ucode/amd-ucode 里二选一；请手动装 intel-ucode 或 amd-ucode 之一"
  fi

  # ---- 外设 ----
  WANT_FP=$(hw_pick "${HW_FP:-auto}" "$has_fp")
  WANT_PRINTERS=$(hw_pick "${HW_PRINTERS:-auto}" "$has_printer")
  WANT_WWAN=$(hw_pick "${HW_WWAN:-auto}" "$has_wwan")
  WANT_XORG_NOUVEAU="${HW_XORG_NOUVEAU:-0}"
  WANT_IRQBALANCE="${HW_IRQBALANCE:-0}"
  WANT_IWD="${HW_IWD:-0}"

  # ---- 电源：ppd / tlp / none 三选一，绝不两个都装 ----
  WANT_PPD=0
  WANT_TLP=0
  case "${HW_POWER:-ppd}" in
    tlp) WANT_TLP=1 ;;
    none) ;;
    *) WANT_PPD=1 ;;
  esac

  # thermald 只对 Intel CPU 有意义（AMD 走内核 amd_pstate，thermald 不干活）
  if [ "${CPU_VENDOR:-unknown}" = intel ] && [ "${IS_VM:-0}" -eq 0 ]; then
    want_thermald=1
  fi
  WANT_THERMALD=$(hw_pick "${HW_THERMALD:-auto}" "$want_thermald")

  # ---- AUR 机型固件：默认只提示，不装 ----
  WANT_WIFI_AUR="${HW_WIFI_AUR:-0}"
  WIFI_AUR_LIST=
  if [ -n "${WIFI_AUR_PKG:-}" ]; then
    if [ "$WANT_WIFI_AUR" -eq 1 ]; then
      WIFI_AUR_LIST="$WIFI_AUR_PKG"
    else
      hw_note "无线 ${WIFI_NAME:-未知型号}（${WIFI_IDS:-?}）可能还需要 AUR 机型驱动 ${WIFI_AUR_PKG}；默认跳过（会和内核驱动抢设备），确实不行再加 --wifi-aur"
    fi
  fi

  return 0
}

# 逐行打印"本次到底装什么"，install.sh 的 print_plan 调用（--dry-run 也能看到）
hw_policy_summary() {
  local gpu="" extras="" power=""
  if [ "$WANT_AMD" -eq 1 ]; then gpu="$gpu AMD"; fi
  if [ "$WANT_INTEL" -eq 1 ]; then gpu="$gpu Intel"; fi
  if [ "$WANT_NVIDIA" -eq 1 ]; then
    # 只显示第一个包名（legacy 是两个包）
    gpu="$gpu NVIDIA(${NVIDIA_PKG%% *})"
  fi
  if [ -z "$gpu" ]; then gpu=" 无（只装 mesa/llvmpipe 基础栈）"; fi
  hw_note " 显卡驱动:$gpu"
  if [ "$WANT_UCODE" -eq 1 ]; then
    hw_note " CPU 微码: $UCODE_PKG"
  else
    hw_note " CPU 微码: 不装"
  fi

  extras=""
  if [ "$WANT_PRINTERS" -eq 1 ]; then extras="$extras 打印扫描"; fi
  if [ "$WANT_FP" -eq 1 ]; then extras="$extras 指纹"; fi
  if [ "$WANT_WWAN" -eq 1 ]; then extras="$extras WWAN"; fi
  if [ "$WANT_IWD" -eq 1 ]; then extras="$extras iwd"; fi
  if [ "$WANT_XORG_NOUVEAU" -eq 1 ]; then extras="$extras Xorg-nouveau"; fi
  if [ -n "$WIFI_AUR_LIST" ]; then extras="$extras AUR固件($WIFI_AUR_LIST)"; fi
  hw_note " 额外外设/网络:${extras:- 无}"

  if [ "$WANT_TLP" -eq 1 ]; then power="tlp"; elif [ "$WANT_PPD" -eq 1 ]; then power="power-profiles-daemon"; else power="无"; fi
  if [ "$WANT_THERMALD" -eq 1 ]; then power="$power + thermald"; fi
  if [ "$WANT_IRQBALANCE" -eq 1 ]; then power="$power + irqbalance"; fi
  hw_note " 电源/散热:$power"
}

# ---------------------------------------------------------------------------
# 官方 Arch 镜像列表
#
# archinstall 初始化时选中的镜像（常见是阿里云/境外源）在部分网络下会掉速、
# 单连接卡在几十 B/s。安装器默认把 /etc/pacman.d/mirrorlist 覆盖成国内常用
# 镜像，清华第一（用户指定），后面中科大/阿里云/南大/浙大/兰大。
# 不想覆盖就加 --no-mirrors（例如机器不在中国，或已经用 reflector 配好）。
# 2026-10-19 逐个 HEAD 验证这些镜像的 core.db 返回 200。
# ---------------------------------------------------------------------------
official_mirrorlist() {
  cat <<'EOF'
# Arch Linux 官方镜像列表（KOS 安装器生成，顺序 = 中国网络优先级）
#
# 为什么整份覆盖：archinstall 会按 --mirror-region 或 reflector 自动生成一份
# （本机常见是 aliyun 单源），单源一抽风整装就卡住。安装器默认重写这个文件，
# 原文件在 ~/.local/state/kos-installer/backup/<时间>/etc/pacman.d/mirrorlist。
# 清华第一；想换顺序直接改这个文件，安装器重跑会再次覆盖（降级注释也会复原）。
# 2026-10-21 用 curl 逐个取 core.db 验证，除 163（超时）外全部 200。
# 镜像状态: https://archlinux.org/mirrors/status/
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.aliyun.com/archlinux/$repo/os/$arch
Server = https://mirror.nju.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.sustech.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.cernet.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.cloud.tencent.com/archlinux/$repo/os/$arch
Server = https://repo.huaweicloud.com/archlinux/$repo/os/$arch
Server = https://mirrors.bfsu.edu.cn/archlinux/$repo/os/$arch
Server = https://mirror.sjtu.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.hust.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.xjtu.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.zju.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.lzu.edu.cn/archlinux/$repo/os/$arch
Server = https://mirror.iscas.ac.cn/archlinux/$repo/os/$arch
Server = https://mirrors.jlu.edu.cn/archlinux/$repo/os/$arch
EOF
}

# ---------------------------------------------------------------------------
# 镜像降级（failover）
#
# 国内镜像站偶尔整站抽风：维护、被校园网拦、TLS 证书过期。pacman 自己会在同一个
# 文件里按 Server 顺序回退，但"连得上却一直超时"会拖很久。这里在系统更新或装包
# 失败、且失败原因确实是网络时，把当前排第一的 Server 注释掉再重试，也就是
# "降级到下一个镜像"，最多降 3 次。下一次运行安装器会重写镜像列表，注释自动复原。
# ---------------------------------------------------------------------------

# 失败输出里出现这些才算镜像问题；依赖冲突、包名错重试没有意义
_mirror_network_failure() {
  grep -Eqi 'failed retrieving file|could not resolve host|Connection timed out|Operation too slow|SSL certificate problem|Failed to connect|Could not connect|404' "$1"
}

# 注释掉镜像列表里第一条 Server =（即当前优先级最高的镜像）
_mirror_demote_first() {
  local f="$1" no line
  [ -r "$f" ] || return 1
  no=$(sudo grep -n -m1 '^Server = ' "$f" 2>/dev/null | cut -d: -f1 || true)
  [ -n "$no" ] || return 1
  line=$(sudo sed -n "${no}p" "$f" 2>/dev/null || true)
  warn "镜像降级：跳过 $line（$f 第 $no 行）"
  sudo sed -i "${no}s/^Server = /# 降级跳过: Server = /" "$f" || return 1
}

# pacman_fallback <mirrorlist> <命令...>：失败且是网络原因就降级镜像重试
pacman_fallback() {
  local ml="$1" attempt=1 out rc
  shift
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] $*"
    return 0
  fi
  while :; do
    out=$(mktemp)
    if "$@" 2>&1 | tee -a "$LOG_FILE" | tee "$out"; then
      rm -f "$out"
      return 0
    else
      rc=$?
    fi
    if [ "$attempt" -ge 3 ] || ! _mirror_network_failure "$out"; then
      rm -f "$out"
      return "$rc"
    fi
    rm -f "$out"
    if ! _mirror_demote_first "$ml"; then
      warn "镜像列表里没有可降级的 Server 了（$ml）"
      return "$rc"
    fi
    attempt=$((attempt + 1))
    log "镜像不可用，降级后重试（第 $((attempt - 1)) 次）..."
  done
}

setup_official_mirrors() {
  if [ "$NO_MIRRORS" -eq 1 ]; then
    log "跳过官方镜像列表覆盖（--no-mirrors）"
    return 0
  fi
  log "覆盖官方镜像列表（清华第一 + 15 个国内镜像；archinstall 生成的 aliyun/reflector 列表会被整份替换）..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 写 /etc/pacman.d/mirrorlist（清华第一）"
    return 0
  fi
  official_mirrorlist | sudo_write_file /etc/pacman.d/mirrorlist
  local n
  n=$(sudo grep -c '^Server = ' /etc/pacman.d/mirrorlist 2>/dev/null || true)
  log "官方镜像列表已覆盖：${n:-0} 个镜像，清华第一（archinstall 的 aliyun/reflector 列表已替换）"
  if ! sudo grep -q '^Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/' /etc/pacman.d/mirrorlist; then
    warn "写入后没看到清华源，请手动检查 /etc/pacman.d/mirrorlist"
  fi
}

# ---------------------------------------------------------------------------
# archlinuxcn 中文社区仓库
#
# 中国用户常用（Chrome / VS Code / 字体 / 输入法等）。安装器默认配置，
# 用 --no-archlinuxcn 跳过。镜像顺序按中国网络优先级：清华第一（用户指定），
# 后面是中科大 / 阿里云 / 华为云 / 腾讯云 / 南大 / 浙大，都是长期在线的
# archlinuxcn 镜像。参考 https://www.archlinuxcn.org/archlinux-cn-repo-and-mirror/
# 与 https://mirrors.tuna.tsinghua.edu.cn/help/archlinuxcn/
# ---------------------------------------------------------------------------
archlinuxcn_mirrorlist() {
  cat <<'EOF'
# archlinuxcn 镜像列表（KOS 安装器生成，顺序 = 中国网络优先级）
# 清华第一；想换顺序直接改这个文件，重跑安装器会再次覆盖。
# 2026-10-21 用 curl 逐个取 archlinuxcn.db 验证：zju 超时、sjtu/163 返回 404，未收录。
# 镜像帮助: https://mirrors.tuna.tsinghua.edu.cn/help/archlinuxcn/
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch
Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch
Server = https://mirrors.aliyun.com/archlinuxcn/$arch
Server = https://mirror.nju.edu.cn/archlinuxcn/$arch
Server = https://mirrors.sustech.edu.cn/archlinuxcn/$arch
Server = https://mirrors.cernet.edu.cn/archlinuxcn/$arch
Server = https://mirrors.cloud.tencent.com/archlinuxcn/$arch
Server = https://repo.huaweicloud.com/archlinuxcn/$arch
Server = https://mirrors.bfsu.edu.cn/archlinuxcn/$arch
Server = https://mirrors.lzu.edu.cn/archlinuxcn/$arch
Server = https://mirror.iscas.ac.cn/archlinuxcn/$arch
Server = https://mirrors.hust.edu.cn/archlinuxcn/$arch
EOF
}

setup_archlinuxcn_repo() {
  if [ "$NO_ARCHLINUXCN" -eq 1 ]; then
    log "跳过 archlinuxcn 仓库（--no-archlinuxcn）"
    return 0
  fi
  log "配置 archlinuxcn 镜像源（清华第一 + 11 个国内镜像）..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 写 /etc/pacman.d/archlinuxcn-mirrorlist（清华第一）"
    log "[dry-run] /etc/pacman.conf 追加 [archlinuxcn] Include（已有则保留）"
    log "[dry-run] sudo pacman -Sy --noconfirm archlinuxcn-keyring"
    return 0
  fi

  archlinuxcn_mirrorlist | sudo_write_file /etc/pacman.d/archlinuxcn-mirrorlist
  local cn_n
  cn_n=$(sudo grep -c '^Server = ' /etc/pacman.d/archlinuxcn-mirrorlist 2>/dev/null || true)
  log "archlinuxcn 镜像列表：${cn_n:-0} 个镜像，清华第一"

  # 幂等：已经有 [archlinuxcn] 段就不动（可能是用户自己配的镜像/顺序）
  if grep -q '^\[archlinuxcn\]' /etc/pacman.conf; then
    log "pacman.conf 已有 [archlinuxcn]，保留现有配置"
  else
    backup_file /etc/pacman.conf
    printf '\n[archlinuxcn]\nInclude = /etc/pacman.d/archlinuxcn-mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null
    log "已把 [archlinuxcn] 写入 /etc/pacman.conf"
  fi

  # 官方导入 GPG key 的做法就是装 archlinuxcn-keyring；
  # --noconfirm 会替用户回答"导入 PGP key"的提示。
  if pacman_fallback /etc/pacman.d/archlinuxcn-mirrorlist sudo pacman -Sy --noconfirm archlinuxcn-keyring; then
    log "archlinuxcn-keyring 已安装"
  else
    warn "archlinuxcn-keyring 安装失败；仓库已写入但包签名未信任，稍后手动: sudo pacman -Sy archlinuxcn-keyring"
  fi
}

system_update() {
  if [ "$SKIP_UPDATE" -eq 1 ]; then
    log "跳过 pacman -Syu（--skip-update）"
    return 0
  fi
  log "更新系统（pacman -Syu）..."
  pacman_fallback /etc/pacman.d/mirrorlist sudo pacman -Syu --noconfirm ||
    die "系统更新失败：镜像都不可用或包数据库异常（详见 $LOG_FILE）"
}

build_official_list() {
  local pkgs
  # tesseract 依赖虚拟包 tessdata（有 128 个 provider）。不显式点名的话，
  # pacman -S --noconfirm 会按默认选 tesseract-data-afr（南非荷兰语），
  # 安装日志里还会弹一个英文 provider 选择提示。显式要英文数据，避免歧义。
  # 注意：注释必须放在 pkgs="..." 字符串外面，否则 # 会变成包名（CI 2026-10-19 抓到）。
  pkgs="
plasma-desktop plasma-workspace kwin plasma-integration plasma-pa plasma-nm
powerdevil kscreen polkit-kde-agent xdg-desktop-portal-kde kde-cli-tools
systemsettings kde-gtk-config kdecoration breeze
dolphin kio-extras ark gwenview spectacle plasma-systemmonitor
sddm qt6-tools libxml2
noto-fonts noto-fonts-cjk noto-fonts-emoji inter-font ttf-jetbrains-mono-nerd
fcitx5 fcitx5-configtool fcitx5-gtk fcitx5-qt fcitx5-chinese-addons
fcitx5-pinyin-zhwiki fcitx5-material-color fcitx5-nord fcitx5-lua
kitty fish starship fzf eza bat fd ripgrep zoxide fastfetch
mpv tesseract-data-eng
networkmanager bluez bluez-utils linux-firmware
base-devel git curl jq unzip xdg-utils xdg-user-dirs man-db cmake extra-cmake-modules python
"

  # ---- archinstall 阶段已经装好的基础工具（只做 --needed 兜底）----
  # 这些在干净 archinstall 后通常已经存在，装了就是空操作；写进来是为了防
  # "精简预设 / 别人装的系统"缺件：
  #   neovim        编辑器（本机基线）
  #   os-prober     GRUB 探测其它系统（双系统菜单）
  #   zram-generator archinstall 的 zram 支持（/etc/systemd/zram-generator.conf）
  #   exfatprogs    在下面的存储段（U 盘 exFAT）
  pkgs="$pkgs neovim os-prober zram-generator"

  # ---- 图形基础栈：任何显卡（含虚拟机的 llvmpipe）都要 ----
  # mesa              AMD/Intel 开源驱动 + llvmpipe 软件渲染兜底；没有它 Wayland 起不来
  # vulkan-icd-loader  Vulkan 加载器；vulkan-radeon/intel、nvidia-utils 提供的 ICD 都靠它
  # vulkan-tools      vulkaninfo（doctor 复查显卡用）
  # libva/libva-utils  VA-API 基础库 + vainfo（查硬解，浏览器看视频不卡的前提）
  # 注意 libva-mesa-driver 自 mesa 24.2.7 起已并入 mesa，只剩虚拟名（由 mesa 提供）；
  # 只写实体包，避免以后 provides 改名时整条 pacman 命令失败（CI 2026-10-19 的教训）。
  # ---- 用户自选应用（2026-10-20 用户要求）----
  # yazi      终端文件管理器（Rust，官方仓库）
  # obsidian  Obsidian 笔记（官方仓库）
  # flclash / nomacs 只在 archlinuxcn（2026-10-21 用 pacman -Si 核实过），
  # 不能混进这条 pacman -S：pacman 遇到一个 "target not found" 会整条事务失败，
  # 一个包都不装。它们走下面的 CN_EXTRA_PKGS + install_archlinuxcn_apps()。
  pkgs="$pkgs yazi obsidian"

  # JDK 21：开发用（Arch 的默认 jdk-openjdk 已经是 27，这里显式锁 21 的 LTS）
  pkgs="$pkgs jdk21-openjdk"

  # ---- ASUS ROG 笔记本工具（默认只在 ASUS 机器上装；--no-asus 关，--asus 强开）----
  # asusctl / rog-control-center：风扇曲线、键盘灯、性能模式、MUX 切换（官方仓库）
  # supergfxctl：GPU 模式切换（archlinuxcn）
  local asus=0
  case "$HW_ASUS" in
    0) asus=0 ;;
    1) asus=1 ;;
    *) asus=${HAS_ASUS:-0} ;;
  esac
  if [ "$asus" -eq 1 ]; then
    pkgs="$pkgs asusctl rog-control-center"
    if pacman -Ss '^supergfxctl$' >/dev/null 2>&1; then
      pkgs="$pkgs supergfxctl"
    else
      warn "未找到 supergfxctl（需要 archlinuxcn 源），跳过 GPU 模式切换工具"
    fi
  fi

  pkgs="$pkgs mesa vulkan-icd-loader vulkan-tools libva libva-utils"

  # ---- 声音 ----
  # pipewire/pipewire-pulse/wireplumber：桌面声音服务器（plasma-pa 的后端）
  # pipewire-alsa  让 ALSA 程序走 pipewire；缺了它 aplay 直连声卡，会和 pipewire 抢设备
  # alsa-utils     alsamixer/amixer（音量键或声道不对时的排查工具）
  # alsa-plugins   老程序、部分 Java/游戏只认 ALSA
  # alsa-ucm-conf  笔记本声卡 UCM 配置；缺了大量机型只剩 "Dummy Output"
  # sof-firmware   Intel/AMD 新本子的 SOF DSP 固件；缺了内置麦克风/扬声器不出声
  pkgs="$pkgs pipewire pipewire-pulse wireplumber pipewire-alsa alsa-utils alsa-plugins alsa-ucm-conf sof-firmware"

  # ---- 输入 ----
  # libinput + xf86-input-libinput：触控板/触摸屏（X11 会话要后者）
  # libinput-tools：libinput list-devices（doctor 看输入设备用）
  # 注意 Arch 没有 libinput-utils 这个包；调试工具在 libinput-tools 里。
  pkgs="$pkgs libinput xf86-input-libinput libinput-tools"

  # ---- 摄像头 ----
  # v4l-utils：v4l2-ctl 查摄像头；体积小，检测不到摄像头也留着当工具
  pkgs="$pkgs v4l-utils"

  # ---- 存储 ----
  # udisks2      U 盘/移动硬盘的挂载后端：KDE 设备通知器、Dolphin 侧边栏、托盘"安全移除"都走它。
  #              不装的话插 U 盘只会被内核识别，Dolphin 里点不开（玄学 bug 的常见来源）。
  # dosfstools   FAT32 的 mkfs/fsck（U 盘最常见格式）；exfat 用 exfatprogs，NTFS 用 ntfs-3g
  # exfatprogs/ntfs-3g/btrfs-progs：U 盘、Windows 盘、btrfs 根（archinstall 可能已装）
  # smartmontools/nvme-cli：真机硬盘健康检查（装完 doctor 会提示怎么用）
  # 注意：不装 udiskie（KDE 自己有设备通知器，两个自动挂载会重复弹窗/抢挂载点）
  pkgs="$pkgs udisks2 dosfstools exfatprogs ntfs-3g btrfs-progs smartmontools nvme-cli"

  # ---- 电源/传感器 ----
  # lm_sensors：sensors 命令（温度、风扇）
  pkgs="$pkgs lm_sensors"
  if [ "$WANT_PPD" -eq 1 ]; then
    # power-profiles-daemon：KDE 电源模式（平衡/性能/省电）的后端，powerdevil 需要
    pkgs="$pkgs power-profiles-daemon"
  fi
  if [ "$WANT_TLP" -eq 1 ]; then
    # tlp 与 power-profiles-daemon 二选一（都改 CPU/磁盘/无线电源策略，同装互相覆盖）
    pkgs="$pkgs tlp"
  fi
  if [ "$WANT_THERMALD" -eq 1 ]; then
    # thermald：只有 Intel CPU 用；AMD 靠内核 amd_pstate，装了不干活
    pkgs="$pkgs thermald"
  fi
  if [ "$WANT_IRQBALANCE" -eq 1 ]; then
    # irqbalance：可选（多核/服务器分摊中断；笔记本收益不明显，默认不装）
    pkgs="$pkgs irqbalance"
  fi

  # ---- 网络 ----
  # iw：iw dev / iw link（排查无线时唯一可靠的命令；tlp 也依赖它）
  pkgs="$pkgs iw"
  if [ "$WANT_WWAN" -eq 1 ]; then
    # modemmanager：WWAN/4G 模块（笔记本自带 LTE、USB 上网卡）
    # usb_modeswitch：很多 USB 上网卡插上先是"U 盘"模式，靠它切到调制解调器模式
    # mobile-broadband-provider-info：运营商 APN 数据库（ModemManager 要用）
    pkgs="$pkgs modemmanager usb_modeswitch mobile-broadband-provider-info"
  fi
  if [ "$WANT_IWD" -eq 1 ]; then
    # iwd 默认不装：它和 wpa_supplicant 抢 wlan0，NetworkManager 必须显式切
    # wifi.backend=iwd（40-system.sh::network_backend 会写）。装错的表现是"Wi-Fi 列表空"。
    pkgs="$pkgs iwd"
  fi

  # ---- 指纹 ----
  if [ "$WANT_FP" -eq 1 ]; then
    # fprintd/libfprint：指纹认证。安装器只装包 + 打印 PAM 接法，不动 /etc/pam.d/sddm
    #（PAM 改错会直接登录不了）；接法由 40-system.sh::fprintd_hint 在安装结束时打印。
    pkgs="$pkgs fprintd libfprint"
  fi

  # ---- 打印/扫描 ----
  if [ "$WANT_PRINTERS" -eq 1 ]; then
    # cups + cups-pdf：打印系统 + 虚拟 PDF 打印机
    # sane + sane-airscan：扫描仪 + 免驱网络扫描（airscan 靠 avahi 的 mDNS 发现）
    # print-manager：KDE 的打印机设置面板（否则只能开 localhost:631）
    pkgs="$pkgs cups cups-pdf sane sane-airscan avahi print-manager"
  fi

  # ---- CPU 微码 ----
  if [ "$WANT_UCODE" -eq 1 ] && [ -n "$UCODE_PKG" ]; then
    # intel-ucode / amd-ucode：包只把 payload 放进 /boot 与 /usr/lib/firmware；
    # 真正的"早加载"靠 mkinitcpio 的 microcode hook（Arch 默认已有）→ 合并 initramfs，
    # 不需要改 bootloader。40-system.sh::microcode_setup 会复查是否真的进去了。
    pkgs="$pkgs $UCODE_PKG"
  fi

  # ---- 显卡 ----
  if [ "$WANT_AMD" -eq 1 ]; then
    # vulkan-radeon：AMD 的 RADV（Vulkan）
    # xf86-video-amdgpu：只有 X11 会话用得到；Wayland 下不加载，留作 X11 回退
    #（libva-mesa-driver 已并入 mesa，见上面的说明）
    pkgs="$pkgs vulkan-radeon xf86-video-amdgpu"
  fi
  if [ "$WANT_INTEL" -eq 1 ]; then
    # vulkan-intel：Intel 的 ANV（Vulkan）
    # intel-media-driver：Gen8（Broadwell）及更新的 VA-API 后端，硬解 H.264/HEVC/AV1 必需
    # libva-intel-driver：Gen7 及更老的 i965 后端（老机器才用得到）
    # xf86-video-intel：X11 回退（Wayland 用内核 modesetting）；有已知撕裂问题，仅兜底
    pkgs="$pkgs vulkan-intel intel-media-driver libva-intel-driver xf86-video-intel"
  fi
  if [ "$WANT_NVIDIA" -eq 1 ]; then
    # NVIDIA_PKG = nvidia-open-dkms（Turing 及更新，官方开源内核模块；官方仓库已无闭源替代）
    #            或 nvidia-580xx-dkms + nvidia-580xx-utils（--nvidia-legacy，旧卡，archlinuxcn）
    # nvidia-utils       用户态驱动（libGLX/Vulkan/OpenCL）；它自己依赖 egl-wayland、
    #                    egl-wayland2、egl-gbm、egl-x11，所以不必再点名
    # libva-nvidia-driver  NVDEC 的 VA-API 翻译层（浏览器/播放器硬解）
    # nvidia-prime       prime-run 双显卡切换（本子上用独显跑单个程序）
    # dkms               DKMS 框架（内核升级后自动重编）
    pkgs="$pkgs $NVIDIA_PKG nvidia-utils libva-nvidia-driver nvidia-prime dkms"
  fi
  if [ "$WANT_XORG_NOUVEAU" -eq 1 ]; then
    # 仅在 --xorg-nouveau 时：X11 下用 nouveau 救急。注意 nvidia-utils 会把 nouveau
    # 拉黑，两者同时装只有一个能生效（切换：卸掉 nvidia-utils 后 nouveau 才会重新可用）。
    pkgs="$pkgs xf86-video-nouveau"
  fi

  # 内核 headers：DKMS 编译前提（NVIDIA 或任何 AUR 机型驱动都依赖它）
  pkgs="$pkgs $HEADERS"

  if [ "$IME" = rime ]; then
    pkgs="$pkgs fcitx5-rime"
  fi

  PKGS="$pkgs"
}

# archlinuxcn 可选应用：仓库里没有就跳过并说清楚，不影响其余安装。
# 用 pacman -Si 判断"当前配置的仓库里有没有"，而不是猜它该在哪个仓库。
install_archlinuxcn_apps() {
  local p skipped=
  [ -n "${CN_EXTRA_PKGS:-}" ] || return 0
  log "检查 archlinuxcn 可选应用（${CN_EXTRA_PKGS}）..."
  for p in $CN_EXTRA_PKGS; do
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[dry-run] pacman -Si $p 成功则 sudo pacman -S --needed --noconfirm $p"
      continue
    fi
    if ! pacman -Si "$p" >/dev/null 2>&1; then
      warn "跳过 $p：当前仓库里没有它（archlinuxcn 没配？见 --no-archlinuxcn）"
      skipped="$skipped $p"
      continue
    fi
    pacman_fallback /etc/pacman.d/archlinuxcn-mirrorlist sudo pacman -S --needed --noconfirm "$p" ||
      warn "安装 $p 失败，跳过"
  done
  if [ -n "$skipped" ]; then
    warn "未安装的可选应用:$skipped（配好 archlinuxcn 后手动 sudo pacman -S$skipped）"
  fi
}

install_official_packages() {
  build_official_list
  log "安装官方仓库包..."
  if [ "$DRY_RUN" -eq 1 ]; then
    # 这里不要再用 head 截断：写端被 SIGPIPE 打断，pipefail 下整个 dry-run 会失败
    #（包一多就必现，包越多越难查）。全量打印，行数就是真实包数。
    log "[dry-run] sudo pacman -S --needed --noconfirm <全部官方包，$(echo "$PKGS" | wc -w) 个>"
    for p in $PKGS; do echo "  $p"; done | tee -a "$LOG_FILE"
    return 0
  fi
  # shellcheck disable=SC2086
  pacman_fallback /etc/pacman.d/mirrorlist sudo pacman -S --needed --noconfirm $PKGS ||
    die "官方包安装失败（详见 $LOG_FILE）"
}

setup_aur_helper() {
  if [ "$NO_AUR" -eq 1 ]; then
    log "跳过 AUR（--no-aur）"
    return 0
  fi
  if have paru; then
    AUR_CMD=paru
  elif have yay; then
    AUR_CMD=yay
  else
    log "未找到 paru/yay，构建 yay-bin ..."
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[dry-run] 构建 yay-bin"
      AUR_CMD=yay
      return 0
    fi
    local cache="$HOME/.cache/kos-installer/aur"
    mkdir -p "$cache"
    if [ ! -d "$cache/yay-bin" ]; then
      git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$cache/yay-bin"
    fi
    ( cd "$cache/yay-bin" && makepkg -si --noconfirm )
    AUR_CMD=yay
  fi
  log "AUR helper: $AUR_CMD"
}

install_aur_packages() {
  if [ "$NO_AUR" -eq 1 ]; then return 0; fi
  local list pkg failed
  # 外观三件套要和 assets/config/gtk/settings.ini、environment/90-kos.conf 里的
  # 名字对得上：图标 WhiteSur、光标 WhiteSur-cursors、GTK 主题 WhiteSur-Light。
  list="whitesur-icon-theme whitesur-cursor-theme-git whitesur-gtk-theme"
  list="$list maplemono-nf-cn"
  list="$list fcitx5-pinyin-moegirl fcitx5-pinyin-custom-pinyin-dictionary"

  # 中文应用（2026-10-20 用户指定）：QQ（官方版 + Wayland 修复版）、微信、MusicFree
  # linuxqq-wayland-fix 修了 Wayland 下屏幕共享/共享声音/剪贴板；两个都装，
  # 但只把修复版暴露到菜单里。安装器只装包，不做桌面文件改写 ——
  # 菜单去重（老项目的 fix_china_app_launchers）没有移植过来，属于已知缺口。
  list="$list linuxqq linuxqq-wayland-fix wechat-bin musicfree-desktop-wayland-bin"

  # 命令行 AI 工具（2026-10-21 用户指定）：pi 与 opencode。上游只发二进制，
  # AUR 里对应 pi-bin / opencode-bin（装完各占 ~109 / ~177 MiB）。
  list="$list pi-bin opencode-bin"

  if [ "$NO_BROWSER" -eq 0 ]; then
    list="$list google-chrome"
  fi
  if [ "$NO_VSCODE" -eq 0 ]; then
    list="$list visual-studio-code-bin"
  fi
  if [ "$IME" = rime ]; then
    list="$list rime-ice-git"
  fi
  if [ "$WANT_WIFI_AUR" -eq 1 ] && [ -n "$WIFI_AUR_LIST" ]; then
    # 机型特定的 AUR 无线驱动/固件（broadcom-wl-dkms、rtl8821ce-dkms-git 等），
    # 只有 --wifi-aur 才装：装错会和内核自带的 brcmfmac/rtw89 抢同一个设备，
    # 表现是"Wi-Fi 列表直接空掉"，比不装更难救。
    list="$list $WIFI_AUR_LIST"
  fi

  failed=
  log "安装 AUR 包..."
  for pkg in $list; do
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[dry-run] $AUR_CMD -S --needed --noconfirm $pkg"
      continue
    fi
    if ! "$AUR_CMD" -S --needed --noconfirm "$pkg"; then
      warn "AUR 包失败: $pkg"
      failed="$failed $pkg"
    fi
  done
  if [ -n "$failed" ]; then
    warn "以下 AUR 包安装失败，可稍后手动重试:$failed"
  fi
}

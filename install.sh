#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# KOS 桌面安装器（Arch Linux）
#
# 目标：一台能登录 TTY 的干净 Arch → 完整可用的 KOS 桌面。
# 结构：install.sh（调度） + modules/*.sh（阶段） + assets/（配置、壁纸、genie 源码）
#
# 用法（以桌面用户身份运行，不要 sudo）：
#   bash install.sh --check          # 只预检，不改系统
#   bash install.sh                  # 标准安装
#   bash install.sh --all --start    # 含独立应用/锁屏，装完立即生效
#
set -Eeuo pipefail
export LC_ALL=C

INSTALLER_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export INSTALLER_DIR
export ASSET_DIR="$INSTALLER_DIR/assets"
export CONFIG_DIR="$ASSET_DIR/config"

DRY_RUN=0
ASSUME_YES=0
CHECK_ONLY=0
VERBOSE=0
SKIP_UPDATE=0
NO_AUR=0
NO_MIRRORS=0
NO_ARCHLINUXCN=0
NO_SDDM_THEME=0
NO_BROWSER=0
NO_VSCODE=0
KOS_WITH_APPS=1
KOS_WITH_LOCKSCREEN=1
KOS_START=0
KOS_SPATIAL=0
IME=fcitx5
LOCALE_MODE=en
HW_ASUS=auto

source "$INSTALLER_DIR/lib/common.sh"
for _m in "$INSTALLER_DIR"/modules/*.sh; do
  # shellcheck source=/dev/null
  source "$_m"
done
unset _m

usage() {
  cat <<'USAGE'
用法: bash install.sh [选项]

预检与协助:
  --check            只做预检并报告，不改动系统
  -y, --yes          全程不询问
  --dry-run          打印将要执行的命令，不落盘
  --verbose          打印每条命令

装什么:
  --all              默认已是全装；保留该参数用于显式表达
  --no-apps          不装独立应用（日历/计算器/待办/天气）
  --no-lockscreen    不装 KOS 锁屏
  --start            安装完成后立即启动 KOS shell
  --spatial          同时构建空间/景深（会装 OpenCV + ONNX Runtime，默认关闭）
  --ime fcitx5|rime|none
  --locale en|zh

跳过:
  --no-sddm-theme    不改 SDDM 登录主题
  --no-aur           不用 AUR（会失去图标主题、SDDM 主题等）
  --no-mirrors       不改 pacman 镜像
  --no-archlinuxcn   不加 archlinuxcn 源
  --no-browser       不装 Chrome
  --no-vscode        不装 VS Code
  --skip-update      不更新 KOS 源码（离线安装）

硬件与驱动（探测在 modules/20-hardware.sh，策略在 modules/10-packages.sh）:
  --hw none|auto|all
  --no-gpu-amd --no-gpu-intel --no-gpu-nvidia --nvidia-legacy --no-microcode
  --no-printers --no-fp --no-wwan --power ppd|tlp|none
  --wifi-aur         允许装机型专属 AUR 无线驱动（会和内核驱动抢设备，默认不开）
  --asus             ASUS 机型额外服务（asusd / supergfxd）；默认按主板厂商自动判断
  --no-asus          即使认到 ASUS 也不装这些

环境变量:
  KOS_SRC_DIR        KOS 源码检出位置（默认 ~/.cache/kos-src）
  KOS_REPO_DIR       已有的 KOS 源码检出，设置后不再克隆
  KOS_SRC_URL        源码仓库地址（默认上游仓库）
  KOS_SRC_REF        源码分支或标签（默认 main）

  -h, --help         显示本帮助
USAGE
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) CHECK_ONLY=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --verbose) VERBOSE=1 ;;
      --all) KOS_WITH_APPS=1; KOS_WITH_LOCKSCREEN=1 ;;
      --no-apps) KOS_WITH_APPS=0 ;;
      --no-lockscreen) KOS_WITH_LOCKSCREEN=0 ;;
      --start) KOS_START=1 ;;
      --spatial) KOS_SPATIAL=1 ;;
      --ime) shift; IME="${1:?--ime 需要参数}" ;;
      --locale) shift; LOCALE_MODE="${1:?--locale 需要参数}" ;;
      --no-sddm-theme) NO_SDDM_THEME=1 ;;
      --no-aur) NO_AUR=1 ;;
      --no-mirrors) NO_MIRRORS=1 ;;
      --no-archlinuxcn) NO_ARCHLINUXCN=1 ;;
      --no-browser) NO_BROWSER=1 ;;
      --no-vscode) NO_VSCODE=1 ;;
      --skip-update) SKIP_UPDATE=1 ;;
      --hw) shift; HW_MODE="${1:?--hw 需要 none|auto|all}" ;;
      --no-gpu-amd) HW_GPU_AMD=0 ;;
      --no-gpu-intel) HW_GPU_INTEL=0 ;;
      --no-gpu-nvidia) HW_GPU_NVIDIA=0 ;;
      --nvidia-legacy|--nvidia-closed) HW_NVIDIA_DRIVER=legacy ;;
      --no-microcode) HW_MICROCODE=0 ;;
      --no-printers) HW_PRINTERS=0 ;;
      --no-fp) HW_FP=0 ;;
      --no-wwan) HW_WWAN=0 ;;
      # 10-packages.sh / 20-hardware.sh 的提示会叫用户"加 --wifi-aur"，
      # 这个开关必须真的存在，否则照做的人只会拿到"未知参数"。
      --wifi-aur) HW_WIFI_AUR=1 ;;
      # 摄像头没有对应的可选包（v4l-utils 只是排查工具），保留这个参数只为
      # 不打断已经在用的命令行；它不产生动作，也不再出现在 --help 里。
      --no-camera) : ;;
      --power) shift; HW_POWER="${1:?--power 需要 ppd|tlp|none}" ;;
      --asus) HW_ASUS=1 ;;
      --no-asus) HW_ASUS=0 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "未知参数: $1" ;;
    esac
    shift
  done
}

print_plan() {
  log "============================================================"
  log " KOS 桌面安装计划"
  log " 安装器: $INSTALLER_DIR"
  log " KOS 源码: $(kos_repo_dir)（来自 $KOS_SRC_URL）"
  log " 输入法: $IME   语言: $LOCALE_MODE"
  log " 独立应用: $([ "$KOS_WITH_APPS" -eq 1 ] && echo 是 || echo 否)   锁屏: $([ "$KOS_WITH_LOCKSCREEN" -eq 1 ] && echo 是 || echo 否)"
  log " SDDM 主题: $([ "$NO_SDDM_THEME" -eq 1 ] && echo 保留现有 || echo SilentSDDM)"
  log " 空间景深: $([ "$KOS_SPATIAL" -eq 1 ] && echo 构建 || echo 跳过)"
  log " 动效: genie 最小化（归档原生插件）+ KOS 玻璃"
  if declare -F hw_report >/dev/null 2>&1; then hw_report; fi
  log " 不改动: 分区 / 内核 / 时区 / bootloader"
  log "============================================================"
}

summary() {
  log "============================================================"
  log " 安装完成"
  log " 下一步："
  log "   1. 注销并重新登录（KWin 插件与 KOS 外壳需要新会话）"
  log "   2. 检查：$(kos_repo_dir)/tools/kosctl version && $(kos_repo_dir)/tools/kosctl doctor"
  log "   3. 外观：设置 → 窗口与动效 / 控制中心"
  log " 日志: $LOG_FILE"
  log "============================================================"
}

main() {
  parse_args "$@"
  init_state
  preflight
  hw_policy_resolve
  print_plan

  if [ "$CHECK_ONLY" -eq 1 ]; then
    log "预检完成（--check，未改动系统）"
    run_doctor quick || true
    exit 0
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    confirm "确认开始安装？" || die "已取消"
    start_sudo_keepalive
  fi

  setup_official_mirrors
  setup_archlinuxcn_repo
  system_update
  install_official_packages
  setup_locale
  setup_aur_helper
  install_aur_packages
  setup_system
  setup_ime
  setup_terminal

  install_kos_deps
  fetch_kos_source
  build_install_kos
  build_genie_effect
  setup_sddm_theme
  install_desktop_config
  install_wallpapers

  run_doctor quick || true
  summary
}

trap cleanup EXIT
main "$@"

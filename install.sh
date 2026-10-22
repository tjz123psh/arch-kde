#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# KOS 桌面安装器（Arch Linux）
#
# 目标：一台能登录 TTY 的干净 Arch → 完整可用的 KOS 桌面。
# 结构：install.sh（调度） + modules/*.sh（阶段） + assets/（配置、壁纸）
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
CLEAN_OLD=0
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
HW_ASUS=1

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
  --clean-old-desktop  卸载旧桌面（linux-macos）遗留的专属包（默认不删）

硬件与驱动（固定按目标机 ASUS TUF A15；名单在 modules/10-packages.sh）:
  --no-gpu-amd --no-gpu-nvidia   手动去掉某个厂商的驱动
  --nvidia-legacy    旧 NVIDIA 卡用 archlinuxcn 的 nvidia-580xx（默认 nvidia-open-dkms）
  --power ppd|tlp|none
  --asus / --no-asus  ASUS 工具（asusctl / rog-control-center / supergfxctl，默认装）

环境变量:
  KOS_SRC_DIR        KOS 源码检出位置（默认 ~/.cache/kos-src）
  KOS_REPO_DIR       已有的 KOS 源码检出，设置后不再克隆
  KOS_SRC_URL        源码仓库地址（默认上游仓库）
  KOS_SRC_REF        源码分支或标签（默认自动解析最新稳定发布；开发版用 main）

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
      --clean-old-desktop) CLEAN_OLD=1 ;;
      --no-gpu-amd) HW_GPU_AMD=0 ;;
      --no-gpu-nvidia) HW_GPU_NVIDIA=0 ;;
      --nvidia-legacy|--nvidia-closed) HW_NVIDIA_DRIVER=legacy ;;
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
  log " 旧桌面清理: $([ "$CLEAN_OLD" -eq 1 ] && echo 卸载旧桌面专属包 || echo 不做)"
  log " 动效: KOS 玻璃（genie 已停用，源码归档在 genie-effect-2026-10-21.tar.gz）"
  if declare -F hw_report >/dev/null 2>&1; then hw_report; fi
  if declare -F hw_policy_summary >/dev/null 2>&1; then hw_policy_summary; fi
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

  cleanup_old_desktop
  setup_official_mirrors
  setup_archlinuxcn_repo
  setup_multilib
  system_update
  install_official_packages
  install_archlinuxcn_apps
  setup_locale
  setup_aur_helper
  install_aur_packages
  setup_system
  setup_ime
  setup_terminal
  install_user_configs
  fix_qq_launcher
  install_vellum

  install_kos_deps
  fetch_kos_source
  # 必须在 KOS shell 首次启动前预置，否则默认的彩色组件会被写成用户配置。
  seed_kos_widget_style
  seed_kos_dock_visibility
  configure_launcher_shortcuts
  build_install_kos
  setup_sddm_theme
  install_desktop_config
  install_wallpapers
  install_user_scripts || warn "维护/包管理脚本安装失败，可稍后重跑"
  install_kde_shortcuts || warn "KDE 快捷键配置失败，可稍后重跑"
  install_wallpaper_shortcut || warn "壁纸快捷键配置失败，可稍后重跑"
  install_vellum_shortcuts || warn "Vellum 快捷键配置失败，可稍后重跑"
  configure_keyboard_repeat || warn "键盘重复设置失败，可稍后重跑"

  run_doctor quick || true
  summary
}

trap cleanup EXIT
main "$@"

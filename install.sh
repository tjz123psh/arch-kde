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
# 无 TTY 的环境（例如通过 ssh 远程跑安装器）没有 TERM，makepkg 构建某些 AUR 包
#（WhiteSur 主题的 install.sh 会调用 setterm/tput）会直接失败；这里兜底一个值。
export TERM="${TERM:-xterm-256color}"

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
Usage: bash install.sh [options]

Preflight and help:
  --check            Preflight only; report and exit without changing anything
  -y, --yes          Never prompt
  --dry-run          Print the commands instead of running them
  --verbose          Echo every command

What gets installed:
  --all              Full install (the default); kept for explicitness
  --no-apps          Skip standalone apps (calendar / calculator / todo / weather)
  --no-lockscreen    Skip the KOS lock screen
  --start            Start the KOS shell right after installing
  --spatial          Also build spatial depth (installs OpenCV + ONNX Runtime; off by default)
  --ime fcitx5|rime|none
  --locale en|zh

Skip:
  --no-sddm-theme    Leave the SDDM login theme alone
  --no-aur           Do not use the AUR (loses the icon theme, SDDM theme, ...)
  --no-mirrors       Do not rewrite the pacman mirrorlist
  --no-archlinuxcn   Do not add the archlinuxcn repository
  --no-browser       Do not install Chrome
  --no-vscode        Do not install VS Code
  --skip-update      Do not update the KOS source (offline install)
  --clean-old-desktop  Remove packages left over from the old linux-macos desktop (off by default)

Hardware and drivers (fixed for the target machine, ASUS TUF A15; list lives in modules/10-packages.sh):
  --no-gpu-amd --no-gpu-nvidia   Drop one vendor's driver
  --nvidia-legacy    Use nvidia-580xx from archlinuxcn for older NVIDIA cards (default: nvidia-open-dkms)
  --power ppd|tlp|none
  --asus / --no-asus  ASUS tools (asusctl / rog-control-center / supergfxctl; installed by default)

Environment:
  KOS_SRC_DIR        Where the KOS source is checked out (default ~/.cache/kos-src)
  KOS_REPO_DIR       Use an existing KOS checkout instead of cloning
  KOS_SRC_URL        Source repository URL (default: upstream)
  KOS_SRC_REF        Source branch or tag (default: newest stable release; use main for development)

Undo:
  --undo [args...]   Restore what the installer changed, then exit. Without args
                     it lists the backup runs; see `bash install.sh --undo --help`.
                     Snapshot rollback: kos-undo snapshot <N> (Snapper).

  -h, --help         Show this help
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
      --ime) shift; IME="${1:?--ime needs a value}" ;;
      --undo) shift; exec bash "$ASSET_DIR/scripts/maintenance/kos-undo" "$@" ;;
      --locale) shift; LOCALE_MODE="${1:?--locale needs a value}" ;;
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
      --power) shift; HW_POWER="${1:?--power needs ppd|tlp|none}" ;;
      --asus) HW_ASUS=1 ;;
      --no-asus) HW_ASUS=0 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown option: $1" ;;
    esac
    shift
  done
}

print_plan() {
  log "============================================================"
  log " KOS desktop installation plan"
  log " Installer: $INSTALLER_DIR"
  log " KOS source: $(kos_repo_dir) (from $KOS_SRC_URL)"
  log " Input method: $IME   Locale: $LOCALE_MODE"
  log " Standalone apps: $([ "$KOS_WITH_APPS" -eq 1 ] && echo yes || echo no)   Lock screen: $([ "$KOS_WITH_LOCKSCREEN" -eq 1 ] && echo yes || echo no)"
  log " SDDM theme: $([ "$NO_SDDM_THEME" -eq 1 ] && echo keep-current || echo SilentSDDM)"
  log " Spatial depth: $([ "$KOS_SPATIAL" -eq 1 ] && echo build || echo skip)"
  log " Old-desktop cleanup: $([ "$CLEAN_OLD" -eq 1 ] && echo remove-old-packages || echo none)"
  log " Effects: KOS window animation (genie) + glass + KDE wobbly windows"
  if declare -F hw_report >/dev/null 2>&1; then hw_report; fi
  if declare -F hw_policy_summary >/dev/null 2>&1; then hw_policy_summary; fi
  log " Not touched: partitions / kernel / timezone / bootloader"
  log "============================================================"
}

summary() {
  log "============================================================"
  log " Installation complete"
  log " Next steps:"
  log "   1. Log out and back in (KWin plugins and the KOS shell need a fresh session)"
  log "   2. Verify: $(kos_repo_dir)/tools/kosctl version && $(kos_repo_dir)/tools/kosctl doctor"
  log "   3. Look and feel: System Settings -> Window Effects / Control Center"
  log " Log: $LOG_FILE"
  log "============================================================"
}

main() {
  parse_args "$@"
  init_state
  record_baseline
  preflight
  hw_policy_resolve
  print_plan

  if [ "$CHECK_ONLY" -eq 1 ]; then
    log "Preflight finished (--check, nothing changed)"
    run_doctor quick || true
    exit 0
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    confirm "Start the installation?" || die "Cancelled"
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
  setup_grub_theme
  setup_hotspot_dispatcher
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
  seed_kos_widget_layout
  configure_launcher_shortcuts
  build_install_kos
  setup_sddm_theme
  install_desktop_config
  install_wallpapers
  install_user_scripts || warn "Maintenance/package scripts failed to install; rerun later"
  install_kde_shortcuts || warn "KDE shortcuts setup failed; rerun later"
  install_wallpaper_shortcut || warn "Wallpaper shortcut setup failed; rerun later"
  install_vellum_shortcuts || warn "Vellum shortcuts setup failed; rerun later"
  install_shortcut_viewer_shortcut || warn "Shortcut viewer setup failed; rerun later"
  install_record_menu_shortcut || warn "Record menu shortcut setup failed; rerun later"
  install_hotspot_shortcut || warn "Hotspot menu shortcut setup failed; rerun later"
  configure_keyboard_repeat || warn "Keyboard repeat setup failed; rerun later"

  run_doctor quick || true
  summary
}

trap cleanup EXIT
main "$@"

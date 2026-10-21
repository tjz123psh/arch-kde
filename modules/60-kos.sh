#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# KOS 桌面主体（上游仓库自己的那部分）：
#   构建依赖 → 取源码 → kosctl doctor/install → 独立应用/锁屏 → 全局快捷键
#
# 本仓库只放安装脚本，桌面本体（Quickshell 界面、kosctl、KWin 插件）在上游仓库，
# 装的时候克隆到 KOS_SRC_DIR。本地开发已有检出时，用 KOS_REPO_DIR 指过去即可跳过克隆。

KOS_SRC_URL="${KOS_SRC_URL:-https://github.com/SuceV587/NextKde.git}"
KOS_SRC_REF="${KOS_SRC_REF:-main}"
KOS_SRC_DIR="${KOS_SRC_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/kos-src}"

kos_repo_dir() {
  if [ -n "${KOS_REPO_DIR:-}" ]; then printf '%s' "$KOS_REPO_DIR"; else printf '%s' "$KOS_SRC_DIR"; fi
}

# 来自 KOS 仓库 docs/GettingStarted 的 Arch 依赖清单
kos_dep_list() {
  printf '%s\n' \
    git quickshell cmake ninja gcc qt6-base qt6-declarative qt6-tools qt6-translations \
    qt6-quick3d qt6-svg qt6-imageformats qt6-5compat qt6-wayland go curl \
    extra-cmake-modules wayland kwindowsystem kiconthemes kglobalaccel kio patchelf \
    kwin kconfig ki18n kguiaddons kcmutils kcoreaddons kdecoration gettext libxcb \
    vulkan-headers

  # 空间景深要多两样：深度引擎要 OpenCV + ONNX Runtime（Arch 的包名是
  # onnxruntime-cpu）。缺了它们 CMake 会静默跳过，所以 --spatial 时显式列出来。
  if [ "${KOS_SPATIAL:-0}" -eq 1 ]; then
    printf '%s\n' opencv onnxruntime-cpu
  fi
}

install_kos_deps() {
  log "检查 KOS 构建依赖..."
  local p missing=()
  while read -r p; do
    [ -n "$p" ] || continue
    pkg_installed "$p" || missing+=("$p")
  done < <(kos_dep_list)
  if [ ${#missing[@]} -eq 0 ]; then
    log "构建依赖已齐"
    return 0
  fi
  log "安装缺失依赖：${missing[*]}"
  sudo_run pacman -S --needed --noconfirm "${missing[@]}"
}

fetch_kos_source() {
  local dir; dir=$(kos_repo_dir)

  if [ -d "$dir/.git" ]; then
    log "KOS 源码已存在：$dir"
    if [ "$SKIP_UPDATE" -eq 1 ]; then
      log "跳过源码更新（--skip-update）"
      return 0
    fi
    log "更新 KOS 源码（$KOS_SRC_REF）..."
    run git -C "$dir" fetch --depth 1 origin "$KOS_SRC_REF" || warn "拉取失败，继续用现有源码"
    run git -C "$dir" checkout -q FETCH_HEAD || warn "切到最新源码失败，继续用现有源码"
    return 0
  fi

  log "克隆 KOS 源码：$KOS_SRC_URL（$KOS_SRC_REF）→ $dir"
  run mkdir -p "$(dirname "$dir")"
  run git clone --depth 1 --branch "$KOS_SRC_REF" "$KOS_SRC_URL" "$dir" ||
    die "克隆 KOS 源码失败：$KOS_SRC_URL（可离线预置到 $dir，或用 KOS_REPO_DIR 指定已有检出）"
}

build_install_kos() {
  local repo; repo=$(kos_repo_dir)
  local spatial=OFF
  [ "${KOS_SPATIAL:-0}" -eq 1 ] && spatial=ON

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] $repo/tools/kosctl doctor"
    log "[dry-run] env KOS_BUILD_SPATIAL=$spatial $repo/tools/kosctl install"
    [ "$KOS_WITH_APPS" -eq 1 ] && log "[dry-run] $repo/tools/kosctl install apps"
    [ "$KOS_WITH_LOCKSCREEN" -eq 1 ] && log "[dry-run] $repo/tools/kosctl install lockscreen"
    log "[dry-run] $repo/tools/kosctl shortcuts install"
    [ "$KOS_START" -eq 1 ] && log "[dry-run] $repo/tools/kosctl start"
    return 0
  fi

  [ -x "$repo/tools/kosctl" ] || die "找不到 kosctl：$repo/tools/kosctl（源码没下载成功？）"

  log "KOS 源码：$repo"
  run "$repo/tools/kosctl" doctor || warn "doctor 报告缺项，继续（详见上方输出）"

  log "构建 + 安装 KOS 核心（KOS_BUILD_SPATIAL=$spatial）"
  run env KOS_BUILD_SPATIAL="$spatial" "$repo/tools/kosctl" install || die "kosctl install 失败"

  if [ "$KOS_WITH_APPS" -eq 1 ]; then
    log "安装独立应用（日历/计算器/待办/天气）"
    run "$repo/tools/kosctl" install apps || warn "独立应用安装失败"
  fi
  if [ "$KOS_WITH_LOCKSCREEN" -eq 1 ]; then
    log "安装 KOS 锁屏"
    run "$repo/tools/kosctl" install lockscreen || warn "锁屏安装失败"
  fi

  log "注册全局快捷键"
  run "$repo/tools/kosctl" shortcuts install || warn "快捷键注册失败（登录后可手动重跑）"

  if [ "$KOS_START" -eq 1 ]; then
    log "启动 KOS shell"
    run "$repo/tools/kosctl" start || warn "kosctl start 失败（注销登录后自动启动）"
  fi
}

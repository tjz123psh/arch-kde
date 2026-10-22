#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# 桌面应用收尾：QQ 启动器去重。
#
# linuxqq 与 linuxqq-wayland-fix 各带一个 .desktop，两个都叫 QQ、StartupWMClass 都是 QQ，
# Dock / 启动器里会显示两个 QQ。只保留 Wayland 修复版可见：用 XDG 的用户级同名覆盖
# （~/.local/share/applications/qq.desktop）把系统里的 qq.desktop 隐藏掉。
# 微信没有这个问题（2026-10-21 用户确认），不要顺手给微信加同样的覆盖。

fix_qq_launcher() {
  local d="$HOME/.local/share/applications"
  if [ ! -f /usr/share/applications/qq.desktop ]; then
    log "系统里没有 qq.desktop（没装 linuxqq），跳过 QQ 启动器整理"
    return 0
  fi
  if [ ! -f /usr/share/applications/linuxqq-wayland-fix.desktop ] &&
     [ ! -f "$d/linuxqq-wayland-fix.desktop" ]; then
    log "未装 linuxqq-wayland-fix，保留现有 QQ 启动器（不去重）"
    return 0
  fi
  log "整理 QQ 启动器（隐藏重复的 qq.desktop）..."
  write_file "$d/qq.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=QQ
Exec=linuxqq %U
Icon=qq
Terminal=false
StartupWMClass=QQ
Categories=Network;
Comment=QQ（已隐藏，请用 Wayland 修复版）
NoDisplay=true
Hidden=true
EOF
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  if have kbuildsycoca6; then
    kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
  fi
  log "QQ 启动器整理完成（Dock 里残留的旧图标右键取消固定即可）"
}

# 截图工具 Vellum：官方发行包（Rust/GTK4，不本地编译）。
# 依赖由官方包列表提前装好，因此用 --no-deps，避免安装器内再次 sudo。
install_vellum() {
  local tmp
  log "安装截图工具 Vellum（最新发行版）..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 下载并运行 Vellum 官方 install.sh --no-deps"
    return 0
  fi
  if ! have curl; then
    warn "缺少 curl，跳过 Vellum"
    return 0
  fi

  tmp=$(mktemp)
  if ! curl -fsSL --retry 3 --connect-timeout 20 \
      https://github.com/tjz123psh/-Screenshot-Tool/releases/latest/download/install.sh \
      -o "$tmp"; then
    rm -f "$tmp"
    warn "下载 Vellum 安装脚本失败，可稍后重试"
    return 0
  fi
  if ! bash "$tmp" --no-deps; then
    warn "Vellum 安装失败，可稍后重试"
  fi
  rm -f "$tmp"
}

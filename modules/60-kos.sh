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
# 默认自动解析最新稳定发布 tag；要开发版可显式 KOS_SRC_REF=main。
# 网络不可用时回退到最近一次已知稳定版。
KOS_SRC_REF="${KOS_SRC_REF:-}"
KOS_SRC_REF_FALLBACK="${KOS_SRC_REF_FALLBACK:-v0.1.1}"
KOS_SRC_DIR="${KOS_SRC_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/kos-src}"

resolve_kos_ref() {
  [ -n "${KOS_SRC_REF:-}" ] && return 0
  local ref
  ref=$(git ls-remote --tags --refs "$KOS_SRC_URL" 2>/dev/null |
    awk -F/ '{print $NF}' |
    grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' |
    grep -v -- '-' |
    sort -V | tail -n 1 || true)
  if [ -n "$ref" ]; then
    KOS_SRC_REF="$ref"
    log "KOS 最新稳定发布: $KOS_SRC_REF"
  else
    KOS_SRC_REF="$KOS_SRC_REF_FALLBACK"
    warn "无法查询 KOS 最新发布，回退到 $KOS_SRC_REF"
  fi
}

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

  # 独立应用（日历/待办）构建依赖；缺了 kcalendarcore，kosctl install apps 会直接失败。
  if [ "${KOS_WITH_APPS:-0}" -eq 1 ]; then
    printf '%s\n' kcalendarcore
  fi

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

  if [ -d "$dir/.git" ] && [ "$SKIP_UPDATE" -eq 1 ]; then
    log "跳过源码更新（--skip-update）"
    return 0
  fi
  resolve_kos_ref

  if [ -d "$dir/.git" ]; then
    log "KOS 源码已存在：$dir"
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

# KWin 6.8 移除了 /org/kde/KWin 上的 org.kde.kwin.Effects，KOS 设置页的
# 集成状态探针会因此把已加载的 glass / dock / context-menu 效果误报为未连接。
# 在构建 Settings 前补一个 supportInformation 回退，保持与 KWin 版本兼容。
patch_kos_settings_integration_probe() {
  local repo="$1"
  local src="$repo/apps/settings/src/SettingsBridgeDesktop.cpp"

  if [ ! -f "$src" ]; then
    warn "找不到 SettingsBridgeDesktop.cpp，跳过 KWin 6.8 集成状态兼容补丁"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 为 KOS Settings 增加 KWin supportInformation 回退"
    return 0
  fi

  python3 - "$src" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
marker = "Fall back to the stable supportInformation report"
anchor = '''            result.insert(
                QStringLiteral("glassLoaded"), loadedEffects.contains(QStringLiteral("glass")));'''
fallback = '''            // KWin 6.8 removed org.kde.kwin.Effects from /org/kde/KWin.
            // Fall back to the stable supportInformation report so the Settings
            // integration page does not report loaded effects as disconnected.
            if (!interrupted && (!kwinAvailable || loadedEffects.isEmpty())) {
                const QDBusMessage supportReply = boundedBusCall(sessionBus,
                    QStringLiteral("org.kde.KWin"), QStringLiteral("/KWin"),
                    QStringLiteral("org.kde.KWin"),
                    QStringLiteral("supportInformation"));
                if (supportReply.type() == QDBusMessage::ReplyMessage
                        && !supportReply.arguments().isEmpty()) {
                    const QString info = supportReply.arguments().constFirst().toString();
                    bool inLoaded = false;
                    for (const QString &rawLine : info.split(QLatin1Char('\\n'))) {
                        const QString line = rawLine.trimmed();
                        if (line == QStringLiteral("Loaded Effects:")) {
                            inLoaded = true;
                            continue;
                        }
                        if (inLoaded && line == QStringLiteral("Currently Active Effects:"))
                            break;
                        if (inLoaded && !line.isEmpty())
                            loadedEffects.append(line);
                    }
                }
            }
'''
if marker not in source:
    if anchor not in source:
        print("SettingsBridgeDesktop.cpp: unexpected integration probe shape", file=sys.stderr)
        sys.exit(0)
    source = source.replace(anchor, fallback + anchor, 1)
    path.write_text(source)
PY
}

build_install_kos() {
  local repo; repo=$(kos_repo_dir)
  patch_kos_settings_integration_probe "$repo"
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
    # 上游把 kos-pim-service 设计成 D-Bus 激活（install-apps 会先 disable）；
    # 这里启动一次，让 PimWidgetService 立刻有快照可用，之后仍不常驻。
    systemctl --user start kos-pim-service.service >/dev/null 2>&1 || true
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

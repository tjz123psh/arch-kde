#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 构建并安装 genie 最小化/还原动效（原生 KWin 6.8 插件）。
# 源码归档自 linux-macos/kwin-effects/linux-macos-genie，效果 id：
#   kwin4_effect_linuxmacosgenie
#
# 用法：assets/genie/build.sh [--dry-run]
# 依赖：cmake extra-cmake-modules kwin qt6-base kconfig kcoreaddons
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD_DIR="${BUILD_DIR:-$HERE/.build}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { printf '[genie] %s\n' "$*"; }
die() { printf '[genie] 错误: %s\n' "$*" >&2; exit 1; }

for p in cmake extra-cmake-modules kwin qt6-base kconfig kcoreaddons; do
  pacman -Q "$p" >/dev/null 2>&1 || die "缺少依赖 $p（sudo pacman -S --needed $p）"
done
# KWin 6.8 是插件的 API 目标：版本不符就别构建，免得装个加载即崩的 .so
kwin_ver=$(pacman -Q kwin | awk '{print $2}')
case "$kwin_ver" in
  6.8*) ;;
  *) die "当前 kwin=$kwin_ver，本插件只针对 6.8.x 构建" ;;
esac

log "配置 CMake（$BUILD_DIR）"
if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] cmake -S $HERE -B $BUILD_DIR -G Ninja"
else
  cmake -S "$HERE" -B "$BUILD_DIR" -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null
  log "编译"
  cmake --build "$BUILD_DIR" --parallel
  so=$(find "$BUILD_DIR" -name 'kwin4_effect_linuxmacosgenie.so' | head -n1)
  [ -n "$so" ] || die "找不到构建产物 kwin4_effect_linuxmacosgenie.so"
  log "安装到 /usr/lib/qt6/plugins/kwin/effects/plugins/"
  sudo install -Dm755 "$so" /usr/lib/qt6/plugins/kwin/effects/plugins/kwin4_effect_linuxmacosgenie.so
fi
log "完成"

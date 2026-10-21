#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 首次登录把主显示器设成 1920x1080（只尝试一次成功；失败下次登录再试）。
# 安装器在 TTY 里跑，拿不到 KWin 的输出信息，所以放到 KDE 自启动里做。
set -u

MARKER="${XDG_STATE_HOME:-$HOME/.local/state}/kos-installer/display-1920x1080.done"
[ -e "$MARKER" ] && exit 0
command -v kscreen-doctor >/dev/null 2>&1 || exit 0

info=""
for _ in $(seq 1 30); do
    info=$(kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
    [ -n "$info" ] && break
    sleep 1
done
[ -n "$info" ] || exit 0

# 第一个输出名（Output: <id> <name> ...）
name=$(printf '%s\n' "$info" | awk '/^Output:/{print $3; exit}')
[ -n "$name" ] || exit 0

# 只有该输出确实支持 1920x1080 才切，避免把不支持的模式写进配置
if ! printf '%s\n' "$info" | grep -q "1920x1080"; then
    exit 0
fi
if kscreen-doctor "output.${name}.mode.1920x1080" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$MARKER")"
    : > "$MARKER"
fi

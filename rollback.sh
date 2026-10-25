#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 仓库里的回滚入口：还没装好（或者 ~/bin 里没有 kos-undo）时也能用。
#   bash rollback.sh --dry-run   # 只打印计划
#   bash rollback.sh             # 清回装 KOS 之前（列计划 → 问一次 y/N）
# 安装完成后等价的命令是 kos-undo（由 modules/58-scripts.sh 链到 ~/bin）。
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/assets/scripts/maintenance/kos-undo" "$@"

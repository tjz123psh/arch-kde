#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# 热点转发放行。
#
# Docker 安装后会把 iptables 的 FORWARD 策略改成 DROP，只放行它自己的网桥。
# NetworkManager 的 shared 模式（热点）虽然自己加了 MASQUERADE 和 forward 规则，
# 但包在 FORWARD 链上先被 DROP 掉，表现就是：手机能连上热点、能拿到 IP，
# 但是上不了网。这里写一个 dispatcher 脚本，在热点上线/下线时补上放行规则。
# 没有装 Docker 的机器上这两条规则只是多余，无害。

setup_hotspot_dispatcher() {
  log "配置热点转发放行规则（NetworkManager dispatcher）..."
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 写入 /etc/NetworkManager/dispatcher.d/90-kos-hotspot"
    return 0
  fi

  sudo_write_file /etc/NetworkManager/dispatcher.d/90-kos-hotspot <<'EOF'
#!/bin/sh
# KOS：热点转发放行（Docker 会把 FORWARD 策略设成 DROP）。
set -u
IFACE="$1"
ACTION="$2"

[ "${CONNECTION_ID:-}" = "KOS-Hotspot" ] || exit 0

case "$ACTION" in
  up)
    iptables -C FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null ||
      iptables -I FORWARD 1 -i "$IFACE" -j ACCEPT
    iptables -C FORWARD -o "$IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
      iptables -I FORWARD 1 -o "$IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ;;
  down)
    iptables -D FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o "$IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    ;;
esac
exit 0
EOF

  sudo_run chmod 755 /etc/NetworkManager/dispatcher.d/90-kos-hotspot
  log "热点转发规则已就位（KOS-Hotspot 上线时自动放行）"
}

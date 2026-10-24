#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

USER_NAME=$(id -un)

add_groups() {
  local g groups="video render input audio optical storage docker"
  # 打印/扫描（lp/scanner）与 WWAN（uucp）不再处理：目标机不需要。
  for g in $groups; do
    if getent group "$g" >/dev/null 2>&1; then
      sudo_run usermod -aG "$g" "$USER_NAME"
    fi
  done
}

set_shell() {
  if ! have fish; then
    warn "fish is not installed; skipping chsh"
    return 0
  fi
  if [ "$(getent passwd "$USER_NAME" | cut -d: -f7)" = /usr/bin/fish ]; then
    log "Login shell is already fish"
    return 0
  fi
  log "Setting fish as the default shell..."
  sudo_run chsh -s /usr/bin/fish "$USER_NAME"
}

enable_services() {
  log "Enabling system services (no GUI starts yet)..."
  sudo_run systemctl enable sddm
  sudo_run systemctl enable NetworkManager
  sudo_run systemctl enable docker || warn "Failed to enable docker.service; check manually"

  # 蓝牙常装常开：没有硬件时 bluez 只是空跑，插上适配器即用；不再按 hci 设备门控
  sudo_run systemctl enable bluetooth || warn "Failed to enable bluetooth.service; check manually"

  if [ "${WANT_PPD:-0}" -eq 1 ]; then
    sudo_run systemctl enable power-profiles-daemon
  fi
  if [ "${WANT_TLP:-0}" -eq 1 ]; then
    sudo_run systemctl enable tlp
    # tlp 与 power-profiles-daemon 二选一：不 mask 掉的话 ppd 会把 TLP 的改动覆盖回去
    sudo_run systemctl mask power-profiles-daemon || warn "Failed to mask power-profiles-daemon (probably not installed); ignoring"
  fi
  # ASUS ROG：asusd 管风扇/灯/性能模式，supergfxd 管 GPU 模式切换（装到才有）
  if pacman -Qq asusctl >/dev/null 2>&1; then
    sudo_run systemctl enable asusd.service || warn "Failed to enable asusd; ignoring"
  fi
  if pacman -Qq supergfxctl >/dev/null 2>&1; then
    sudo_run systemctl enable supergfxd.service || warn "Failed to enable supergfxd; ignoring"
  fi
  # udisks2：U 盘/移动硬盘挂载后端（KDE 设备通知器与 Dolphin 都走它；D-Bus 激活也能工作，显式 enable 更稳）
  if pacman -Qq udisks2 >/dev/null 2>&1; then
    sudo_run systemctl enable udisks2.service || warn "Failed to enable udisks2; ignoring"
  fi
  sudo_run systemctl set-default graphical.target
}

network_backend() {
  # iwd 默认不装（和 wpa_supplicant 抢 wlan0）。只在 --iwd 或用户自己已经启用过
  # iwd 时才把 NetworkManager 切过去；切错的表现是"Wi-Fi 列表空"，所以下面留了回退命令。
  if ! systemctl is-enabled iwd >/dev/null 2>&1; then
    return 0
  fi
  log "Switching NetworkManager to the iwd backend..."
  sudo_write_file /etc/NetworkManager/conf.d/10-iwd-backend.conf <<'EOF'
[device]
wifi.backend=iwd
EOF
  sudo_run systemctl enable iwd
  # 同一条 wlan0 不能两个后端抢：iwd 模式下把 wpa_supplicant 停掉
  sudo_run systemctl disable wpa_supplicant || true
  warn "Switched to the iwd backend. If the Wi-Fi list is empty: delete /etc/NetworkManager/conf.d/10-iwd-backend.conf and run sudo systemctl enable --now wpa_supplicant to roll back"
}

# 时间同步：archinstall 通常会启用 systemd-timesyncd（或用户自己用 chrony）。
# 安装器只兜底，不覆盖已有的 NTP 实现 —— 两个 NTP 客户端同时改时钟会互相拉扯。
time_sync_setup() {
  local u
  for u in chronyd ntpd openntpd; do
    if systemctl is-enabled --quiet "$u" 2>/dev/null; then
      log "Time sync handled by $u; skipping systemd-timesyncd"
      return 0
    fi
  done
  if systemctl is-enabled --quiet systemd-timesyncd 2>/dev/null; then
    log "Time sync: systemd-timesyncd enabled"
    return 0
  fi
  log "Enabling systemd-timesyncd (fallback)..."
  sudo_run systemctl enable --now systemd-timesyncd || warn "Failed to enable systemd-timesyncd; check time sync manually"
}

# zram：archinstall 开了 zram 时会写 /etc/systemd/zram-generator.conf 并装包。
# 安装器不新建/不修改 zram 配置，只做一次确认（重启后由 zram-generator 建 /dev/zram0）。
zram_setup() {
  if [ ! -e /etc/systemd/zram-generator.conf ] && [ ! -e /usr/lib/systemd/zram-generator.conf ]; then
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] systemctl daemon-reload (zram-generator config already present)"
    return 0
  fi
  sudo_run systemctl daemon-reload || true
  if [ -e /sys/block/zram0 ]; then
    log "zram: /dev/zram0 active"
  else
    log "zram: config present but /dev/zram0 missing (zram-generator creates it after reboot)"
  fi
}

nvidia_setup() {
  if [ "${WANT_NVIDIA:-0}" -ne 1 ]; then
    log "NVIDIA driver not installed in this run; skipping modprobe/mkinitcpio"
    return 0
  fi
  log "Configuring NVIDIA: Wayland needs nvidia_drm.modeset=1 ..."
  # 这一条无论模块能不能用都无害（模块不加载时内核直接忽略未知 options）
  sudo_write_file /etc/modprobe.d/99-nvidia-macos.conf <<'EOF'
options nvidia_drm modeset=1 fbdev=1
EOF

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] after modinfo nvidia_drm succeeds, write /etc/mkinitcpio.conf.d/99-nvidia-macos.conf and run mkinitcpio -P"
    return 0
  fi

  # 只有模块真的编出来了才把 nvidia 塞进 initramfs。
  # 否则（DKMS 编译失败 / headers 版本不匹配 / 卡不被支持）mkinitcpio -P 会因为
  # "module not found: nvidia_drm" 失败，留下的半成品 initramfs 会让机器重启黑屏 ——
  # 这正是真机上最贵的错误，所以这里必须先验证再动手。
  if ! modinfo nvidia_drm >/dev/null 2>&1; then
    warn "nvidia_drm module missing (DKMS did not build it, or this driver does not support the card); skipping mkinitcpio"
    warn "Display still works (nouveau / llvmpipe); debug with: dkms status, journalctl -b -u dkms"
    warn "To fully roll back NVIDIA: sudo rm -f /etc/modprobe.d/99-nvidia-macos.conf && sudo pacman -Rns nvidia-open-dkms nvidia-utils"
    return 0
  fi

  sudo_write_file /etc/mkinitcpio.conf.d/99-nvidia-macos.conf <<'EOF'
MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
EOF
  if ! sudo mkinitcpio -P; then
    warn "mkinitcpio -P failed: removing the NVIDIA MODULES drop-in to avoid a black screen on next boot"
    sudo rm -f /etc/mkinitcpio.conf.d/99-nvidia-macos.conf
    if ! sudo mkinitcpio -P; then
      warn "Regenerating the initramfs failed too! Run sudo mkinitcpio -P manually in a TTY before rebooting, or the machine may not boot"
    fi
  fi
}

# 微码没生效时的统一出口：具体命令由 20-hardware.sh 的 hw_bootloader_hint 维护
# （探测层知道 bootloader 是 GRUB / systemd-boot / UKI），这里只负责调用。
hw_boot_hint() {
  if declare -F hw_bootloader_hint >/dev/null 2>&1; then
    hw_bootloader_hint
  else
    warn "Microcode is not active yet: the installer does not touch the bootloader; make sure HOOKS in /etc/mkinitcpio.conf contains microcode, then run sudo mkinitcpio -P"
  fi
}

# CPU 微码：包只把 payload 放进 /boot，真正"早加载"要求 initramfs 里带微码。
# 安装器不改 bootloader（这是它的边界），但必须做到"装完能确认；确认不了就说清楚"：
#   1) microcode hook 在（Arch 默认 HOOKS 已带）→ 重跑 mkinitcpio -P 生成合并 initramfs；
#   2) 安装期有 sudo，就用 sudo + lsinitcpio --early 做硬校验（doctor 期没有 sudo，
#      才退回 20-hardware.sh 的 hw_microcode_state 软判断）；
#   3) 校验不过 → 调 hw_bootloader_hint 打印确切命令，绝不"装完不说话"。
microcode_setup() {
  local img verified=0 candidates=0 f
  local hook="${MICROCODE_HOOK:-0}"
  if [ "${WANT_UCODE:-0}" -ne 1 ] || [ -z "${UCODE_PKG:-}" ]; then
    log "CPU microcode not installed in this run; skipping"
    return 0
  fi
  img="/boot/${UCODE_PKG}.img"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] microcode hook=$hook -> mkinitcpio -P -> sudo lsinitcpio --early to verify $img"
    return 0
  fi

  if [ "$hook" -eq 1 ]; then
    # 装 ucode 包时 pacman 的 mkinitcpio hook 通常已经重跑过；再跑一次是幂等的，
    # 也是唯一能保证"刚装完的 initramfs 里确实有微码"的办法。
    if ! sudo mkinitcpio -P; then
      warn "mkinitcpio -P failed: microcode will not load early; rerun manually and check the exit code"
    fi
  fi

  for f in /boot/initramfs-*.img /boot/EFI/Linux/*.efi /efi/EFI/Linux/*.efi; do
    [ -e "$f" ] || continue
    candidates=$((candidates + 1))
    if sudo lsinitcpio --early "$f" 2>/dev/null | grep -q microcode; then
      verified=1
    fi
  done

  if [ "$verified" -eq 1 ]; then
    log "CPU microcode confirmed in the initramfs (${UCODE_PKG} -> $img): early loading will work, no bootloader change needed"
    return 0
  fi
  if [ "$candidates" -eq 0 ]; then
    # 这台机器的 /boot 目录对普通用户不可读（权限 700 之类），sudo lsinitcpio 也就没文件可查。
    # 别在这里乱指路（hw_bootloader_hint 会说"只差 mkinitcpio -P"，而我们已经跑过了），
    # 只给重启后的自查方法。
    warn "Cannot verify: no readable initramfs/UKI found (/boot is not readable by the user, or the layout is unusual)"
    warn "Microcode package installed and mkinitcpio ran; after reboot check: journalctl -k -b | grep -i microcode should show 'Updated early from'"
    warn "If missing: make sure HOOKS has microcode, rerun sudo mkinitcpio -P; with GRUB also run sudo grub-mkconfig -o /boot/grub/grub.cfg"
    return 0
  fi
  warn "Microcode package is installed but not found in the initramfs - it is not active yet!"
  if [ "$hook" -eq 0 ]; then
    warn "Cause: HOOKS in /etc/mkinitcpio.conf lacks the microcode hook (Arch ships it by default; this machine was modified)"
  fi
  hw_boot_hint
}

xdg_dirs() {
  if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
  if have xdg-user-dirs-update; then
    xdg-user-dirs-update || true
  fi
}

default_browser() {
  if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
  if [ -f /usr/share/applications/google-chrome.desktop ]; then
    xdg-settings set default-web-browser google-chrome.desktop >/dev/null 2>&1 || true
    xdg-mime default google-chrome.desktop x-scheme-handler/http >/dev/null 2>&1 || true
    xdg-mime default google-chrome.desktop x-scheme-handler/https >/dev/null 2>&1 || true
  fi
}

# Snapper：Btrfs root/home 的时间线快照。
# 只做配置和定时器，不碰分区/挂载；非 Btrfs 系统直接跳过。
setup_snapshots() {
  if ! have snapper; then
    warn "snapper not installed; skipping snapshot setup"
    return 0
  fi
  if [ "$(findmnt -no FSTYPE / 2>/dev/null || true)" != "btrfs" ]; then
    warn "Root filesystem is not Btrfs; skipping Snapper setup"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] snapper create-config root/home; keep 4 weekly timeline snapshots; enable the timeline/cleanup timers"
    return 0
  fi

  local spec cfg target
  for spec in "root:/" "home:/home"; do
    cfg="${spec%%:*}"
    target="${spec#*:}"
    [ "$(findmnt -no FSTYPE "$target" 2>/dev/null || true)" = "btrfs" ] || continue
    if [ ! -e "/etc/snapper/configs/$cfg" ]; then
      sudo_run snapper -c "$cfg" create-config "$target" ||
        warn "Snapper failed to create the $cfg config (a .snapshots dir may exist, or it is not a separate subvolume)"
    fi
    if [ -e "/etc/snapper/configs/$cfg" ]; then
      sudo_run snapper -c "$cfg" set-config \
        TIMELINE_CREATE=yes TIMELINE_CLEANUP=yes \
        TIMELINE_LIMIT_HOURLY=1 TIMELINE_LIMIT_DAILY=0 \
        TIMELINE_LIMIT_WEEKLY=4 TIMELINE_LIMIT_MONTHLY=0 \
        TIMELINE_LIMIT_QUARTERLY=0 TIMELINE_LIMIT_YEARLY=0 ||
        warn "Snapper failed to set the timeline options for $cfg"
    fi
  done

  # 落一个“装桌面前”的回滚点：桌面/KOS 的配置都在这一步之后写，装坏了可以
  # 用 kos-undo snapshot <序号> 退回来。描述相同就不再重复建，避免重跑堆快照。
  local snap_desc="kos-installer: before desktop"
  for spec in root home; do
    [ -e "/etc/snapper/configs/$spec" ] || continue
    if sudo snapper -c "$spec" list 2>/dev/null | grep -qF "$snap_desc"; then
      log "Snapshot \"$snap_desc\" already exists for $spec; skipping"
      continue
    fi
    sudo_run snapper -c "$spec" create -d "$snap_desc" ||
      warn "Failed to create the $spec snapshot"
  done

  # Snapper 默认每小时触发 timeline；用户要求每周一次，改为周日 03:00。
  # 只覆盖 timer 时间表，不改 Snapper 的保留策略（weekly=4）。
  sudo_write_file /etc/systemd/system/snapper-timeline.timer.d/90-weekly.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=Sun *-*-* 03:00:00
Persistent=true
EOF
  sudo_run systemctl daemon-reload
  sudo_run systemctl enable --now snapper-timeline.timer snapper-cleanup.timer ||
    warn "Failed to enable the Snapper timers; check manually"
}

setup_system() {
  log "System finish-up: groups / shell / services / microcode / drivers..."
  add_groups
  set_shell
  enable_services
  setup_snapshots
  time_sync_setup
  zram_setup
  network_backend
  # 顺序有讲究：nvidia_setup 先写 MODULES drop-in 并重建 initramfs，
  # microcode_setup 最后再跑一次 mkinitcpio -P 并校验 —— 校验对象才是最终镜像。
  nvidia_setup
  microcode_setup
  xdg_dirs
  default_browser
}

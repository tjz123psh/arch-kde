#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

USER_NAME=$(id -un)

add_groups() {
  local g groups="video render input audio optical storage lp scanner"
  # uucp：WWAN/串口设备的属组（ModemManager 要能开 /dev/ttyUSB*）。
  # lp/scanner 是打印/扫描（cups/sane 用得到），视频渲染/输入/存储一直是这批。
  if [ "${WANT_WWAN:-0}" -eq 1 ]; then
    groups="$groups uucp"
  fi
  for g in $groups; do
    if getent group "$g" >/dev/null 2>&1; then
      sudo_run usermod -aG "$g" "$USER_NAME"
    fi
  done
}

set_shell() {
  if ! have fish; then
    warn "fish 未安装，跳过 chsh"
    return 0
  fi
  if [ "$(getent passwd "$USER_NAME" | cut -d: -f7)" = /usr/bin/fish ]; then
    log "登录 shell 已是 fish"
    return 0
  fi
  log "设置 fish 为默认 shell..."
  sudo_run chsh -s /usr/bin/fish "$USER_NAME"
}

enable_services() {
  log "启用系统服务（不会立刻启动图形界面）..."
  sudo_run systemctl enable sddm
  sudo_run systemctl enable NetworkManager

  # 没有蓝牙硬件还 enable，每次开机都会留一条失败日志（bluez 已装，插上再开就行）
  if [ "${HAS_BT:-0}" -eq 1 ]; then
    sudo_run systemctl enable bluetooth
  else
    log "未检测到蓝牙硬件，跳过 bluetooth.service（bluez 已装：sudo systemctl enable --now bluetooth 随时可开）"
  fi

  if [ "${WANT_PPD:-0}" -eq 1 ]; then
    sudo_run systemctl enable power-profiles-daemon
  fi
  if [ "${WANT_TLP:-0}" -eq 1 ]; then
    sudo_run systemctl enable tlp
    # tlp 与 power-profiles-daemon 二选一：不 mask 掉的话 ppd 会把 TLP 的改动覆盖回去
    sudo_run systemctl mask power-profiles-daemon || warn "mask power-profiles-daemon 失败（大概率没装），忽略"
  fi
  if [ "${WANT_THERMALD:-0}" -eq 1 ]; then
    sudo_run systemctl enable thermald || warn "enable thermald 失败，忽略（AMD 机器不需要它）"
  fi
  if [ "${WANT_IRQBALANCE:-0}" -eq 1 ]; then
    sudo_run systemctl enable irqbalance || warn "enable irqbalance 失败，忽略"
  fi
  # ASUS ROG：asusd 管风扇/灯/性能模式，supergfxd 管 GPU 模式切换（装到才有）
  if pacman -Qq asusctl >/dev/null 2>&1; then
    sudo_run systemctl enable asusd.service || warn "enable asusd 失败，忽略"
  fi
  if pacman -Qq supergfxctl >/dev/null 2>&1; then
    sudo_run systemctl enable supergfxd.service || warn "enable supergfxd 失败，忽略"
  fi
  # udisks2：U 盘/移动硬盘挂载后端（KDE 设备通知器与 Dolphin 都走它；D-Bus 激活也能工作，显式 enable 更稳）
  if pacman -Qq udisks2 >/dev/null 2>&1; then
    sudo_run systemctl enable udisks2.service || warn "enable udisks2 失败，忽略"
  fi
  if [ "${WANT_PRINTERS:-0}" -eq 1 ]; then
    # cups 安装时一般会自己 enable cups.socket，这里再显式来一次（镜像 preset 不一定）
    # avahi：sane-airscan 的免驱网络扫描靠它的 mDNS 发现，没它扫描仪搜不到
    sudo_run systemctl enable cups.socket || warn "enable cups.socket 失败，忽略"
    sudo_run systemctl enable avahi-daemon.socket avahi-daemon.service || warn "enable avahi 失败，忽略"
  fi
  sudo_run systemctl set-default graphical.target
}

network_backend() {
  # iwd 默认不装（和 wpa_supplicant 抢 wlan0）。只在 --iwd 或用户自己已经启用过
  # iwd 时才把 NetworkManager 切过去；切错的表现是"Wi-Fi 列表空"，所以下面留了回退命令。
  if [ "${WANT_IWD:-0}" -ne 1 ] && ! systemctl is-enabled iwd >/dev/null 2>&1; then
    return 0
  fi
  log "NetworkManager 使用 iwd 后端..."
  sudo_write_file /etc/NetworkManager/conf.d/10-iwd-backend.conf <<'EOF'
[device]
wifi.backend=iwd
EOF
  sudo_run systemctl enable iwd
  # 同一条 wlan0 不能两个后端抢：iwd 模式下把 wpa_supplicant 停掉
  sudo_run systemctl disable wpa_supplicant || true
  warn "已切到 iwd 后端。若 Wi-Fi 列表为空：删掉 /etc/NetworkManager/conf.d/10-iwd-backend.conf 并 sudo systemctl enable --now wpa_supplicant 即回退"
}

# 时间同步：archinstall 通常会启用 systemd-timesyncd（或用户自己用 chrony）。
# 安装器只兜底，不覆盖已有的 NTP 实现 —— 两个 NTP 客户端同时改时钟会互相拉扯。
time_sync_setup() {
  local u
  for u in chronyd ntpd openntpd; do
    if systemctl is-enabled --quiet "$u" 2>/dev/null; then
      log "时间同步已由 $u 负责，跳过 systemd-timesyncd"
      return 0
    fi
  done
  if systemctl is-enabled --quiet systemd-timesyncd 2>/dev/null; then
    log "时间同步: systemd-timesyncd 已启用"
    return 0
  fi
  log "启用 systemd-timesyncd（兜底）..."
  sudo_run systemctl enable --now systemd-timesyncd || warn "启用 systemd-timesyncd 失败，请手动检查时间同步"
}

# zram：archinstall 开了 zram 时会写 /etc/systemd/zram-generator.conf 并装包。
# 安装器不新建/不修改 zram 配置，只做一次确认（重启后由 zram-generator 建 /dev/zram0）。
zram_setup() {
  if [ ! -e /etc/systemd/zram-generator.conf ] && [ ! -e /usr/lib/systemd/zram-generator.conf ]; then
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] systemctl daemon-reload（zram-generator 配置已存在）"
    return 0
  fi
  sudo_run systemctl daemon-reload || true
  if [ -e /sys/block/zram0 ]; then
    log "zram: /dev/zram0 已启用"
  else
    log "zram: 有配置但当前没有 /dev/zram0（重启后由 zram-generator 创建）"
  fi
}

nvidia_setup() {
  if [ "${WANT_NVIDIA:-0}" -ne 1 ]; then
    log "本次不装 NVIDIA 驱动，跳过 modprobe/mkinitcpio"
    return 0
  fi
  log "配置 NVIDIA：Wayland 需要 nvidia_drm.modeset=1 ..."
  # 这一条无论模块能不能用都无害（模块不加载时内核直接忽略未知 options）
  sudo_write_file /etc/modprobe.d/99-nvidia-macos.conf <<'EOF'
options nvidia_drm modeset=1 fbdev=1
EOF

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] modinfo nvidia_drm 通过后写 /etc/mkinitcpio.conf.d/99-nvidia-macos.conf 并 mkinitcpio -P"
    return 0
  fi

  # 只有模块真的编出来了才把 nvidia 塞进 initramfs。
  # 否则（DKMS 编译失败 / headers 版本不匹配 / 卡不被支持）mkinitcpio -P 会因为
  # "module not found: nvidia_drm" 失败，留下的半成品 initramfs 会让机器重启黑屏 ——
  # 这正是真机上最贵的错误，所以这里必须先验证再动手。
  if ! modinfo nvidia_drm >/dev/null 2>&1; then
    warn "nvidia_drm 模块不存在（DKMS 没编出来，或这版驱动不支持这张卡），跳过 mkinitcpio"
    warn "现在仍能显示（nouveau / llvmpipe）；排查：dkms status、journalctl -b -u dkms"
    warn "要彻底回退 NVIDIA：sudo rm -f /etc/modprobe.d/99-nvidia-macos.conf && sudo pacman -Rns nvidia-open-dkms nvidia-utils"
    return 0
  fi

  sudo_write_file /etc/mkinitcpio.conf.d/99-nvidia-macos.conf <<'EOF'
MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
EOF
  if ! sudo mkinitcpio -P; then
    warn "mkinitcpio -P 失败：撤掉 NVIDIA 的 MODULES drop-in，避免下次开机黑屏"
    sudo rm -f /etc/mkinitcpio.conf.d/99-nvidia-macos.conf
    if ! sudo mkinitcpio -P; then
      warn "重新生成 initramfs 也失败！请在重启前于 TTY 手动执行 sudo mkinitcpio -P，否则可能起不来"
    fi
  fi
}

# 微码没生效时的统一出口：具体命令由 20-hardware.sh 的 hw_bootloader_hint 维护
# （探测层知道 bootloader 是 GRUB / systemd-boot / UKI），这里只负责调用。
hw_boot_hint() {
  if declare -F hw_bootloader_hint >/dev/null 2>&1; then
    hw_bootloader_hint
  else
    warn "微码还没生效：安装器不改 bootloader，请确认 /etc/mkinitcpio.conf 的 HOOKS 带 microcode 后跑 sudo mkinitcpio -P"
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
    log "本次不装 CPU 微码，跳过"
    return 0
  fi
  img="/boot/${UCODE_PKG}.img"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] microcode hook=$hook → mkinitcpio -P → sudo lsinitcpio --early 校验 $img"
    return 0
  fi

  if [ "$hook" -eq 1 ]; then
    # 装 ucode 包时 pacman 的 mkinitcpio hook 通常已经重跑过；再跑一次是幂等的，
    # 也是唯一能保证"刚装完的 initramfs 里确实有微码"的办法。
    if ! sudo mkinitcpio -P; then
      warn "mkinitcpio -P 失败：微码不会早加载，请手动重跑并看返回码"
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
    log "CPU 微码已确认进 initramfs（${UCODE_PKG} → $img）：早期加载会生效，bootloader 不用改"
    return 0
  fi
  if [ "$candidates" -eq 0 ]; then
    # 这台机器的 /boot 目录对普通用户不可读（权限 700 之类），sudo lsinitcpio 也就没文件可查。
    # 别在这里乱指路（hw_bootloader_hint 会说"只差 mkinitcpio -P"，而我们已经跑过了），
    # 只给重启后的自查方法。
    warn "无法校验：找不到可读的 initramfs/UKI（/boot 目录对普通用户不可读，或布局特殊）"
    warn "微码包已装、mkinitcpio 也跑过了；重启后自查：journalctl -k -b | grep -i microcode 应出现 'Updated early from'"
    warn "如果没出现：确认 HOOKS 里有 microcode、重跑 sudo mkinitcpio -P；GRUB 还要 sudo grub-mkconfig -o /boot/grub/grub.cfg"
    return 0
  fi
  warn "微码包已装，但 initramfs 里没找到微码 —— 现在还不会生效！"
  if [ "$hook" -eq 0 ]; then
    warn "原因：/etc/mkinitcpio.conf 的 HOOKS 里没有 microcode hook（Arch 默认有，这台被改过）"
  fi
  hw_boot_hint
}

# 指纹：只装包 + 打印接法，绝不自动改 PAM。
# 原因：/etc/pam.d/sddm 写错就是"登录界面永远密码错"，真机上要 rescue 才救得回来。
fprintd_hint() {
  if [ "${WANT_FP:-0}" -ne 1 ]; then
    return 0
  fi
  log "指纹已装包（fprintd/libfprint）。安装器不改 PAM（改错会登录不了），要指纹登录请手动三步："
  log "  1) fprintd-enroll                 # 按提示按 5 次指纹"
  log "  2) sudoedit /etc/pam.d/sddm       # auth 段最前面加一行：auth sufficient pam_fprintd.so"
  log "  3) 回退：删掉那一行；进不去桌面时 Ctrl+Alt+F3 登录后用 sudoedit 改回来"
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

setup_system() {
  log "系统收尾：用户组 / shell / 服务 / 微码 / 驱动..."
  add_groups
  set_shell
  enable_services
  time_sync_setup
  zram_setup
  network_backend
  # 顺序有讲究：nvidia_setup 先写 MODULES drop-in 并重建 initramfs，
  # microcode_setup 最后再跑一次 mkinitcpio -P 并校验 —— 校验对象才是最终镜像。
  nvidia_setup
  microcode_setup
  fprintd_hint
  xdg_dirs
  default_browser
}

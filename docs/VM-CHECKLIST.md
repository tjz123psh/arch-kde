# 干净 VM 全装验收清单

AGENTS.md §五要求：改了主流程 / 阶段顺序 / 包清单 / 镜像逻辑，必须在一台干净 Arch 虚拟机里完整跑一次。
本清单把“怎么装、留什么证据、装完核对什么”固定下来，免得每次靠记忆复现现场。

## 0. 前置

- 干净 Arch（archinstall 之后、能登录 TTY，**不要**先装桌面）。
- 网络可用（`ping -c1 archlinux.org`）。
- 一个普通用户，能 `sudo`；**不要用 root 跑安装器**。
- 建议 40G 磁盘 / 4G 内存（KOS 构建 + AUR 编译比较吃空间）。

## 1. 跑安装

```bash
git clone https://github.com/tjz123psh/arch-kde.git
cd arch-kde
git log --oneline -1          # 记下这次验的 commit
bash install.sh --yes         # 约 30-60 分钟，取决于镜像与 AUR 编译
```

装完别急着重启，先把证据留下来。

## 2. 装完立刻收集

```bash
LOG=$(ls -t ~/.local/state/kos-installer/log/install-*.log | head -1)
cp "$LOG" ~/vm-install.log
cp "$(ls -t ~/.local/state/kos-installer/doctor-*.txt | head -1)" ~/vm-doctor.txt
pacman -Qq | sort > ~/vm-packages.txt
pacman -Q kwin plasma-desktop sddm kitty fish fcitx5 quickshell \
          mpv mpv-uosc mpv-thumbfast-git yt-dlp 7zip kate \
          sddm-silent-theme > ~/vm-key-packages.txt 2>&1
grep -nE 'WARN|ERROR' ~/vm-install.log > ~/vm-warnings.txt || true
ls -1 ~/vm-*.txt ~/vm-install.log
```

## 3. 重启后逐项核对

| # | 检查 | 命令 / 操作 | 期望 |
|---|---|---|---|
| 1 | 能进登录页 | 重启 | Silent 主题登录页，背景 樱吹雪 |
| 2 | 登录页配置 | `cat /etc/sddm.conf.d/zz-kos-silent.conf` | 有 `ThemeDir=/etc/sddm/themes`、`Current=silent` |
| 3 | 主题自管副本 | `ls /etc/sddm/themes/silent/Main.qml` | 存在 |
| 4 | 能登录进 KDE | 输密码 | 进桌面，KOS shell（Dock/顶栏）起来 |
| 5 | KDE 中文 | 系统设置 | 中文 |
| 6 | KDE 字体 CJK | `kreadconfig6 --file kdeglobals --group General --key font` | 以 `Noto Sans CJK SC` 开头 |
| 7 | GTK 字体没被改回 | `grep gtk-font-name ~/.config/gtk-3.0/settings.ini` | 含 `Noto Sans CJK SC` |
| 8 | Meta 留给 KOS | `kreadconfig6 --file kglobalshortcutsrc --group plasmashell --key 'activate application launcher'` | 第一段是 `none` |
| 9 | 分辨率 | `kscreen-doctor -o` | 主屏 1920x1080（显示器支持时） |
| 10 | 壁纸 | `grep '^image=' ~/.local/state/quickshell/kos/wallpaper.ini` | 指向 `.../kos/gallery/樱吹雪.png` |
| 11 | 输入法 | `fcitx5-diagnose` / Ctrl+Space | fcitx5 可用，能打中文 |
| 12 | 终端 | 打开 kitty | fish + starship 正常，中文不豆腐块 |
| 13 | **mpv UI** | 打开任意视频 → 右键；再按 `?` | uosc 菜单、键位表都出来，无 “Can't load unknown script” |
| 14 | **yazi 解压** | `yazi` 里选 .zip → Extract | 三个解压项都在，且真能解开 |
| 15 | **b23** | `b23 'https://b23.tv/xxxx'`（或复制链接后 `b23`） | mpv 小窗开始播放 |
| 16 | **kate** | `kate --version` | 能启动 |
| 17 | 截图 | `Print` | Vellum 区域截图 |
| 18 | 录屏 | `Alt+F5` | fuzzel 菜单 |
| 19 | 热点菜单 | `Alt+F6` | fuzzel 菜单 |
| 20 | 微码 | `journalctl -k -b \| grep -i microcode` | 有 “Updated early from” |
| 21 | NVIDIA | `lsmod \| grep nvidia`、`nvidia-smi` | 模块加载、能出表 |
| 22 | GRUB 方向键 | 重启停在 GRUB 菜单按 ↑↓ | 能移动，不卡死 |
| 23 | doctor | `bash install.sh --check` | 除硬件没有的项外无 `[MISS]` |

## 4. 回传什么

`~/vm-install.log`、`~/vm-doctor.txt`、`~/vm-packages.txt`、`~/vm-key-packages.txt`、`~/vm-warnings.txt`；
第 3 节里失败的项附截图或输出。doctor 报告里有会话类型、locale、包版本，排查时要一起看。

## 5. 两条新行为

```bash
echo '# my edit' >> ~/.config/starship.toml
bash install.sh --dry-run --yes --keep-user-configs   # 计划里应显示 Existing user config: keep
bash install.sh --ime foo --check; echo rc=$?            # 期望 rc=1，提示 must be fcitx5, rime or none
bash install.sh --wallpaper 不存在.png --dry-run; echo rc=$?   # 期望 rc=1
```

## 6. 已知会出现的非问题

- `--no-archlinuxcn` 且 `--nvidia-legacy` 时，安装器会跳过 NVIDIA 驱动并提示（archlinuxcn 才有 580xx）。
- `whitesur-gtk-theme` 在 AUR 被标记 out-of-date，构建失败只会 warn，图标/光标/GTK 主题可能回退默认。
- VM 里没有独显/蓝牙/摄像头时，doctor 对应项按“硬件没有”处理，不算 MISS。

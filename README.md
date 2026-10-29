# KOS 桌面一键安装器（Arch Linux）

把一台**刚 archinstall 完、只能登录 TTY** 的干净 Arch，一键装成 **KDE Plasma 6 (Wayland) + KOS/NextKDE 桌面**：
Quickshell 外壳、KOS 设置与控制中心、kitty + fish 终端、fcitx5 中文输入、SilentSDDM 登录主题、13 张壁纸，外加一套常用软件和快捷键。

- 桌面本体来自上游 [NextKDE](https://github.com/SuceV587/NextKde)，本仓库只负责“装”和少量用户配置
- 破坏性动作（分区 / 挂载 / 内核 / bootloader / 时区）一律不碰，那些都是 archinstall 的职责

## 快速开始

~~~bash
git clone https://github.com/tjz123psh/arch-kde.git
cd arch-kde
bash install.sh --check     # 只预检，不改系统
bash install.sh --yes       # 全装
~~~

装完请**注销并重新登录一次**（KWin 插件和 KOS 外壳需要新会话才会生效）。

默认壁纸用仓库自带的图（默认 `樱吹雪.png`），不会再露出 KDE 的默认壁纸；
想换一张：`bash install.sh --yes --wallpaper 落霞.png`（名字取自 `assets/wallpapers/`）。

## 装坏了怎么办

安装器**没有**自动卸载/回滚命令（上游桌面本体也不归这里管）。三条现成的路：

- **重跑就是修复**：`bash install.sh --yes` 是幂等的，配置会重新部署、缺的包会补上；
  被覆盖的文件在 `~/.local/state/kos-installer/backup/<时间>/` 有备份，
  `manifest.txt` 里记了原路径 + sha256，要哪个手动拷回去。
- **整机回档**：安装器在装桌面前会落一个 Snapper 快照 `kos-installer: before desktop`，
  用 `sudo snapper -c root list` 看序号，`sudo snapper -c root rollback <序号>` 回档
  （图形界面等价操作是 btrfs-assistant）。
- **彻底重来**：重装系统最快——安装器不碰分区/引导器，重装完再跑一遍即可。

## 要求

- Arch Linux x86_64，能登录 TTY（刚 archinstall 完的状态就行），普通用户 + sudo（不要用 root 跑）
- 安装过程需要联网；AUR 固定用 **paru**，没有时会自动构建 paru-bin
- 硬件按目标机固定打包：**ASUS TUF A15（R7 7735H + RTX 4050 + RTL8852BE）**；换机器改 modules/10-packages.sh 里那段

## 装完之后

- **桌面**：KDE Plasma 6 + KOS shell（Dock / 顶栏 / 控制中心 / 设置 / 锁屏），玻璃磨砂外观，macOS 风格动效
- **终端**：kitty + fish + starship，配置随安装器部署；编辑器用 nvim
- **输入法**：fcitx5 + 中文方案，按 KWin Wayland 方式接管
- **外观**：BreezeDark + WhiteSur 图标/光标，SilentSDDM 登录页，13 张 KOS 壁纸（默认壁纸开箱即用，`--wallpaper` 可换）
- **窗口**：新窗口默认 1304x770（`--window-size WxH` 可改，只在第一次出现时套一次；对话框 / 桌面面板不受影响）
- **软件**：Chrome、VS Code、Obsidian、Docker、gh、yazi 等
- **快捷键**：Alt+Enter 终端、Alt+Q 关窗、Win+O 启动器、Win+/ 快捷键查看器、Print 区域截图、Alt+F5 录屏、Alt+F6 热点

## 文档

- [交接状态](docs/HANDOFF.md) — 当前进度、未完成项、本机系统级改动
- [排障手册](docs/TROUBLESHOOTING.md) — 镜像、锁屏、快捷键、热点、装坏了怎么退
- [VM 验收清单](docs/VM-CHECKLIST.md) — 干净 VM 全装要留的证据、装完逐项核对表
- bash install.sh --help — 全部参数与环境变量

## 许可

GPL-3.0-or-later

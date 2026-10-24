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

## 装坏了 / 后悔了

一条命令退回安装前（连装上的软件包一起卸掉）：

```bash
kos-undo            # 列出要卸的包、要还原/删除的文件，问过你才动手
kos-undo --dry-run  # 只看计划，什么都不动
```

它做三件事：卸载这一次安装新装的包（安装开始时记了 `pacman -Qq` 基线，做差集）、
还原被改过的文件、删掉安装器新建的文件和 `~/.cache/kos-src` 等目录。跑完重启就是干净的起点。

装好之后 `kos-undo` 就在 `~/bin`；还没装完时用 `bash rollback.sh`，效果相同。

## 要求

- Arch Linux x86_64，能登录 TTY（刚 archinstall 完的状态就行），普通用户 + sudo（不要用 root 跑）
- 安装过程需要联网；AUR 固定用 **paru**，没有时会自动构建 paru-bin
- 硬件按目标机固定打包：**ASUS TUF A15（R7 7735H + RTX 4050 + RTL8852BE）**；换机器改 modules/10-packages.sh 里那段

## 装完之后

- **桌面**：KDE Plasma 6 + KOS shell（Dock / 顶栏 / 控制中心 / 设置 / 锁屏），玻璃磨砂外观，macOS 风格动效
- **终端**：kitty + fish + starship，配置随安装器部署；编辑器用 nvim
- **输入法**：fcitx5 + 中文方案，按 KWin Wayland 方式接管
- **外观**：BreezeDark + WhiteSur 图标/光标，SilentSDDM 登录页，13 张 KOS 壁纸（默认壁纸开箱即用，`--wallpaper` 可换）
- **软件**：Chrome、VS Code、Obsidian、Docker、gh、yazi 等
- **快捷键**：Alt+Enter 终端、Alt+Q 关窗、Win+O 启动器、Win+/ 快捷键查看器、Print 区域截图、Alt+F5 录屏、Alt+F6 热点

## 文档

- [交接状态](docs/HANDOFF.md) — 当前进度、未完成项、本机系统级改动
- [排障手册](docs/TROUBLESHOOTING.md) — 镜像、锁屏、快捷键、热点、回退
- bash install.sh --help — 全部参数与环境变量

## 许可

GPL-3.0-or-later

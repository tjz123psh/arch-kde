# KOS 桌面一键安装器（Arch Linux）

一台能登录 TTY 的干净 Arch → 装完就能用的桌面：**KDE Plasma 6 (Wayland) + KOS/NextKDE 桌面外壳 + kitty + fish**，外加输入法、登录主题、壁纸库和一套常用工具。

~~~bash
git clone https://github.com/tjz123psh/nextkde.git
cd nextkde
bash install.sh --check     # 只预检，不改系统
bash install.sh --all       # 全装（含独立应用 + 锁屏）
~~~

## 要求

- Arch Linux，x86_64，能登录 TTY（刚 archinstall 完的状态就行）
- 一个**普通用户**（不是 root），有 sudo 权限
- 装的时候需要联网；离线装可以先准备好源码，见下面的环境变量

## 装什么

**系统层**

- KDE Plasma 6 + KWin + SDDM + 一套 KDE 应用（Dolphin / Ark / Gwenview / Spectacle / System Monitor）
- 图形栈：mesa / vulkan / VA-API；按硬件自动选 AMD、Intel、NVIDIA（含 Turing 之前的旧卡分支）驱动
- 声音：pipewire + wireplumber + ALSA 兼容层
- 输入法：fcitx5 + 中文输入方案，按 KWin Wayland 的方式接管
- 终端：**kitty**、**fish**、**starship**，外加 fzf / eza / bat / fd / ripgrep / zoxide / fastfetch
- 常用应用：Chrome、VS Code、yazi、flclash、Obsidian、nomacs 等（可用参数关掉）
- 中文环境：locale、Noto CJK / Inter / Maple Mono NF CN 字体

**桌面本体（KOS / NextKDE）**

- 克隆上游仓库，用它的 `kosctl` 构建并安装 Quickshell 外壳、KOS 设置与控制中心
- 独立应用（日历 / 计算器 / 待办 / 天气）、锁屏、全局快捷键（可选）
- KWin 玻璃效果 + genie 最小化动效（genie 插件源码归档在本仓库 `assets/genie`）
- SilentSDDM 登录主题、11 张壁纸的图集（进 KOS 壁纸选择器）

## 关键约定

- **以桌面用户身份运行，不要 sudo**：KOS 配置在 `~/.config/quickshell/kos`，服务是用户单元；用 root 跑会写进 root 的 HOME
- 只写自己的东西：`~/.local/state/kos-installer`（日志、备份清单）、`~/.config/...`、`~/.local/share/kos`；改系统文件前一律先备份
- 破坏性动作（分区、内核、bootloader）不做
- KOS 本体安装失败即中断；可选项（应用 / 锁屏 / 主题 / genie / 壁纸）失败只警告
- 桌面本体源码默认克隆到 `~/.cache/kos-src`，可用 `KOS_SRC_DIR` 改位置；本地已有检出时用 `KOS_REPO_DIR` 指过去，跳过克隆

## 结构

~~~
.
├── install.sh            调度：参数解析、阶段顺序、计划与总结
├── .shellcheckrc         shellcheck 配置（跨文件变量的误报说明）
├── lib/common.sh         日志 / 备份 / install_file / sudo 保活
├── modules/              每个阶段一个文件，按序号执行
│   ├── 00-preflight.sh   发行版、磁盘、网络、GPU 预检
│   ├── 10-packages.sh    镜像、系统更新、官方包、AUR 包
│   ├── 20-hardware.sh    硬件探测（只读 /sys /proc lspci）
│   ├── 30-locale.sh      语言环境
│   ├── 40-system.sh      用户组 / shell / 服务 / 微码 / 驱动
│   ├── 45-ime.sh         fcitx5 配置
│   ├── 50-terminal.sh    kitty / fish / starship
│   ├── 60-kos.sh         KOS 构建依赖 + 取源码 + kosctl 构建安装 + 快捷键
│   ├── 70-genie.sh       genie 最小化动效（归档原生 KWin 插件）
│   ├── 80-sddm.sh        SilentSDDM 登录主题（AUR）
│   ├── 85-config.sh      桌面环境变量 / GTK / 字体 / 壁纸库
│   └── 95-doctor.sh      安装后复查
└── assets/
    ├── config/           fcitx5 / kitty / fish / gtk / fontconfig / environment
    ├── genie/            genie 插件源码
    └── wallpapers/       壁纸库
~~~

## 常用参数

| 参数 | 作用 |
|---|---|
| `--check` | 只预检并出报告，不改系统 |
| `--dry-run` | 打印将要执行的命令，不落盘 |
| `--all` / `--no-apps` / `--no-lockscreen` | 是否装独立应用与锁屏 |
| `--ime fcitx5\|rime\|none` | 输入法 |
| `--locale en\|zh` | 系统语言 |
| `--no-sddm-theme` / `--no-aur` / `--no-mirrors` | 跳过对应步骤 |
| `--no-browser` / `--no-vscode` | 不装 Chrome / VS Code |
| `--no-gpu-amd` / `--no-gpu-intel` / `--no-gpu-nvidia` / `--nvidia-legacy` | 显卡驱动选择 |
| `--wifi-aur` | 允许装机型专属 AUR 无线驱动（默认关，会和内核驱动抢设备） |
| `--spatial` | 同时构建空间景深（需要 OpenCV + ONNX） |
| `--skip-update` | 不更新 KOS 源码（离线安装） |

完整列表：`bash install.sh --help`

## 环境变量

| 变量 | 默认 | 作用 |
|---|---|---|
| `KOS_SRC_DIR` | `~/.cache/kos-src` | KOS 源码检出位置 |
| `KOS_REPO_DIR` | 空 | 已有的源码检出，设置后跳过克隆（本地开发用） |
| `KOS_SRC_URL` | 上游仓库 | 源码地址 |
| `KOS_SRC_REF` | `main` | 源码分支或标签 |

离线装机：先把源码放到 `KOS_SRC_DIR`，再加 `--skip-update`。

## 状态

- 已验证：`--check` 通过、`--dry-run` 全链路通过、genie 插件在本机 KWin 6.8 上编译成功
- CI：`.github/workflows/ci.yml`，bash -n + shellcheck + 干净 Arch 容器里跑 `--check` 与 `--dry-run`（只读检出）
- 待办：首次登录引导未接；`--spatial` 未在干净系统验证；干净系统实机全装还没走过一遍

## 许可

GPL-3.0-or-later（见 `LICENSE`）。桌面本体与 KWin 插件的版权归各自作者；本仓库只负责“把它装上去”。

# 交接状态（新会话先读）

最后更新：2026-10-23

## 一句话

这是 **Arch Linux → KDE Plasma 6 (Wayland) + KOS/NextKDE 桌面**的一键安装器；
仓库只负责“装”和少量必要的用户配置，不包含桌面本体源码。

当前目标机（ASUS TUF A15：Ryzen 7 7735H + RTX 4050 + RTL8852BE）已经实机安装并验收。
仓库最新状态以 `git log -1` 为准，工作区应保持干净。

## 当前已经可用

- 干净 Arch（archinstall 后、能登录 TTY）→ KDE + KOS shell
- 中文 locale / fcitx5 / kitty / fish / starship
- KOS 壁纸库（13 张）
- SilentSDDM 登录主题 + KOS 锁屏（ds2 背景、时钟、天气、歌词、14px 圆角密码框）
- 音量 / 亮度 / 静音使用 **KDE 原生快捷键**（kmix / PowerDevil）；KOS OSD 实验已回退，不再接管这些按键
- 截图快捷键只保留两个：
  - `Print` → Vellum 区域截图
  - `Ctrl+Print` → Vellum 长截图
  - Vellum 自己的 `Meta+Print` / `Meta+Shift+Print` / `Meta+Ctrl+Print`，以及 KOS platform 里重复的 Vellum 动作，都已关闭
- 默认应用、Dolphin 布局、窗口动效、控制中心玻璃、KOS 设置玻璃等已在当前机调过
- 终端（kitty）保留 KOS 窗口装饰：鼠标贴边即可缩放；旧版“无边框”规则会在重装时被自动清理
- `Win+/` 快捷键查看器：KOS + KDE 快捷键按分类列出，媒体键显示成中文键名，Meta 显示为 Win
- `rclone` 随安装器一起装（云盘同步 / 异地备份用；不写任何远端配置）
- 窗口动效：KOS 动画走 genie（最小化吸进 Dock），叠加 KDE 自带的摆动窗口（拖动/缩放形变）

## 仓库结构

```text
install.sh               调度：参数、阶段顺序、计划与总结
lib/common.sh            日志 / 备份 / install_file / write_file / sudo 保活
modules/00..95           按序号 source 进同一个 shell
assets/config/           应用配置（kitty/fish/yazi/fastfetch/mpv/fuzzel/btop 等）
assets/scripts/          maintenance / package / desktop 三组常驻脚本
assets/wallpapers/       13 张壁纸
docs/                    本文件 + 排障手册
```

关键模块：

| 模块 | 责任 |
|---|---|
| `00-preflight` | 预检、内核/headers 探测、硬件探测、archinstall 前提检查 |
| `05-cleanup` | 显式 `--clean-old-desktop` 才删旧桌面包 |
| `10-packages` | 镜像、系统更新、官方包、AUR、硬件固定名单 |
| `20-hardware` | 全量只读硬件探测（doctor 用） |
| `30-locale` / `40-system` | locale、用户组、shell、服务、微码、时间同步、zram、快照 |
| `45-ime` / `50-terminal` / `52-configs` | 输入法、终端、应用配置 |
| `55-apps` | QQ 启动器去重、Vellum 安装 |
| `57-shortcuts` | KDE 快捷键、Vellum 截图键 |
| `58-scripts` | 常驻脚本安装到 `~/scripts`，链接到 `~/bin` |
| `60-kos` | 取上游源码并用 kosctl 构建安装 |
| `80-sddm` / `85-config` | 登录主题、桌面配置、锁屏、OSD 模块 |
| `95-doctor` | 安装后复查 |

## 新会话第一步

在仓库根目录执行：

```bash
git status --short
git log --oneline -8
bash install.sh --check
bash install.sh --dry-run --yes
```

然后按下面的“未完成项”继续，不要假设本文件里的实机状态等于干净 VM 状态。

## 未完成 / 风险

1. **干净 Arch VM 全量复跑**（最高优先级）
   当前实机是在多轮迭代中安装出来的；最新代码没有在干净 VM 上重新跑过
   `install.sh --yes`。按项目约定，改主流程 / 包清单 / 镜像逻辑后必须在干净 VM
   验证，不能只靠宿主 dry-run。

2. **AGENTS.md 仍是旧约束**
   项目级 `AGENTS.md` 的旧桌面清单里还写着 `fuzzel`，但安装器现在把 fuzzel
   当备用启动器安装，`05-cleanup.sh` 已从删除清单移除。按 `AGENTS.md` 自己的
   要求，改它之前要先问用户；新会话不要静默修改。

3. **KDE 原生音量/亮度键的验证**
   当前系统已恢复 KDE 原生快捷键。若下次登录后按键失效，先重启
   `plasma-kded6`（音量）和 `plasma-powerdevil`（亮度），再按排障手册检查
   `kglobalshortcutsrc` 中的 kmix / PowerDevil 动作。

4. **首次登录引导**
   属于桌面仓库（NextKDE）的责任，本仓库不实现。

## 本机系统级改动（安装器不管，重装系统会丢）

下面这些是按用户要求在这台机器上做的，**故意没写进安装器**（引导/登录管理器不在安装器职责内）：

| 项目 | 现状 | 回退方式 |
|---|---|---|
| SDDM 用 Wayland greeter | `/etc/sddm.conf.d/10-wayland.conf`：`DisplayServer=wayland` + `CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts` | 删该文件 → `sudo systemctl restart sddm`；配置备份在 `/root/sddm-backup-20261023-202326/` |
| GRUB 主题 | `Elegant-mojave-window-left-dark`；`GRUB_THEME`、`GRUB_TIMEOUT=5`、`GRUB_GFXMODE=1920x1080,auto`、`GRUB_PRELOAD_MODULES` 含 `usb usb_keyboard` | `/root/grub-backup-20261023-195626/`（`default-grub` + `grub.cfg`），拷回后 `grub-mkconfig` |
| Plasma 桌面壁纸 | 樱吹雪（`~/.local/share/kos/gallery/`），作为 KOS shell 加载完成前的兜底背景，避免登录后黑屏 | 删 `plasma-org.kde.plasma.desktop-appletsrc` 里 `[Containments][1][Wallpaper]` 段 |
| 开机提速 | `NetworkManager-wait-online.service` 已 disable；`rjsupplicant.service` 加了 `10-no-wait-online.conf` drop-in | `systemctl enable --now NetworkManager-wait-online`；删 drop-in 后 `daemon-reload` |

⚠️ `/boot` 是 **vfat（EFI 分区）**，GRUB 主题只能用 `cp -rL`（解引用符号链接）安装；上游 `install.sh` 的直接 `cp -a` 会因为符号链接报 `文件已存在`。

> 2026-10-24 起：GRUB 主题与登录头像已纳入安装器（`modules/15-grub-theme.sh` + `assets/grub-theme/`、`modules/80-sddm.sh` + `assets/avatar/`），不再需要手动处理。

## KOS 启动慢的已知瓶颈（上游问题，未解决）

登录后 KOS 顶栏/Dock 要等约 8 秒才出现。实测：`kos-shell` 单独重启只需 ~2.7 秒（CPU 满载、清空页缓存都一样），
登录时慢是因为 **KWin 启动阶段在编译 KOS 的效果着色器**，主循环不响应桥接轮询，shell 只能等。
日志特征：`KOS continuous corners: shader failed; using native arcs`（该 shader 编译失败，属上游 bug）。
已做缓解：给 Plasma 桌面配了壁纸，过渡期间显示壁纸而不是黑屏。
## 常用验证

```bash
# 仓库门禁
for f in install.sh lib/*.sh modules/*.sh; do bash -n "$f"; done
shellcheck install.sh lib/*.sh modules/*.sh
bash install.sh --check
bash install.sh --dry-run --yes
bash install.sh --dry-run --yes --no-archlinuxcn --no-aur

# 截图键位（应该只剩两个）
grep -nE 'Print|vellum' ~/.config/kglobalshortcutsrc
```

## 快捷键（2026-10-24 定稿）

安装器在 `modules/57-shortcuts.sh` 里写入，装完注销重登生效：

| 快捷键 | 功能 |
|---|---|
| `Meta+F` / `Meta+C` | 最大化 / 最小化窗口 |
| `Alt+Q` | 关闭窗口 |
| `Alt+F4` | 强制终止窗口（默认值仍为 Meta+Ctrl+Esc） |
| `Alt+K/J/H/L` | 切换到上/下/左/右的窗口 |
| `Alt+Shift+H/L` | 切换到左/右工作区 |
| `Alt+Return` | 打开终端（kitty） |
| `Alt+W` | 壁纸全屏预览 |
| `Ctrl+M` | 备用启动器（fuzzel） |
| `Meta+M` | 系统监视（btop） |
| `Meta+Shift+C` | 终端工具菜单 |
| `Meta+/` | 快捷键查看器 |
| `Alt+F5` / `Alt+F6` | 录屏菜单 / 热点菜单 |
| `Print` / `Ctrl+Print` | 区域截图 / 长截图（Vellum） |

KOS 壳自己的快捷键存在 `~/.local/state/quickshell/kos/shortcuts/config.json`：启动器 `Meta`、快速搜索 `Meta+O`，其余为 KOS 默认。

## 约定（不要破坏）

- 以桌面用户身份运行，**不要整脚本 sudo**；KOS 配置写 `~/.config/quickshell/kos`。
- 不碰分区、挂载、bootloader、内核安装/切换、时区。
- 写系统文件先 `backup_file`；备份在 `~/.local/state/kos-installer/backup/<时间>/`。
- KOS 本体失败 `die`；独立应用 / 锁屏 / 主题 / OSD / 壁纸失败只 `warn`。
- 图片：“截图”和“壁纸”不要混淆；用户说的“镜像文件”指 pacman mirrorlist，不是软件包。
- 不要把测试 VM 密码、token、密钥写进仓库、文档或提交信息。

## 当前提交锚点

- 后续以 `git log` 为准；KOS OSD 实验已在后续提交里回退。

- `05685d6` feat(lock): customize KOS lock screen
- `51ff09f` chore(shortcuts): keep only Print and Ctrl+Print for screenshots

后续提交以 `git log` 为准。

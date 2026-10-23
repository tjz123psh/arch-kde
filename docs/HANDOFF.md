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

4. **genie 插件归档**
   `genie-effect-2026-10-21.tar.gz` 还在仓库根目录；已停用，不影响安装。
   是否移入 `docs/archive/` 需要先确认，不要直接删。

5. **首次登录引导**
   属于桌面仓库（NextKDE）的责任，本仓库不实现。

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

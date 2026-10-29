# 交接状态（新会话先读）

最后更新：2026-10-29

## 一句话

这是 **Arch Linux → KDE Plasma 6 (Wayland) + KOS/NextKDE 桌面**的一键安装器；
仓库只负责“装”和少量必要的用户配置，不包含桌面本体源码。

当前目标机（ASUS TUF A15：Ryzen 7 7735H + RTX 4050 + RTL8852BE）已经实机安装并验收。
仓库最新状态以 `git log -1` 为准，工作区应保持干净。

## 当前已经可用

- 干净 Arch（archinstall 后、能登录 TTY）→ KDE + KOS shell
- 中文 locale / fcitx5 / kitty / fish / starship
- KOS 壁纸库（13 张）
- SilentSDDM 登录主题 + KOS 锁屏（ds2 背景、时钟、天气、歌词、14px 圆角密码框）。KOS 的锁屏 QML
  依赖 greeter 注入的壁纸项，而 KOS 桌面接管壁纸后那一项是空的（实测 `texture -1x-1`、walk
  找不到 still image）；安装器因此在**锁屏包外面**写 `~/.config/kscreenlockerrc`
  `[Greeter][Wallpaper][org.kde.image][General] Image=~/.local/share/kos/lockscreen.png`（ds2 副本），
  `kosctl install lockscreen` 重建包也不会丢
- 音量 / 亮度 / 静音使用 **KDE 原生快捷键**（kmix / PowerDevil）；KOS OSD 实验已回退，不再接管这些按键
- 截图快捷键只保留两个：
  - `Print` → Vellum 区域截图
  - `Ctrl+Print` → Vellum 长截图
  - Vellum 自己的 `Meta+Print` / `Meta+Shift+Print` / `Meta+Ctrl+Print`，以及 KOS platform 里重复的 Vellum 动作，都已关闭
- 默认应用、Dolphin 布局、窗口动效、控制中心玻璃、KOS 设置玻璃等已在当前机调过
- 终端（kitty）保留 KOS 窗口装饰：鼠标贴边即可缩放；旧版“无边框”规则会在重装时被自动清理
- 触摸板：滚动方向改成“内容跟手指走”（和 Windows 一致，`NaturalScroll=true`，由 `modules/85-config.sh` 写进 `kcminputrc`）；`Fn+F10` 是真正的开关——安装器用用户级组件 `~/.local/share/kglobalaccel/org.kde.touchpadshortcuts.desktop` 覆盖系统那份，把“切换”动作的 Exec 换成 `~/.local/bin/kos-touchpad-toggle`（400ms 防抖，源码在 `assets/config/shortcuts/`），三个触摸板键都绑在这一个动作上；改完要注销重登（KGlobalAccel 在会话启动时读组件）
- `Win+/` 快捷键查看器：KOS + KDE 快捷键按分类列出，媒体键显示成中文键名，Meta 显示为 Win
- `rclone` 随安装器一起装（云盘同步 / 异地备份用；不写任何远端配置）
- 窗口动效：KOS 动画走 genie（最小化吸进 Dock），叠加 KDE 自带的摆动窗口（拖动/缩放形变）
- 默认壁纸：安装器把 Plasma 桌面和 KOS 都指到图集里的一张（默认 `樱吹雪.png`，`--wallpaper` 可改），
  不再出现 KDE 默认壁纸；用户自己在图集里选过的图不会被重跑覆盖
- 回滚：**没有自动回滚命令**（2026-10-25 按用户要求把 `kos-undo` 整个删掉了）。三条路：
  ① `bash install.sh --yes` 是幂等的，重跑一遍能修好大部分问题；
  ② 被覆盖的文件在 `~/.local/state/kos-installer/backup/<时间>/`，`manifest.txt` 每行是
  `<原路径> <sha256> <备份路径>`（`created <原路径>` = 安装器新建的），手动拷回/删除；
  ③ 整机回档用 Snapper / btrfs-assistant（装桌面前会落一个 `kos-installer: before desktop` 快照）。

## 仓库结构

```text
install.sh               调度：参数、阶段顺序、计划与总结
lib/common.sh            日志 / 备份 / install_file / write_file / sudo 保活
modules/00..95           按序号 source 进同一个 shell
assets/config/           应用配置（kitty/fish/yazi/fastfetch/mpv/fuzzel/btop 等）
                         + display / shortcuts：被桌面配置调用的小工具
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
| `15-grub-theme` | GRUB 主题（只改显示相关项，失败只 warn） |
| `20-hardware` | 全量只读硬件探测（doctor 用） |
| `30-locale` / `40-system` | locale、用户组、shell、服务、微码、时间同步、zram、快照 |
| `45-ime` / `47-hotspot` / `50-terminal` / `52-configs` | 输入法、热点转发 drop-in、终端、应用配置 |
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

1. **干净 Arch VM 全量复跑**（2026-10-25 完成，结论留档）
   干净 VM（VMware，archinstall 后 TTY）跑 `install.sh --yes`，commit `e893ac1`：
   耗时 29 分 52 秒、日志 0 ERROR、装 985 个包；按 VM 硬件算的官方清单 152/152、
   AUR 21/21 一个不缺；`sassc` 构建后即卸；doctor 复跑 0 MISS；29 份配置文件里
   27 份与仓库逐字节一致（2 份 GTK `settings.ini` 被 kde-gtk-config 重写，内容正确：
   `gtk-font-name=Noto Sans CJK SC`）。
   前后三轮（首次安装 + 两次在运行中的桌面里重跑）一共发现并修掉四处：
   - 默认壁纸预置被"只有 themeAnimated 的 wallpaper.ini"挡住而跳过（`57f816c`）；
   - doctor 声卡与装饰行误报（`6407f2e`）；
   - 重跑时先写 `none,none` 再让 KGlobalAccel 解除绑定，导致这个键被整条抹掉、
     KDE 回落到默认 Meta（`554cba0`，改成先解绑再写）；
   - Plasma 桌面配置写到 `plasma-org.kde.plasma.desktop-appletsrc`，而 KOS 的 shell 包
     是 `org.kos.desktop`，plasmashell 实际读的是 `plasma-org.kos.desktop-appletsrc`
     （`8f78364`，改成按存在的文件解析，doctor 同时接受 KOS 生成的 KOS-Backdrop 壁纸）。
   第三轮（`8f78364`）在 VM 上确认：appletsrc 的 `Image` 落到
   `file:///…/kos/gallery/樱吹雪.png`、`activate application launcher` 保持
   `none,none,…`、doctor 0 MISS、包数与快捷键无重复。
   仍未覆盖：真实锁屏画面（只验证了 `plasmashellrc ShellPackage=org.kos.desktop` 与
   QML 补丁在位）、多显示器、Wi-Fi/蓝牙/摄像头/独显（VM 无硬件）、实际出声
   （`wpctl` 有 sink、`paplay` 返回 0）。判据表见 `docs/VM-CHECKLIST.md`。

2. **KDE 原生音量/亮度键的验证**
   当前系统已恢复 KDE 原生快捷键。若下次登录后按键失效，先重启
   `plasma-kded6`（音量）和 `plasma-powerdevil`（亮度），再按排障手册检查
   `kglobalshortcutsrc` 中的 kmix / PowerDevil 动作。

3. **首次登录引导**
   属于桌面仓库（NextKDE）的责任，本仓库不实现。

4. **锁屏：壁纸在包外，细节补丁在包里**
   KOS 接管壁纸后，kscreenlocker greeter 交给锁屏的壁纸项没有贴图，没配置图源的锁屏只剩 KOS 自带的罩底底色（黑屏）。
   安装器把图源写在包外：`~/.config/kscreenlockerrc` →
   `[Greeter][Wallpaper][org.kde.image][General] Image=~/.local/share/kos/lockscreen.png`（ds2 副本），
   `kosctl install lockscreen` 重建 KOS 包不影响它。14px 密码框圆角、隐藏日历/表盘是包内
   `LockScreen.qml` / `LockWidgets.qml` 的补丁，KOS 重建包后会回到上游原版（只影响观感）；
   `doctor` 报 `[WARN]`，重跑 `bash install.sh --yes` 恢复。2026-10-29 用
   `/usr/lib/kscreenlocker_greet --testing` 截图验证：上游 QML + 这条 kscreenlockerrc 就能正常出图
   （本机 16:48 的 KOS 更新把旧版包内补丁冲掉，正是那次黑屏的原因）。

## 本机系统级改动（安装器不管）

2026-10-25 复查：SDDM Wayland greeter、GRUB 主题、登录头像、桌面壁纸都已经并入安装器
（`modules/80-sddm.sh`、`modules/15-grub-theme.sh`、`modules/85-config.sh`），重装会自己带上。
真正留在安装器之外的只剩"开机提速"这一条：

| 项目 | 现状 | 回退方式 |
|---|---|---|
| 开机提速 | `NetworkManager-wait-online.service` 已 disable；`rjsupplicant.service` 加了 `10-no-wait-online.conf` drop-in | `systemctl enable --now NetworkManager-wait-online`；删 drop-in 后 `daemon-reload` |

⚠️ `/boot` 是 **vfat（EFI 分区）**，GRUB 主题只能用 `cp -rL`（解引用符号链接）安装；
直接 `cp -a` 会因为符号链接报"文件已存在"。`modules/15-grub-theme.sh` 用的就是 `-L`。

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

# 触摸板热键：组件只剩一个动作，三个触摸板键都绑在它上面
qdbus6 --literal org.kde.kglobalaccel /component/org_kde_touchpadshortcuts_desktop \
  org.kde.kglobalaccel.Component.allShortcutInfos
```

## 快捷键（2026-10-24 定稿）

安装器在 `modules/57-shortcuts.sh` 里写入，装完注销重登生效：

| 快捷键 | 功能 |
|---|---|
| `Meta+F` / `Meta+C` | 最大化 / 最小化窗口 |
| `Alt+Q` | 关闭窗口（只绑这一个键，不再附带 Alt+F4） |
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

以 `git log` 为准（本节只是最近一次的写作锚点，别当成 HEAD）：

- `b0b94a1` fix(lock): take the lock screen wallpaper from kscreenlockerrc, not the KOS package
- `ff9e7cc` refactor(input): ship the touchpad wrapper from config/ and stop shadowing shortcutsrc
- `b552512` chore: drop a stray __pycache__ and ignore bytecode
- `41e9a21` fix(input): debounce the Fn+F10 touchpad toggle

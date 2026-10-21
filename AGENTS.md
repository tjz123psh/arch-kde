# 项目级指令（AGENTS）

本文件是本仓库对 agent 的最高约束，优先级高于一般操作惯例。改动本文件先问用户。

## 一、工作区边界

- **唯一可写范围**：`/home/pang/Projects/arch-kde/`。编辑、git、构建产物、运行脚本都先确认路径在仓库内。
- **不碰宿主机系统**：不在宿主上装/卸包、不改 `/etc`、不启停服务、不动引导/分区/网络。验证只在一次性虚拟机里做。
- **凭据纪律**：不读取、不打印、不提交任何密码/token/密钥。测试 VM 的账号密码只在会话里用，不写进仓库、文档、提交信息或日志。
- **删除类操作**：只用精确路径、禁用通配；删前查引用（README / 脚本 / 台账）。不确定就先问。

## 二、仓库定位

- 一键把**干净 Arch（archinstall 之后、能登录 TTY）**装成 KDE Plasma 6 (Wayland) + KOS/NextKDE 桌面。
- **这里只有安装器**：桌面本体（Quickshell 外壳、kosctl、KWin 插件）在上游 `SuceV587/NextKde`，安装时克隆到 `~/.cache/kos-src`。
- 公开仓库，remote `https://github.com/tjz123psh/arch-kde.git`，GPL-3.0-or-later。
- 数据资产是核心：`assets/config/`（fcitx5 / kitty / fish / gtk / fontconfig / environment）、`assets/wallpapers/`（11 张）；genie 插件源码已压缩归档在仓库根目录 `genie-effect-2026-10-21.tar.gz`（已停用，待以后处理）。

## 三、结构约定

```
install.sh          调度：参数解析、阶段顺序、计划与总结
lib/common.sh       日志 / 备份 / install_file / write_file / sudo 保活
modules/00..95      每个阶段一个文件，按序号 source 进同一个 shell
assets/             配置、壁纸
```

- 阶段函数由 `install.sh` 的 `main()` 顺序调用；模块之间共享变量，所以 `.shellcheckrc` 关了 SC2034/SC1091。
- 新增阶段：文件按序号命名，函数只做一件事；需要 sudo 的用 `sudo_run`，写文件的用 `install_file` / `write_file` / `sudo_write_file`（自带备份）。
- 所有写系统文件的动作必须走 `backup_file`（备份到 `~/.local/state/kos-installer/backup/<时间>/`，`manifest.txt` 记路径 + sha256）。

## 四、硬约定（改之前先读）

1. **以桌面用户身份运行，不要整脚本 sudo**：KOS 配置写 `~/.config/quickshell/kos`，用 root 跑会写进 root 的 HOME。
2. **破坏性动作不做**：分区、挂载、bootloader、内核安装/切换、时区都不碰；这些是 archinstall 的前提。
3. **硬件固定按目标机**：ASUS TUF A15（AMD 7735H + RTX 4050 + RTL8852BE）。驱动名单写死在 `modules/10-packages.sh` 的"硬件驱动：固定按目标机装"一段，**不再按探测结果决定装包**；换机器时改那一段和 `hw_policy_resolve()`。蓝牙固定装 `bluez` + `bluedevil` + `bluez-obex`，`bluetooth.service` 常开；打印、指纹、WWAN 不装。
4. **archinstall 前提只做 `--needed` 兜底**：内核 headers、`neovim`、`exfatprogs`、`os-prober`、`zram-generator`。装过就跳过。
5. **镜像文件策略**：默认整份覆盖 `/etc/pacman.d/mirrorlist`（archinstall 常留 aliyun 单源）与 `/etc/pacman.d/archlinuxcn-mirrorlist`；清华必须第一，官方 16 个 / archlinuxcn 12 个国内镜像；网络失败自动降级（注释当前第一条 `Server =`，最多 3 次）。改镜像清单要重新用 curl 验证 `core.db` / `archlinuxcn.db`。
6. **失败分级**：KOS 本体安装失败即 `die`；独立应用 / 锁屏 / 主题 / 壁纸失败只 `warn`。
7. **不要"顺手"扩展**：微信启动器不需要去重（用户 2026-10-21 确认）；QQ 需要（`modules/55-apps.sh`）。

## 五、改动规则

- 提交前必跑，任一失败不得提交：
  ```bash
  for f in install.sh lib/*.sh modules/*.sh; do bash -n "$f"; done
  shellcheck install.sh lib/*.sh modules/*.sh
  bash install.sh --check
  bash install.sh --dry-run --yes
  bash install.sh --dry-run --yes --no-archlinuxcn --no-aur
  ```
- CI（`.github/workflows/ci.yml`）：语法 + shellcheck + 干净 Arch 容器里的 `--check` / `--dry-run`，必须绿。
- **改主流程 / 阶段顺序 / 包清单 / 镜像逻辑**：必须在一台干净 Arch 虚拟机里完整跑一次 `install.sh --yes` 再提交，不能只靠宿主 dry-run。
- 提交信息用 Conventional Commits（`feat:` / `fix:` / `docs:` / `refactor:` / `chore:`），一次提交只做一件事。
- 推送前按 `git-push` 技能：确认 remote/分支/待推 commit，gitleaks 扫工作区与历史，公开仓库不推密钥。

## 六、验收基线

- `install.sh --check` 通过；`install.sh --dry-run` 全阶段走通。
- 干净 VM 全装后：能进 SDDM → KDE → KOS shell；KDE 界面为中文，主屏 1920x1080（显示器支持时）；doctor 无 MISS（硬件没有的项除外）；KOS 窗口动画、壁纸库、fcitx5、kitty/fish 可用。
- 装完立即重启一次，确认没有黑屏/起不来（尤其 NVIDIA 与微码改动）。

## 七、已知缺口 / 待办

- 干净系统实机全装验收（VM 安装进行中；以实测日志为准，不要拿 dry-run 当验收）。
- QQ 启动器去重已在 `55-apps.sh` 落地，装完需要在真实会话里看一眼 Dock/启动器。
- 硬件驱动是固定名单（目标机 ASUS TUF A15）；换机器要同步改 `modules/10-packages.sh`。
- 首次登录引导属于桌面仓库，本仓库不承担。
- 仓库还没有单独的 `tests/`；CI 的内联检查是当前唯一自动化门禁。

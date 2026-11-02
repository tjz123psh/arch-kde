# KOS 桌面更新器（`update.sh`）

KOS = 上游 [SuceV587/NextKde](https://github.com/SuceV587/NextKde) 桌面外壳。它**不在**
Arch 官方仓库、archlinuxcn 或 AUR 里，`paru -Syu` 只更新它的依赖（quickshell / qt6 / kwin），
外壳本体只能走上游 GitHub 发布。本脚本把官方 `kosctl` 的动作收成一条命令，并处理两个真实痛点。

## 快速开始

```bash
kos                     # fzf 菜单（终端命令，软链：~/bin/kos）
kos check               # 查上游最新正式 tag
kos update              # 更新到最新正式版
```

三种启动方式：

| 入口 | 用法 |
|---|---|
| 终端命令 | `kos`（无参数进菜单）或 `kos <子命令>`（`~/bin/kos` → 本脚本的软链） |
| 桌面启动器 | 启动器里搜「KOS 桌面更新」（`~/.local/share/applications/kos-update.desktop`，用 kitty 打开菜单） |
| 定时检查 | `kos-update-check.timer` 每日 12:00 检查，有新版本才通知，不安装 |

直接用路径也行：`~/scripts/kos/update.sh [命令]`。

## 为什么不是 `kosctl update` 直接跑

| 问题 | 本脚本的做法 |
|---|---|
| 本地有未提交改动时，`kosctl update` 的源码选择器直接报 "Working tree has local changes" 拒绝切换 | 先 `git diff` 导出到 `~/.local/state/kos/local-patches/`，清干净工作区，切换后自动重打；冲突则留 `.rej` 并**中止构建** |
| 不带参数的 `kosctl update` 走 GitHub API 查 Latest，本机 `urllib` 实测会 403 rate limit | 用 `git ls-remote --tags` 自己算最新正式 tag（无 API、无需凭据），再显式传给 `kosctl update vX.Y.Z` |

## 固定的设计取舍

| 抉择 | 取值 | 理由 |
|---|---|---|
| 默认通道 | `stable`（GitHub 最新正式 tag） | `main` 是开发线（上游 `VERSION` 仍是 `0.1.0-dev`），要显式 `update main` |
| 依赖策略 | **只补 KOS 构建依赖**，从不 `pacman -Syu` | 系统滚动是独立决策（内核/NVIDIA/Qt6 全在里面），不该被一次桌面更新顺手带走。构建依赖由 `kosctl install` 自己补 |
| 交互 | 默认 fzf 全屏菜单 + 子命令 | 菜单左列只放动作（窄屏不截断），右侧预览显示状态 / 更新说明 / 补丁 / 日志 |
| 补丁 | 自动保存 → 重打 → 冲突即停 | 本地 25 行 KWin 6.8 兼容补丁上游还没有，丢了就没法用 |
| 定时 | user timer 每日检查 + 通知，**不自动安装** | 自动安装要 sudo 提权且必须注销才生效，不适合无人值守 |

## 命令

| 命令 | 作用 |
|---|---|
| `status [--json]` | 已装版本、源码检出、最新 tag、补丁、应用/锁屏、用户服务、上次更新 |
| `check [--json]` | 正式版看最新 tag、dev 版看上游 `main` 有无新提交；有变化退出码 `10` |
| `update [stable\|main\|vX.Y.Z]` | 完整更新流程（见下）；`update main` 就是「拉取 main 最新并重建」 |
| `rollback` | 从历史 tag 里选一个重装 |
| `patch list\|save\|apply\|drop` | 本地补丁管理 |
| `build` | 不换源码，仅按当前检出重新构建部署 |
| `start` | `kosctl start`，重启 KOS 用户服务 |
| `logs [--all\|-f]` | 最近一次更新日志 |
| `notes [tag]` | 打印某个版本的发布说明（默认最新正式版），预览面板的 ctrl-e 走的就是它 |

选项：`-y/--yes`、`-n/--dry-run`、`--start`（更新后启动）、`--notify`、`-q/--quiet`、`--json`。

`--json` 只对 `status` / `check` 有效（其他命令会明确报参数错误）。未核对过最新版本时输出
`"latest": null, "updateAvailable": null, "checked": false`，不会把“查不到”说成“有新版本”。

## 交互约定（菜单）

- **整个会话跑在终端备用屏里**：进入即切屏，退出即还原，菜单和动作输出不会留在主屏或
  scrollback 里，反复打开看不到上一轮的残影；退出后在主屏只留一行“收据”
  （已装版本 / 是否最新 / 日志目录）。
- 出错时先还原屏幕再打印错误，**并把最近日志尾部重打到主屏**（仅限已建立日志的后期失败），
  所以“更新失败”时当屏就能看到上下文，不用再翻会话。
- 收据在窄终端（<100 列）自动换短版，保证真的只占一行。
- main 行的数据来自 `main-head` 缓存，超过 15 分钟会标注「缓存 N 前，已过期 · 未核对」，
  不再把陈值当结论；`check` 刷新失败时明确报「无法判断」，不会静默沿用旧值。
- 走 main 开发版时（VERSION 形如 `0.1.0-dev`），`check` 改为比较**上游 main HEAD 与已部署 revision**：
  有新提交就报「main 有新提交：已部署 b30e71d → 上游 3fa1d70（日期）+ 提交标题」，退出码 `10`；
  一致则报「main 无新提交」。状态卡常驻一行 `main`，`--json` 里带 `"dev": true` 与 `main` 块。
  main HEAD 缓存在 `~/.local/state/kos/main-head`（15 分钟 TTL，预览/状态卡只读缓存）。
- 预览面板**零网络、零写盘**：只读本地缓存；缓存过期时状态卡标注“缓存 x 前，已过期，未核对”，
  不会把陈数据当成“已是最新”。抓取动作只在 `check` / `notes` / `ctrl-e` 里发生。
- 快捷键：`Enter` 执行 · `Esc` 退出 · `/` 过滤 · `?` 预览开关 · `alt-h` 帮助 ·
  `ctrl-e` 发布说明 · `ctrl-g` 更新日志 · `ctrl-o` 状态快照（后三者与 `alt-h` 都用 `less` 分页，`q` 返回菜单）。
- `update` 先打印计划（目标版本 / 本地改动 / 提权）再确认一次，`-y` 跳过确认；
  同版本重装也只确认一次。
- 非交互终端（管道、CI）不会进入菜单，会提示改用子命令；非交互下 `confirm` **不会**自动同意，
  需要 `-y`（否则打印“非交互模式不自动确认”并取消）。
- **单实例**：同一时间只允许一个菜单会话（`menu.lock` + `menu.pid`）。重复点启动器时，
  第二个窗口会提示「已有一个更新窗口在运行」、发一条桌面通知并立刻退出，不会留着两个相互不知道的会话。
  锁在会话结束时释放；若主进程被 `kill -9`，下次启动会用 `menu.pid` 判活并自动接管遗留锁。
- **`--hold`**：桌面启动器用它（`Exec=… update.sh --hold`）。没有它时脚本一退出，kitty 窗口就
  跟着关闭，出错信息会被带走；加上后所有退出路径都先停住等按键。
- 补丁冲突时不做任何修改（不再 `git apply --reject` 留下半应用树）；历史遗留的 `.rej` 会被移到
  `rejects/<时间>/`（保留相对路径），并打印“当前状态 + 三条出路”。
- 源码检出缺失时菜单不再整体退出：`状态/检查/日志/启动` 照常可用，依赖源码的条目
  （更新/回退/补丁/重建）会给出修复命令而不是崩溃。
- 缺依赖（`fzf`/`git`/`flock`）退出码为 **127**，与执行失败（1）、参数错误（2）区分。

## 更新流程

```
1/6 保存本地改动（导出补丁到 ~/.local/state/kos/local-patches/）
2/6 选择源码（kosctl update vX.Y.Z / main，detached 检出）
3/6 重打本地补丁（按导出时间；补丁头记录基线 `# kos-source: <通道>@<rev>`，不符则跳过；
    纯 check 失败再试 3-way，仍失败则不做任何修改并中止）
4/6 检查构建依赖（kosctl doctor；提权经 gsudo）
5/6 构建并部署核心（kosctl install）
6/6 独立应用 / 锁屏（按检测结果）/ 快捷键（无条件尝试，0.1.1 后该子命令已废弃，失败可忽略）
```

结束后需**注销并重新登录**，KWin 特效与锁屏才换成新版本（这是上游行为，不是脚本能绕过的）。

## 状态目录

| 路径 | 内容 |
|---|---|
| `~/.local/state/kos/local-patches/` | 导出的补丁（`kos-local-<rev>-<时间>.patch`）；`archive/` 是不参与自动重打的归档（构建成功后脚本自动移入），`rejects/` 存历史拒绝块（保留原相对路径） |
| `~/.local/state/kos/update-logs/` | 每次更新的完整输出日志 |
| `~/.local/state/kos/latest-tag` | 最新 tag 缓存（15 分钟 TTL，菜单重绘靠它避免打网络） |
| `~/.local/state/kos/main-head` | 上游 main HEAD 缓存（`sha\|日期\|标题`，dev 版判定用） |
| `~/.local/state/kos/releases/` | 拉下来的中文发布说明（预览面板用） |
| `~/.local/state/kos/install-backups/` | 上游 `kosctl install` 自己的配置/运行树备份 |

## 定时检查

`~/.config/systemd/user/kos-update-check.{service,timer}`：每日 **12:00（±15 分钟随机）** 跑一次 `check --notify --quiet`，
**只有存在变化时才** `notify-send`，其余静默；网络不可达时打一行警告并按 0 退出（不把单元标成 failed）。
跑 main 开发版时：main 有新提交会提醒（同一个提交只一次，记在 `last-notified-main`），
上游发了新正式 tag 也会提醒一次（记在 `last-notified-tag`）。

```bash
systemctl --user list-timers kos-update-check.timer
systemctl --user start kos-update-check.service   # 立即跑一次
journalctl --user -u kos-update-check.service -n 20
```

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 正常 / 已是最新 / 用户取消 |
| 10 | 有新版本（`check`） |
| 1 | 执行失败 |
| 2 | 参数错误 |
| 127 | 缺少依赖（fzf / git / flock） |

## 测试

```bash
bash ~/scripts/kos/tests/run.sh      # 69 项回归，隔离在 mktemp 目录里跑
bash ~/scripts/kos/tests/run.sh -v   # 失败时打印完整输出
```

覆盖：用法/参数顺序、JSON 契约（含 dev 版与 main 块）、main 有无新提交的判定、
缺源码与离线降级、dry-run 零副作用、
补丁 save/apply/冲突不半应用、systemd 单元与 timer 契约、启动器与 `kos` 软链、
以及 pty 里的 `--hold` 停住与「菜单退出后备用屏配平」。

## 环境变量

| 变量 | 作用 |
|---|---|
| `KOS_REPO_DIR` | 源码检出目录（默认 `~/.cache/kos-src`） |
| `KOS_PREFIX` | 安装前缀（默认 `~/.local`） |
| `KOS_SRC_URL` | 上游仓库地址（镜像/自建 fork） |
| `KOS_GIT_TIMEOUT` | 上游查询超时秒数（默认 30；`git ls-remote` 不再无限挂起，且禁用交互式凭据提示） |
| `KOS_CHANNEL` | 默认更新通道（默认 `stable`） |
| `KOS_HOLD` | 等价于 `--hold` |

## 已知限制

- 不处理 pacman 侧升级；`check` 不报告系统待升级包（用 `checkupdates`）。
- `kosctl update` 需要**干净工作区**；仓库里的未跟踪文件也会阻挡，脚本会列出来并中止。
- 浅克隆（`--depth 1`）无法比较与 `main` 的分叉提交数，只能看各自 HEAD。
- NixOS 不支持这套流程（上游 `kosctl` 直接拒绝，`/nix/store` 只读）。

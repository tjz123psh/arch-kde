# package —— Arch 包管理三件套

在终端里敲三个命令，就能装、卸、降级软件：**`pac` 装、`pacr` 卸、`pacd` 降级**。

都是模糊搜索 + 多选：输入关键词、Tab 勾选、回车执行。装 AUR 包之前可以先用 AI 看一遍它的构建脚本，卸完之后可以顺手把家目录里剩下的配置、缓存一并清掉。

> **AUR 是什么**：官方的 pacman 源之外，还有一个社区仓库（Arch User Repository）。里面放的不是编译好的包，而是"怎么下载、怎么编译"的脚本（PKGBUILD），谁都能提交、官方不审核。所以装之前看一眼脚本干了什么，是件值得做的事 —— 这就是这里要加 AI 审查的原因。

---

## 快速开始

```bash
pac  关键词     # 装：官方源、AUR、Flatpak 一起搜
pacr 关键词     # 卸：卸载，并可顺手清理家目录残留
pacd 关键词     # 降级：退回到旧版本
```

三个命令都装在 PATH 上，任意目录直接敲。在 fish 里敲 `paru 关键词` 也会打开 `pac`。

忘了参数就敲 `pac --help`（写 `pac help` 也行），`pacr`、`pacd` 同样支持；`pac ai --help` 是 AI 配置的用法。

想用 AI 审查，多花两分钟配置一下（见「配置 AI」）；**不配也能用**，只是 AUR 包少一道检查。

---

## 装东西：`pac`

一条列表里三种来源，用颜色区分：

| 来源 | 颜色 | 说明 |
|---|---|---|
| 官方源 | 蓝色 | pacman 仓库里的包 |
| AUR | 紫色 | 社区包，装之前会走 AI 审查 |
| Flatpak | 青色 | 装了 flatpak 才会出现 |

选包时右边（或下方）有预览：版本、描述、来源一目了然。**Tab 多选、回车安装**。

选中 AUR 包时会多问一句「是否先进行 PKGBUILD 审查? [Y/n/m]」：

- **低风险** → 默认继续安装（回车即可）
- **中 / 高风险** → 默认**不装**，要你明确按 `y` 才继续
- **没配 AI、或审查出错** → 不猜，直接交回给 paru 自带的 PKGBUILD 复核，不会偷偷跳过

常用参数：

```bash
pac --check 包名      # 只审查 AUR 包，不安装
pac --no-ai           # 这一次不审查，直接装
pac --flatpak         # 只看 Flatpak（原来的 pak 命令）
pac --clear-cache     # 清掉包索引、预览与审查产物
```

---

## 卸东西：`pacr`

同一条列表里列出已装的 Pacman / AUR 与 Flatpak 软件，多选卸载。卸载成功之后会问：

```
是否清理家目录残留? [Y/n]
```

回答 Y 就列出候选 —— 每一条都带**体积、来源、置信度和一句话理由**，勾选后要输入 `delete` 才真的删（永久删除，不进回收站）。

候选从三个地方来：包名与命令名派生的关键词、家目录里的同名目录（连 `~/Documents/...` 这类偏门位置也会限深搜一遍）、以及 `--trace` 模式实际追踪到的读写路径。

```bash
pacr --scan 包名               # 只列出候选，卸载和删除都不做（先看它想删什么）
pacr --no-clean 包名           # 只卸载，不找残留
pacr --no-ai 包名              # 这一次不用 AI 判残留
pacr --trace 包名              # 卸载前先跑一次程序，看它真实读写过哪些路径
pacr --trace-command <命令>    # 追踪任意程序（原来的 pacrrr 命令）
```

---

## 降级：`pacd`

模糊搜索已安装的包，交给 `downgrade` 回退版本：来源可以是本地缓存（`/var/cache/pacman/pkg`）或 Arch 官方归档（A.L.A）。界面会显示包的真实来源（官方源 / AUR），依赖冲突由 pacman 自己拦下。

需要装 `downgrade`（官方源里有），缺了会直接告诉你装法。

---

## AI 到底做了什么

**审查 AUR 包**：脚本先把证据备齐 —— PKGBUILD 全文、`.install` 脚本、补丁、AUR 上的元数据（维护者、票数、上架时间）、git 历史，以及**最近几次提交的 diff**（投毒几乎都是靠一次"更新"进来的）。然后把证据交给模型，模型只负责"报出它看到了什么"并附上原文；**风险级别由脚本按固定规则算**，模型无权定级，它引用的原文在证据里找不到就不算数。整个审查期间模型拿不到任何工具，执行不了命令。

**判定残留**：`pacr` 把候选清单交给模型判置信度并给一句理由，帮你决定哪些能删；模型额外想到的路径也会经同一套校验后列出来。

**没配 AI 时**：AUR 包不做审查（但仍然保留 paru 自带的那道复核），残留只按名字匹配列出。功能都还在，只是少一层把关。

---

## 安全边界

1. **只动家目录**。`.ssh`、`.gnupg`、密钥环、shell 配置文件与历史、共享的字体 / 图标 / 主题缓存、`Documents` 这类顶层目录整体……永远不会出现在清单里。AI 说的路径也要过同一道校验：必须存在、在家目录内、不是软链接、不在豁免名单。
2. **删除过两道闸**：先勾选，再输入确认词 `delete`；确认词不对，一条都不删。
3. **审查没跑成，不会顺带把 paru 自带的复核也跳过**。要么有 AI 的结论，要么有 paru 的复核，不会两头都空。

---

## 配置 AI

```bash
pac ai init                    # 生成 ~/.config/pac/ai.conf（自动设成 600 权限）
$EDITOR ~/.config/pac/ai.conf  # 填 url / model / key 三行
pac ai show                    # 查看（key 会打码）
pac ai models                  # 可选：从端点的 /models 拉列表，用 fzf 挑一个
```

配置文件长这样，前三行是必填：

| 字段 | 必填 | 说明 |
|---|---|---|
| `url` | 是 | 接口地址。写 `https://api.deepseek.com`、`.../v1`、`.../v1/chat/completions` 都行，脚本自己拼 |
| `model` | 是 | 模型名，例如 `deepseek-chat` |
| `key` | 是 | API key。文件权限保持 600（`pac ai init` 会自动设；不是 600 会提醒你） |
| `protocol` | 否 | `openai`（默认）或 `anthropic` |
| `timeout` | 否 | 单次请求最长等待秒数，默认 600 |
| `max_tokens` | 否 | 回复长度上限，默认 4096 |
| `temperature` | 否 | 审查场景建议保持 0 |

支持 OpenAI 兼容的端点（DeepSeek、OpenRouter、智谱、Ollama、one-api 等）和 Anthropic 接口。

---

## 常见问题

**AI 审查报错了？** 脚本会直接说是什么问题：`401` 多半是 key 不对，`402` 是额度不足，`429` 是被限流，`404` 是地址写错了。先 `pac ai show` 看一眼配置。**报错不会让安装卡住**，只是退回 paru 自带复核。

**为什么装 AUR 包时 paru 自己又问了一遍 PKGBUILD？** 说明这次没跑成 AI 审查——脚本特意保留了 paru 的复核，这是设计如此，不是故障。

**想看看 AI 到底说了什么？** 报告在 `~/.cache/pac/review/<包名>.report`，模型的原始输出是同一个目录下的 `<包名>.json`。

**缓存占多大？** 一般十几 MB（主要是包索引），`pac --clear-cache` 可以清；`du -sh ~/.cache/pac` 看体积。

---

## 目录与缓存（技术细节）

```
~/scripts/package/
  pac  pacr  pacd       三个命令（~/.local/bin 里有同名链接）
  lib/pac-ai.sh         AI 后端共享库：配置解析、HTTP 请求、模型列表
  tests/                六套验收脚本，run-all.sh 一把跑完
  README.md             本文件
  UPGRADE.md            升级方案、每期改动、决策记录与回退办法
```

```
~/.config/pac/ai.conf   AI 后端配置（url / model / key，权限 600）
~/.cache/pac/           缓存总目录
  package-index.tsv     包索引（最大的一块）
  aur-packages.txt      AUR 包名列表（24 小时自动失效）
  previews/             包详情预览
  review/               审查产物：<包名>.report（人看的报告）、.json（模型原始输出）、
                        .json.scored（定级结果）、.dossier.json（证据包）、.log，以及构建目录
  pacr/  pacd/          pacr 与 pacd 各自的软件源列表缓存
```

---

## 验收与升级记录

改完东西想确认没坏：`./tests/run-all.sh` 一把跑完六套（当前 134 条断言）。

想了解这套东西是怎么一步步改成现在这样的（每一期做了什么、踩了什么坑、为什么这么定），看 [UPGRADE.md](./UPGRADE.md)。

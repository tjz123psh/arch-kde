# media —— 媒体工具

| 脚本 | 作用 |
|---|---|
| `b23` | 从剪贴板（或命令行参数）取 B 站 / b23.tv 链接，交给 mpv 播放；支持多 P / 合集连播、最高 1080P、浏览器 cookie 鉴权、链接参数清洗 |

## 依赖

- `yt-dlp`：解析 B 站链接与格式（安装器官方包清单里有）
- `mpv`：播放器，使用 `~/.config/mpv/mpv.conf` 里的 `[b23]` profile（小窗、置顶、不缓存）
- `wl-paste`（`wl-clipboard`）：只有"不带参数、从剪贴板取链接"时才需要
- `libnotify`（`notify-send`）：可选，没装就退回终端输出

## 用法

```bash
b23                      # 从剪贴板取链接
b23 'https://www.bilibili.com/video/BV...'
b23 'https://b23.tv/...'
b23 -h                   # 帮助
```

环境变量：`B23_COOKIES_FROM_BROWSER`（默认 chrome）、`B23_PROFILE`（默认 b23）、`B23_PLAYLIST_LIMIT`（默认 110）、`B23_LOG`、`B23_MPV_ARGS`、`B23_IMPERSONATE`（需要 curl_cffi，默认关闭）。细节见脚本头部注释。

## 来源

脚本来自 `github.com/tjz123psh/my-script` 的 `media/b23`（2026-10-25 取回，未改动）。
上游还带回归测试（`media/tests/`），本仓库不放测试，需要时去上游取。

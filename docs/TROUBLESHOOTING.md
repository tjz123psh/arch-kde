# 排障手册

## 安装前 / 安装失败

```bash
bash install.sh --check      # 只预检
bash install.sh --dry-run    # 只打印
```

- 必须普通用户运行，不能 root。
- 安装器要求 TTY；图形会话里运行会提示，但不是硬失败。
- 日志：`~/.local/state/kos-installer/log/install-*.log`
- doctor 报告：`~/.local/state/kos-installer/doctor-*.txt`
- 所有被改过的配置：`~/.local/state/kos-installer/backup/<时间>/`
  - `manifest.txt` 记录原路径、sha256、备份路径

## 镜像 / 网络

安装器默认重写 `/etc/pacman.d/mirrorlist` 和 `/etc/pacman.d/archlinuxcn-mirrorlist`，
清华第一；网络失败会自动注释当前第一条 `Server =` 换下一个，最多 3 次。

恢复原镜像：

```bash
ls ~/.local/state/kos-installer/backup/
sudo cp ~/.local/state/kos-installer/backup/<时间>/etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist
```

如果 `reflector.timer` 在跑，它会重新覆盖 mirrorlist；要固定就停掉它：

```bash
sudo systemctl disable --now reflector.timer
```

## 音量 / 亮度 OSD 不出现

先确认服务：

```bash
systemctl --user status kos-osd-shortcuts
journalctl --user -u kos-osd-shortcuts -n 50 --no-pager
```

手动测脚本 + IPC：

```bash
~/bin/kos-osd volume-up
~/bin/kos-osd brightness-up
qs ipc -c kos call osd volume 50 false
qs ipc -c kos call osd brightness 40
```

如果脚本能改音量/亮度但 OSD 不显示，重启 KOS shell：

```bash
systemctl --user restart kos-shell
```

如果 KOS shell 里没有 `osd` IPC target，说明 OSD 模块没装进：

```bash
ls ~/.config/quickshell/kos/desktop/modules/osd
grep -nE 'modules.osd|Osd \{\}' ~/.config/quickshell/kos/desktop/DesktopEnvironment.qml
```

重新跑安装器对应阶段（或重跑一次 `bash install.sh --yes`，已有配置会备份）。
不要整脚本 sudo。

## 音量/亮度键还弹 KDE 原生 OSD，或两个 OSD 都弹

KDE 的 kmix / PowerDevil 会在某些会话重启后重新注册默认动作。检查：

```bash
grep -nA4 '^\[kmix\]\|^\[org_kde_powerdevil\]' ~/.config/kglobalshortcutsrc
```

`kos-osd-shortcuts` 启动时会移除重复动作。重启它：

```bash
systemctl --user restart kos-osd-shortcuts
journalctl --user -u kos-osd-shortcuts -n 50 --no-pager
```

仍然反复出现时，退出并重新登录一次，让 KWin 重新加载 KGlobalAccel；这是 Plasma 6
快捷键配置的已知行为，不是安装器在运行时改坏的。

## 截图快捷键多余 / 只剩 Print 和 Ctrl+Print 的目标

最终只应该有两个：

- `Print` → Vellum 区域截图
- `Ctrl+Print` → Vellum 长截图

检查：

```bash
grep -nE 'Print|vellum' ~/.config/kglobalshortcutsrc
vellum shortcuts status
```

期望没有 `Meta+Print` / `Meta+Shift+Print` / `Meta+Ctrl+Print`；
Vellum portal 的 `bindings` 为空、`enabled=false`。

如果 Vellum 又恢复了 Meta 组合：

```bash
vellum shortcuts disable
cat ~/.config/vellum/shortcuts.json    # 应为 {"enabled": false}
systemctl --user restart kos-osd-shortcuts
```

安装器 `57-shortcuts.sh` 的 `install_vellum_shortcuts` 会做同样的清理；
`kos-osd-shortcuts` 启动时还会 unRegister 掉 portal 旧动作。

## 锁屏不是 ds2 / 没有天气歌词

KOS 锁屏文件：

```bash
ls ~/.local/share/plasma/shells/org.kos.desktop/contents/lockscreen
grep -nE 'customWallpaper|ds2.png|cornerRadius' ~/.local/share/plasma/shells/org.kos.desktop/contents/lockscreen/LockScreen.qml
```

重装锁屏配置：

```bash
# 重新跑安装器（会先备份 QML）
bash install.sh --yes
systemctl --user restart kos-shell
```

锁屏是 kscreenlocker greeter 加载的，改完要重新锁屏才看到；不需要注销。

## KOS shell 起不来 / 黑屏

```bash
systemctl --user status kos-shell
journalctl --user -u kos-shell -n 100 --no-pager
```

先看 QML 报错，不要急着重装。常见原因：

- 上游 KOS 更新后 `DesktopEnvironment.qml` 结构变了，安装器的 Python patch 没命中；
- OSD / 锁屏 QML 写入失败；
- 旧备份路径。

安装器改过的文件都有备份，按 `manifest.txt` 恢复单个文件即可。

## SDDM 登录页

```bash
systemctl status sddm
ls ~/.local/share/sddm/themes
```

登录主题在 `modules/80-sddm.sh`；不想用主题就重跑安装器加 `--no-sddm-theme`。
SDDM 的登录背景和 KOS 锁屏是两套东西：前者在登录主题里，后者是 kscreenlocker。

## 完全回退

- 单个配置：按 `~/.local/state/kos-installer/backup/<时间>/manifest.txt` 复制回去。
- 镜像：见上面。
- KOS 桌面：用上游 `kosctl uninstall`（本仓库不接管桌面本体卸载）。
- 旧桌面遗留包：默认不删；明确要删才用 `bash install.sh --clean-old-desktop`，
  安装器会先列清单再确认。

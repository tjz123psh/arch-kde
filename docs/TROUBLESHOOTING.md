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

## 音量 / 亮度快捷键不工作

当前使用 **KDE 原生** 音量/亮度处理，不再由 KOS OSD 接管。

先检查动作是否存在：

```bash
qdbus6 org.kde.kglobalaccel 2>&1 | grep -E '/component/(kmix|org_kde_powerdevil)'
qdbus6 --literal org.kde.kglobalaccel /component/kmix org.kde.kglobalaccel.Component.allShortcutInfos 2>&1 | grep -E 'increase_volume|decrease_volume|mute'
qdbus6 --literal org.kde.kglobalaccel /component/org_kde_powerdevil org.kde.kglobalaccel.Component.allShortcutInfos 2>&1 | grep -E '(Increase|Decrease) Screen Brightness'
```

如果缺音量动作，重启 kded（audioshortcutsservice 在 kded 里）：

```bash
systemctl --user restart plasma-kded6
```

如果缺亮度动作，重启 PowerDevil：

```bash
systemctl --user restart plasma-powerdevil
```

配置文件中的期望值（`~/.config/kglobalshortcutsrc`）：

```ini
[kmix]
increase_volume=Volume Up
decrease_volume=Volume Down
mute=Volume Mute

[org_kde_powerdevil]
Increase Screen Brightness=Monitor Brightness Up
Decrease Screen Brightness=Monitor Brightness Down
```

如果 KGlobalAccel 状态很乱，最可靠的是注销并重新登录一次；不要为了这个去重装整台系统。

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
```

安装器 `57-shortcuts.sh` 的 `install_vellum_shortcuts` 会做同样的清理。

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

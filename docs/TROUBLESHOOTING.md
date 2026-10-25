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
- 这两样只保留最近 20 份（每次运行自动清理；要改数量就 `KOS_STATE_KEEP=50 bash install.sh ...`）
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

## 终端窗口不能用鼠标拖边缩放（边缘光标不变成双向箭头）

KDE 里只有「带窗口装饰」的窗口才有可抓的缩放边框。KOS 的窗口装饰（kos_decoration）
是「细标题栏 + 看不见的缩放边框」：有它，鼠标贴边就能把窗口拉大拉小；把装饰整个关掉
（旧版安装器用 KWin 规则 kitty_no_decorations + decorationpolicy=none 这么干过），
窗口就没有任何边缘可抓，鼠标永远显示文本光标。

先看规则还在不在：

```bash
grep -n 'kitty_no_decorations' ~/.config/kwinrulesrc
```

在的话删掉（重跑安装器会自动清理：remove_kitty_no_decorations），然后**关掉旧终端重开**——
窗口规则只在新建窗口时生效，已经开着的窗口不会自己变。

```bash
bash install.sh --yes
```

如果新窗口带一个细标题栏、你能接受，就到此为止。连标题栏都不想要，那就只能放弃鼠标拖边：
KWin 对 decorationpolicy=none 的窗口不提供任何缩放把手，最多用 Meta + 右键拖动缩放。

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

## 热点能连上但上不了网（Docker 环境）

Docker 安装后会把 iptables 的 `FORWARD` 策略改成 `DROP`，只放行它自己的网桥。
NetworkManager 的 shared 模式（热点）自己加的 MASQUERADE 和 forward 规则会被这条 DROP 抢先拦掉，
表现就是：手机能连上热点、能拿到 `10.42.0.x` 的地址，但网页打不开。

安装器会写入 `/etc/NetworkManager/dispatcher.d/90-kos-hotspot`，在 `KOS-Hotspot` 上线/下线时
自动加/删两条放行规则。手动补也能立刻生效：

```bash
sudo iptables -I FORWARD 1 -i wlp3s0 -j ACCEPT
sudo iptables -I FORWARD 1 -o wlp3s0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

检查（这两条要出现在 `DROP` 策略前面）：

```bash
sudo iptables -S FORWARD | head -4
```

另外热点还依赖 `dnsmasq`（shared 模式的 DHCP/DNS）；缺了它会在开启时报
`IP 配置无法保留（无可用地址、超时等）`。
## Electron 应用弹「KDE 密码库 / OS keyring 不可用」

Chrome 启动时要通过 KDE 密钥服务（`ksecretd`，属于 `kwallet` 包）取 cookie 加密密钥；
系统里没建过钱包时，它会请求新建一个叫 `kwallet` 的钱包，**点取消才能继续使用浏览器**。

安装器会给 Chrome 写一个用户级启动项覆盖，把 `--password-store=basic` 加进 Exec，
Chrome 改用自带的存储，不再碰密钥服务：

```bash
grep '^Exec' ~/.local/share/applications/google-chrome.desktop   # 应该带 --password-store=basic
```

想恢复默认：删掉 `~/.local/share/applications/google-chrome.desktop` 再 `kbuildsycoca6 --noincremental`。

换成 basic 存储后，Chrome 会重新生成 cookie 加密密钥，个别站点可能要重新登录一次。

### VS Code 弹「你正在 KDE 环境中运行，但 OS keyring 不可用于加密」

同一个根因，但不是同一个应用：`kwallet` 进程在跑，而**钱包从来没建过**
（`~/.local/share/kwalletd/` 是空的，`kwallet-query -l kdewallet` 会报 not found），
Electron 就认定“KDE 环境下该有 keyring”，去取的时候拿不到，于是弹这句。

安装器给 VS Code 写两处（都在用户目录，不动 kwallet 本身）：

```bash
cat ~/.config/code-flags.conf              # /usr/bin/code 包装脚本启动时读
cat ~/.config/Code/User/argv.json          # VS Code 自己读的运行时参数
```

两处都应该出现 `password-store` = `basic`；前者管菜单/终端启动，后者管直接跑
`/usr/share/code/code` 的情况。

想改成用钱包加密：删掉那一行里的 `--password-store=basic`，装 `kwalletmanager`、
建一个 kdewallet 钱包，然后重启 VS Code。
## 桌面壁纸还是 KDE 默认的那张

壁纸有两个来源，先分清是哪一个：

- **KOS 自己的壁纸**：`~/.local/state/quickshell/kos/wallpaper.ini` 里的 `image=`（shell 盖住桌面时看到的就是它）
- **Plasma 桌面壁纸**：`~/.config/plasma-org.kde.plasma.desktop-appletsrc` 里的 `[Containments][1][Wallpaper][org.kde.image][General] Image=`
  （KOS shell 启动前那几秒、以及没有 KOS 的时候看到的就是它）

全新机器装完第一次登录前，appletsrc 还不存在，安装器不会去伪造它（Plasma 会当成无主配置丢掉），
而是装一个首登自启动：`~/.config/autostart/kos-wallpaper-first-login.desktop` →
`~/.local/bin/kos-wallpaper-first-login`，进桌面后调 `plasma-apply-wallpaperimage` 设置一次。
成功与否记在 `~/.local/state/kos-installer/log/wallpaper-first-login.log`。

排查：

```bash
ls ~/.local/share/kos/gallery                     # 图集在不在
cat ~/.local/state/kos-installer/log/wallpaper-first-login.log
grep -A2 'org.kde.image' ~/.config/plasma-org.kde.plasma.desktop-appletsrc | head
```

手动设一次：`plasma-apply-wallpaperimage ~/.local/share/kos/gallery/落霞.png`。
想换默认图：`bash install.sh --yes --wallpaper 落霞.png`。

## 登录页还是 SDDM 默认主题（silent 没生效）

按可能性从高到低查：

1. **主题包没装上**：`pacman -Q sddm-silent-theme`；主题目录 `/usr/share/sddm/themes/silent/Main.qml`
   是否存在。AUR 构建失败时安装器只 warn，不会中断，所以登录页会静默退回默认主题。
2. **有更靠后的配置文件覆盖**：`grep -rn 'Current=' /etc/sddm.conf /etc/sddm.conf.d/`。
   SDDM 按文件名排序读 `conf.d/*.conf`，**后读的赢**；KDE 的「登录屏幕」设置会写
   `kde_settings.conf`，它排在 `90-silent.conf` 之后，会把 Current 盖回 breeze ——
   这是最常见的坑。安装器现在写 `zz-kos-silent.conf`（排序最后）并顺手删掉旧的 90 文件。
3. **`/etc/sddm.conf` 设了 Current**：它的优先级高于 conf.d，安装器会备份后改成 silent。

安装器收尾会自检并打印「SDDM 自检通过：生效主题 = silent」；没通过会直接说是哪一条。
改完配置要重启 SDDM 才生效（会中断当前图形会话）：`systemctl restart sddm`，或者直接重启。
看日志：`journalctl -u sddm -b --no-pager | tail -50`。

## 完全回退

一条命令退回安装前（装好后在 `~/bin`；还没装完就用仓库里的 `bash rollback.sh`）：

~~~bash
kos-undo            # 卸掉这次新装的包 + 还原文件 + 清残留目录；先列清单再问你
kos-undo --dry-run  # 只打印计划
~~~

包清单来自安装开始时记的 `~/.local/state/kos-installer/baseline/<时间>-pacman-Qq.txt`；
旧版本安装器装的没有这份基线，会退回解析 `/var/log/pacman.log`。都没有就只还原文件。

另一条路是整机快照（不需要它也能用 `kos-undo`）：

~~~bash
kos-undo list         # 安装记录 + Snapper 快照
kos-undo snapshot 12  # 回档到 Snapper 12（要 root，回档后重启）
~~~

- 清单在 `~/.local/state/kos-installer/backup/<时间>/manifest.txt`：`<原路径> <sha256> <备份路径>`
  的行会被拷回去，`created <原路径>` 的行是安装器新建的文件、会被删掉。
- 安装器在装桌面前会落一个 Snapper 快照 `kos-installer: before desktop`，
  比文件级回滚更彻底（连包一起退）。
- 只想重来一遍：直接 `bash install.sh --yes`，不用回滚。
- 镜像：见上面。
- KOS 桌面：用上游 `kosctl uninstall`（本仓库不接管桌面本体卸载）。
- 旧桌面遗留包：默认不删；明确要删才用 `bash install.sh --clean-old-desktop`，
  安装器会先列清单再确认。

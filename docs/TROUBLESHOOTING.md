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

## 锁屏是黑屏（没有壁纸）/ 不是 ds2 / 没有天气歌词

KOS 锁屏是 kscreenlocker greeter 加载的一层 QML，**不是** KOS shell：
`~/.local/share/plasma/shells/org.kos.desktop/contents/lockscreen/`。每次锁屏都会新起一个
greeter 进程，所以改完下一次锁屏就生效，不用注销，也不用重启 `kos-shell`。

**壁纸从哪来**：greeter 读 `~/.config/kscreenlockerrc` 的
`[Greeter][Wallpaper][org.kde.image][General] Image`。安装器把它指向
`~/.local/share/kos/lockscreen.png`（ds2 的副本，故意放在 KOS 锁屏包**外面**——
`kosctl install lockscreen` 会把整个包 `rm -rf` + `cp -a` 重建，包里的东西都会丢）。
没设这个键时 KOS 的 QML 拿不到 still image，只剩自带的兜底底色，就是黑屏。

~~~bash
cat ~/.config/kscreenlockerrc
kreadconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper \
  --group org.kde.image --group General --key Image
ls -l ~/.local/share/kos/lockscreen.png
# 不用真锁屏也能预览（上游自带的测试模式）：
/usr/lib/kscreenlocker_greet --testing
~~~

想换锁屏壁纸：把 `Image` 改成任一张 png 的绝对路径即可（重跑安装器会改回 ds2）。
`doctor` 的 `== 锁屏 ==` 报 `[MISS]` = 这个键或文件不在了，重跑安装器。

密码框圆角、隐藏日历/表盘是包内 QML 补丁，KOS 重建锁屏包后会回到上游原版（`doctor` 报
`[WARN]`），只影响观感；重跑安装器会把它们打回去。补丁锚点对不上时安装器会 `warn` 并
**整份不写**（不写半成品，避免锁屏 QML 直接报错），这时要按新 QML 改 `modules/85-config.sh`。

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
## GRUB 菜单里上下键没反应

典型症状：开机停在 GRUB 菜单，按 ↑↓ 不动、只能等超时自己启动。

原因几乎都是 `GRUB_PRELOAD_MODULES` 里写了 `usb_keyboard`：笔记本内置键盘走 AT/PS2
（`/proc/bus/input/devices` 里叫 `AT Translated Set 2 keyboard`），不是 USB 设备，
UEFI 下再加载 USB 键盘驱动会把输入抢掉。

```bash
grep GRUB_PRELOAD_MODULES /etc/default/grub
# 有问题的话改成（保留分区模块）：GRUB_PRELOAD_MODULES="part_gpt part_msdos at_keyboard"
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

安装器现在不再写 `usb_keyboard`，遇到旧值会自动换成 `at_keyboard`；
`bash install.sh --yes` 重跑一次即可修好。

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

## 窗口默认尺寸（1304x770）

安装器写一条 KWin 窗口规则（`~/.config/kwinrulesrc` 的 `kos_default_window_size`）：普通窗口
第一次出现时套一次 `--window-size` 的尺寸（默认 1304x770）。策略是 **Apply（3）**，只作用于
初次映射，之后拖拽、缩放、最大化、贴边都照常；对话框（类型不是 Normal）、KOS/Plasma 的
桌面与面板层（标题为空）、以及 Win+/ 的快捷键查看器（`kitty --class kos-shortcuts`）不受影响。

~~~bash
kreadconfig6 --file kwinrulesrc --group kos_default_window_size --key size   # 1304,770
# 临时改尺寸（重跑安装器会改回 WINDOW_SIZE 的默认值）：
kwriteconfig6 --file kwinrulesrc --group kos_default_window_size --key size "1400,800"
kwriteconfig6 --file kwinrulesrc --group kos_default_window_size --key Description "Default window size: 1400x800" --notify
~~~

想长期改：用 `bash install.sh --yes --window-size 1400x800`（重装也保留）。

注意：
- 只在窗口**第一次出现**时套一次；软件自己恢复上次尺寸（浏览器、编辑器）时以它为准。
- 刚开始标题为空的窗口不会套尺寸（规则用“标题非空”排除桌面/面板层，不列 app 名字）。
- 想彻底关掉：系统设置 → 窗口管理 → 窗口规则，删掉那条 `Default window size: …`。

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

## 触摸板：滚动方向反了 / Fn+F10 只能开不能关

**滚动方向**：KDE/libinput 默认是“传统”方向（双指上推 = 看上面、内容往下走），Windows 触摸板是
“自然滚动”（内容跟着手指走）。安装器会给检测到的每块触摸板写 `NaturalScroll=true`：

~~~bash
grep -A3 'Touchpad]' ~/.config/kcminputrc    # 组名是 [Libinput][vendor][product][设备名]
~~~

想改回传统方向：系统设置 → 输入设备 → 触摸板 → 滚动，取消“反转滚动方向”。

**Fn+F10 只能开不能关**：这颗键盘按一次会被 KDE 的 KGlobalAccel 触发两次（实测两次
`org.kde.touchpad.toggle` 间隔 1–5ms），两次切换互相抵消，所以看起来“怎么按都是开/都是关”。
安装器的做法是：用用户级组件 `~/.local/share/kglobalaccel/org.kde.touchpadshortcuts.desktop`
覆盖系统那份，把“切换”动作的 Exec 换成 `~/.local/bin/kos-touchpad-toggle`（400ms 防抖，
一次按键只切一次），并且只留“切换”一个动作，三个触摸板键都绑在它上面。

~~~bash
# 组件只剩一个动作，Exec 指向防抖包装脚本
cat ~/.local/share/kglobalaccel/org.kde.touchpadshortcuts.desktop

# KGlobalAccel 运行时看到的样子：只有 ToggleTouchpad，键位数组非空
qdbus6 --literal org.kde.kglobalaccel /component/org_kde_touchpadshortcuts_desktop \
  org.kde.kglobalaccel.Component.allShortcutInfos

# 防抖状态：每按一次会刷新时间戳（纳秒）
ls -l ~/.local/state/kos-touchpad/last-toggle
~~~

`~/.config/kglobalshortcutsrc` 里**没有** `[services][org.kde.touchpadshortcuts.desktop]` 是正常的：
键位来自组件里的 `X-KDE-Shortcuts`，KGlobalAccel 启动时会把和默认值相同的组整条剪掉。

**改完必须注销重登**（KGlobalAccel 在会话启动时读组件与键位）。重登后一次按键就是一次开关。
换机器/换键盘后按键不同，到 系统设置 → 快捷键 → 触摸板 手动绑一次即可。

## 装坏了怎么退

安装器**没有**自动回滚命令（上游桌面本体也不归这里管）。现成的三条路：

~~~bash
bash install.sh --yes      # 幂等：重跑一遍就能修好大部分问题
sudo snapper -c root list  # 看快照序号
sudo snapper -c root rollback <序号>   # 整机回档（或 btrfs-assistant 图形操作）
~~~

- 被覆盖的文件都在 `~/.local/state/kos-installer/backup/<时间>/`，`manifest.txt` 每行是
  `<原路径> <sha256> <备份路径>`，要恢复就手动 `sudo cp -a` 回去；`created <原路径>` 表示
  这个文件是安装器新建的（想删就删）。
- 安装器在装桌面前会落一个 Snapper 快照 `kos-installer: before desktop`，
  比文件级恢复更彻底（连包一起退）。
- 只想重来一遍：直接 `bash install.sh --yes`，不用回滚。
- 镜像：见上面。
- KOS 桌面：用上游 `kosctl uninstall`（本仓库不接管桌面本体卸载）。
- 旧桌面遗留包：默认不删；明确要删才用 `bash install.sh --clean-old-desktop`，
  安装器会先列清单再确认。

-- yazi 启动脚本（$YAZI_CONFIG_HOME/init.lua，yazi 启动时自动执行）。
-- 这里只做一件事：开「整屏外框」——full-border 插件给三个栏位和整个界面各加一圈边框，
-- 于是整个 UI 被一个方框包住、栏位分隔线接到方框上下沿（默认圆角）。
-- 插件本体随安装器部署在 plugins/full-border.yazi/：上游 yazi-rs/plugins 的 MIT 作品，
-- main.lua 文件头标注 @since 26.8.15（本机 yazi 26.9.1 可用）。
-- 升级 yazi 后如果这里报错，去上游 https://github.com/yazi-rs/plugins 拿最新 main.lua 覆盖即可。
require("full-border"):setup()

-- 想要方角外框就把上面那行换成：
-- require("full-border"):setup { type = ui.Border.PLAIN }

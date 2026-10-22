# ══════════════════════════════════════════════════════════════
#  fish — 默认 shell
# ══════════════════════════════════════════════════════════════

# ── PATH：~/bin 优先
if not contains "$HOME/bin" $PATH
    set -gx PATH "$HOME/bin" $PATH
end

# 注：旧的 tty1「exec niri」自动启动已移除 —— 它会截胡 greetd→niri-session，
# 使 graphical-session.target 不激活、xdg-desktop-portal-gnome 起不来（录屏/共享失效）。

# ── starship 提示符（配色由 Noctalia 从壁纸生成）
if type -q starship
    starship init fish | source
end

# ── fzf：模糊查找（Ctrl+R 历史、Ctrl+T 文件、Alt+C 目录）
if type -q fzf
    fzf --fish | source
end

# ── eza：带图标的 ls
if type -q eza
    alias ls  'eza --icons --group-directories-first'
    alias ll  'eza -lh --icons --group-directories-first'
    alias la  'eza -lah --icons --group-directories-first'
    alias lt  'eza --tree --level=2 --icons'
else
    alias ll  'ls -lh'
    alias la  'ls -lah'
end

# ── bat：带高亮的 cat（cat 别名由 maintenance terminal-tools 接管）
if type -q bat
    set -gx BAT_THEME ansi
    alias catn 'bat --style=numbers'
end

# ── 其他常用
alias ..  'cd ..'
alias ... 'cd ../..'
alias grep 'grep --color=auto'
alias df  'df -h'
alias free 'free -h'
alias top  'btop'
alias ff   'fastfetch'
alias vi   'nvim'
alias vim  'nvim'
alias tree 'eza --tree --icons'

if status is-interactive
    set -g fish_greeting ""
end

# ── fastfetch 欢迎画面（每个终端会话一次）
if status is-interactive; and not set -q FASTFETCH_DONE
    set -gx FASTFETCH_DONE 1
    fastfetch
end

# 用户自定义脚本路径
fish_add_path -g ~/scripts/maintenance

# >>> maintenance terminal-tools >>>
# 由 ~/scripts/maintenance/terminal-tools 管理；可用 terminal-tools --disable 撤销。
# 仅交互式 Fish 使用：脚本和非交互命令不会受到 cat 别名影响。
if status is-interactive
    if type -q zoxide
        zoxide init fish | source
    end

    # bat 提供语法高亮；--paging=never 避免在短输出和脚本复制时出现额外分页器。
    if type -q bat
        alias cat 'bat --paging=never --style=plain'
    end
end
# <<< maintenance terminal-tools <<<

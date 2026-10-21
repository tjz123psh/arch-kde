if status is-interactive
    set -g fish_greeting ""
    set -gx EDITOR nvim
    set -gx VISUAL nvim
    set -gx PATH $HOME/.local/bin $PATH

    if type -q starship
        starship init fish | source
    end
    if type -q zoxide
        zoxide init fish | source
    end
    if type -q fzf
        fzf --fish | source
    end

    if type -q eza
        alias ls 'eza --icons --group-directories-first'
        alias ll 'eza -lh --icons --group-directories-first'
        alias la 'eza -lah --icons --group-directories-first'
        alias lt 'eza --tree --level=2 --icons'
    end
    if type -q bat
        alias cat 'bat --paging=never'
    end
end

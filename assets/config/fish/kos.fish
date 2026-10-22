if status is-interactive
    set -g fish_greeting ""
    set -gx EDITOR nvim
    set -gx VISUAL nvim
    set -gx PATH $HOME/bin $HOME/.local/bin $PATH
end

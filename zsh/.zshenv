export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export ZDOTDIR="$XDG_CONFIG_HOME/zsh"
export GUI=1

export EDITOR=code
export BROWSER=google-chrome-stable
export TERMINAL=urxvtc

path+=("$HOME/.local/bin")
path+=("$HOME/.local/bin/i3")
export PATH

HISTFILE="$XDG_CACHE_HOME/zsh_history"

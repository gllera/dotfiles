# If not running interactively, don't do anything
[[ $- != *i* ]] && return

[[ -z "$DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]] && exec startx

[[ -f ~/.config/profile ]] && source ~/.config/profile

ADOTDIR=$XDG_CACHE_HOME/antigen
source $XDG_CONFIG_HOME/zsh/antigen.zsh

antigen use oh-my-zsh
antigen bundle git
antigen bundle gitfast
antigen bundle git-extras

antigen apply

PROMPT='%{$fg_bold[blue]%}%n@%m%{$reset_color%} %{$fg[green]%}%(!.%1~.%~) $(git_prompt_info)%{$reset_color%}$ '
ZSH_THEME_GIT_PROMPT_PREFIX="%{$fg[yellow]%}("
ZSH_THEME_GIT_PROMPT_SUFFIX=") "

alias ls='ls --color=auto'
alias y='yay --nodiffmenu'

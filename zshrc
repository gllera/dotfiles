alias .=source

. "$ADOTDIR/.antigen.zsh"
. "$HOME/.local/fzf/shell/completion.zsh"
. "$HOME/.local/fzf/shell/key-bindings.zsh"

antigen use oh-my-zsh

antigen bundle git
antigen bundle gitfast
antigen bundle git-extras
antigen bundle zsh-users/zsh-autosuggestions

antigen apply

######### PROMPT ######### 

PROMPT='%(!.%{$fg_bold[red]%}.%{$fg_bold[green]%}%n@)%m %{$fg_bold[blue]%}%(!.%1~.%~) $(git_prompt_info)%{$reset_color%}'
PROMPT='%n@%m %{$fg[green]%}%(!.%1~.%~) $(git_prompt_info)%{$reset_color%}$ '

ZSH_THEME_GIT_PROMPT_PREFIX="%{$fg[yellow]%}("
ZSH_THEME_GIT_PROMPT_SUFFIX=") "

alias ls='ls --group-directories-first --color=tty'

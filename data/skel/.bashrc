# ~/.bashrc: interactive bash shells.
[[ $- == *i* ]] || return

HISTCONTROL=ignoreboth
HISTSIZE=10000
HISTFILESIZE=20000
shopt -s histappend checkwinsize

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='\[\e[1m\]\w\[\e[0m\] \$ '

[[ -r /usr/share/bash-completion/bash_completion ]] && . /usr/share/bash-completion/bash_completion
if command -v mise >/dev/null; then eval "$(mise activate bash)"; fi

# ~/.bash_profile: login shells read this, not ~/.profile, so it reads
# ~/.profile first: what is set there holds in a console or ssh login as it
# does in the desktop session. Then ~/.bashrc.
[[ -f ~/.profile ]] && . ~/.profile
[[ -f ~/.bashrc ]] && . ~/.bashrc

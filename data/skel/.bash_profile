# ~/.bash_profile: login shells read this, not ~/.profile, so it reads
# ~/.profile first: what is set there holds in a console or ssh login as it
# does in the desktop session. Not while uwsm makes the desktop's
# environment, which has read ~/.profile already. Then ~/.bashrc.
[[ -z ${IN_UWSM_ENV_PRELOADER:-} && -f ~/.profile ]] && . ~/.profile
[[ -f ~/.bashrc ]] && . ~/.bashrc

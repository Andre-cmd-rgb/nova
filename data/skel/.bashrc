# ~/.bashrc: your interactive bash shells.
[[ $- == *i* ]] || return

# Nova's defaults: history, Tab, the prompt. Updates improve them without
# touching this file.
[[ -r ${NOVA_PATH:-/usr/share/nova}/default/bash/bashrc ]] && . "${NOVA_PATH:-/usr/share/nova}/default/bash/bashrc"

# Yours, after the defaults so that they win.

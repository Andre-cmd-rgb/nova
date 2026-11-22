# ~/.bashrc: your interactive bash shells.
[[ $- == *i* ]] || return

# Nova's defaults: history, Tab, the prompt. Updates improve them without
# touching this file.
if [[ -r ${NOVA_PATH:-/usr/share/nova}/default/bash/bashrc ]]; then
  . "${NOVA_PATH:-/usr/share/nova}/default/bash/bashrc"
else
  # Where they are not (a container that shares this home, a Nova from before
  # they came): the history keeps its length, which bash would cut to 500.
  HISTCONTROL=ignoreboth HISTSIZE=10000 HISTFILESIZE=20000
  shopt -s histappend
  if command -v mise >/dev/null; then eval "$(mise activate bash)"; fi
fi

# Yours, after the defaults so that they win.

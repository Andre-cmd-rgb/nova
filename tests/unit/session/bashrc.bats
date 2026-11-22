#!/usr/bin/env bats

# Nova's interactive bash (data/bash/bashrc), and the account's ~/.bashrc that
# reads it (data/skel/.bashrc), in a real interactive bash: on a pipe, each
# line typed in turn, or on a terminal of its own (script's) for what needs
# one, the arrow keys and Ctrl+C. A home, history file and git config of the
# test's own; mise's activation, which the file runs where mise is, does
# nothing here.

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home NOVA_PATH=$SCRATCH/nova
  mkdir -p "$HOME" "$SCRATCH/bin" "$NOVA_PATH/default"
  ln -s "$REPO_ROOT/data/bash" "$NOVA_PATH/default/bash"
  ln -s "$REPO_ROOT/data/skel" "$NOVA_PATH/skel"
  export NOVA_BASHRC=$NOVA_PATH/default/bash/bashrc
  printf '#!/bin/sh\nexit 0\n' >"$SCRATCH/bin/mise"
  chmod +x "$SCRATCH/bin/mise"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.org GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.org
  IENV=()
  ITERM=xterm
}

teardown() { teardown_scratch; }

SOURCE='. "$NOVA_BASHRC"'

# The environment a terminal's bash would have, and nothing of this one's.
shell_env() {
  env -i HOME="$HOME" PATH="$SCRATCH/bin:/usr/bin:/bin" TERM="$ITERM" LANG=C.UTF-8 \
    HISTFILE="$HOME/.bash_history" INPUTRC=/dev/null NOVA_PATH="$NOVA_PATH" NOVA_BASHRC="$NOVA_BASHRC" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.org \
    GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.org "${IENV[@]}" "$@"
}

# An interactive bash on a pipe, each argument a line typed into it, in the
# home folder. What the terminal showed (each prompt, with the line typed
# after it) goes to $SCRATCH/out.
ibash() { # line...
  (cd "$HOME" && printf '%s\n' "$@" | shell_env bash --norc --noprofile -i >"$SCRATCH/out" 2>&1)
}

# The prompt in front of the line typed as <text>, colours kept.
prompt_of() { # typed text
  local line
  while IFS= read -r line; do
    line=${line//$'\e[K'/}
    line=${line//$'\r'/}
    if [[ $line == *"\$ $1" ]]; then
      printf '%s\n' "${line%"$1"}"
      return 0
    fi
  done <"$SCRATCH/out"
  echo "no prompt in front of: $1" >&2
  cat -v "$SCRATCH/out" >&2
  return 1
}

plain() { sed $'s/\e\\[[0-9;]*m//g'; }

# A repository with a commit, on main.
repo() { # folder
  mkdir -p "$1"
  git -C "$1" init -q -b main
  echo a >"$1/a"
  git -C "$1" add a
  git -C "$1" commit -q -m one
}

# The same bash on a terminal of its own. Each argument is sent (printf %b)
# once the shell has shown one more prompt than before it; then exit.
pty_bash() { # keys...
  local out=$SCRATCH/out key n=0
  : >"$out"
  {
    for key in "$@" 'exit\r'; do
      n=$((n + 1))
      prompts_shown "$n" "$out" || break
      printf '%b' "$key"
    done
  } | (cd "$HOME" && shell_env script -qfc 'bash --norc --noprofile -i' /dev/null >"$out" 2>&1)
  # What the terminal showed, as lines, without its control sequences.
  sed -i $'s/\r//g; s/\e\\[[0-9;?]*[a-zA-Z]//g' "$out"
}

prompts_shown() { # count file
  local i
  for ((i = 0; i < 200; i++)); do
    (($(grep -o '\$ ' "$2" | wc -l) >= $1)) && return 0
    sleep 0.05
  done
  echo "the shell showed fewer than $1 prompts:" >&2
  cat -v "$2" >&2
  return 1
}

@test "the arrows find the commands that start with what is typed, in both forms terminals send; on an empty line, the last" {
  printf '%s\n' 'echo aaa' 'echo bbb' 'echo ccc' >"$HOME/.bash_history"
  IENV=(NO_COLOR=1)
  pty_bash "$SOURCE\r" 'echo a\e[A\r' 'echo b\eOA\r' '\e[A\r'
  [ "$(grep -cx 'aaa' "$SCRATCH/out")" -eq 1 ]
  [ "$(grep -cx 'bbb' "$SCRATCH/out")" -eq 2 ]
  fails grep -qx 'ccc' "$SCRATCH/out"
}

@test "reading it twice changes nothing" {
  state='{ declare -p PS1 PS0 PROMPT_COMMAND; alias; shopt; for m in emacs vi-insert vi-command; do bind -m $m -p; done; bind -v; }'
  ibash "$SOURCE" "$state >~/once" "$SOURCE" "$state >~/twice"
  [ -s "$HOME/once" ]
  diff "$HOME/once" "$HOME/twice"
}

@test "the keys: the arrows search by what is typed in emacs and vi; Ctrl+R, Ctrl+P and Ctrl+N as they were" {
  ibash "$SOURCE" 'for m in emacs vi-insert vi-command; do bind -m $m -q history-search-backward >~/$m-up; bind -m $m -q history-search-forward >~/$m-down; done' \
    '{ bind -q reverse-search-history; bind -q previous-history; bind -q next-history; } >~/keys'
  for m in emacs vi-insert vi-command; do
    for key in '"\e[A"' '"\eOA"'; do grep -qF "$key" "$HOME/$m-up" || { echo "$m: $key is not history-search-backward"; false; }; done
    for key in '"\e[B"' '"\eOB"'; do grep -qF "$key" "$HOME/$m-down" || { echo "$m: $key is not history-search-forward"; false; }; done
  done
  grep -qF 'reverse-search-history can be invoked via "\C-r"' "$HOME/keys"
  grep -qF 'previous-history can be invoked via "\C-p"' "$HOME/keys"
  grep -qF 'next-history can be invoked via "\C-n"' "$HOME/keys"
}

@test "what the user's own ~/.inputrc sets wins over Nova's keys and Tab" {
  printf '%s\n' 'set completion-ignore-case off' '"\e[A": previous-history' >"$HOME/.inputrc"
  IENV=(INPUTRC="$HOME/.inputrc")
  ibash "$SOURCE" '{ bind -v; bind -q previous-history; bind -q history-search-forward; } >~/settings'
  grep -qx 'set completion-ignore-case off' "$HOME/settings"
  grep -qx 'set show-all-if-ambiguous on' "$HOME/settings"
  grep -qF '"\e[A"' <(grep '^previous-history' "$HOME/settings")
  grep -qF '"\e[B"' <(grep '^history-search-forward' "$HOME/settings")
}

@test "Tab and folder names: the settings as bash reports them" {
  ibash "$SOURCE" '{ bind -v; shopt; } >~/settings'
  for line in 'set completion-ignore-case on' 'set show-all-if-ambiguous on' 'set visible-stats on' \
    'set colored-stats on' 'set mark-symlinked-directories on'; do
    grep -qx "$line" "$HOME/settings" || { echo "not: $line"; false; }
  done
  for option in cdspell dirspell histappend checkwinsize; do
    grep -qE "^$option[[:space:]]+on$" "$HOME/settings" || { echo "off: $option"; false; }
  done
}

@test "cd puts a small typo in a folder's name right" {
  mkdir -p "$HOME/Projects"
  ibash "$SOURCE" 'cd ~/Projcts' 'pwd'
  grep -qx "$HOME/Projects" "$SCRATCH/out"
}

@test "history: a command is in the file as it starts, for a terminal opened then; one open already keeps its own" {
  mkfifo "$SCRATCH/a" "$SCRATCH/b"
  (cd "$HOME" && shell_env bash --norc --noprofile -i <"$SCRATCH/a" >"$SCRATCH/a.out" 2>&1) &
  a=$!
  exec {fa}>"$SCRATCH/a"
  printf '%s\n' "$SOURCE" ': first-a' >&"$fa"
  in_history() { local i; for ((i = 0; i < 100; i++)); do grep -qx "$1" "$HOME/.bash_history" 2>/dev/null && return 0; sleep 0.05; done; return 1; }
  in_history ': first-a'

  (cd "$HOME" && shell_env bash --norc --noprofile -i <"$SCRATCH/b" >"$SCRATCH/b.out" 2>&1) &
  b=$!
  exec {fb}>"$SCRATCH/b"
  printf '%s\n' "$SOURCE" ': first-b' >&"$fb"
  in_history ': first-b'
  printf '%s\n' ': late-a' >&"$fa"
  in_history ': late-a'
  printf '%s\n' 'history >~/b-history' 'exit' >&"$fb"
  exec {fb}>&-
  wait "$b"
  printf '%s\n' 'exit' >&"$fa"
  exec {fa}>&-
  wait "$a"

  grep -q ': first-a$' "$HOME/b-history"
  fails grep -q ': late-a$' "$HOME/b-history"
  for line in ': first-a' ': first-b' ': late-a'; do
    [ "$(grep -cx "$line" "$HOME/.bash_history")" -eq 1 ]
  done
}

@test "only an interactive bash reads it: a script's, bash -c's and a login's without a terminal are untouched" {
  cp "$REPO_ROOT/data/skel/.bashrc" "$REPO_ROOT/data/skel/.bash_profile" "$HOME/"
  run shell_env bash --norc --noprofile -c '. ~/.bash_profile; . ~/.bashrc; . "$NOVA_BASHRC"; echo "${PS0-none} ${PROMPT_COMMAND-none} $(alias | wc -l) $(shopt -p cdspell)"'
  [ "$status" -eq 0 ]
  [ "$output" = 'none none 0 shopt -u cdspell' ]
}

@test "the account's ~/.bashrc, from Nova's skel, reads the defaults; without them it starts all the same" {
  cp "$REPO_ROOT/data/skel/.bashrc" "$HOME/.bashrc"
  mkdir -p "$HOME/folder"
  ibash '. ~/.bashrc' 'cd ~/fodler' 'pwd'
  grep -qx "$HOME/folder" "$SCRATCH/out"

  NOVA_PATH=$SCRATCH/none
  ibash '. ~/.bashrc' 'echo "${PS0-none}"' ': c'
  grep -qx 'none' "$SCRATCH/out"
  fails grep -q 'No such file' "$SCRATCH/out"
}

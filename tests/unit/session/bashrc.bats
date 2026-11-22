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

@test "outside a repository, after an ordinary command, the prompt is the folder alone" {
  mkdir -p "$HOME/folder"
  ibash "$SOURCE" 'cd ~/folder' ': one' 'echo hi' ': two'
  [ "$(prompt_of ': one' | plain)" = '~/folder $ ' ]
  [ "$(prompt_of ': two' | plain)" = '~/folder $ ' ]
}

@test "in a repository: the branch, and git's marks for a change, a staged change and a new file" {
  repo "$HOME/r"
  ibash "$SOURCE" 'cd ~/r' ': clean' 'echo b >>a' ': changed' 'git add a' ': staged' 'echo n >new' ': new' 'cd ~' ': out'
  [ "$(prompt_of ': clean' | plain)" = '~/r main $ ' ]
  [ "$(prompt_of ': changed' | plain)" = '~/r main * $ ' ]
  [ "$(prompt_of ': staged' | plain)" = '~/r main + $ ' ]
  [ "$(prompt_of ': new' | plain)" = '~/r main +% $ ' ]
  [ "$(prompt_of ': out' | plain)" = '~ $ ' ]
}

@test "with no branch checked out, the commit, shortened; in a folder below the top, the same" {
  repo "$HOME/r"
  mkdir "$HOME/r/sub"
  sha=$(git -C "$HOME/r" rev-parse --short HEAD)
  git -C "$HOME/r" checkout -q --detach
  ibash "$SOURCE" 'cd ~/r' ': detached' 'cd sub' ': below'
  [ "$(prompt_of ': detached' | plain)" = "~/r ($sha...) \$ " ]
  [ "$(prompt_of ': below' | plain)" = "~/r/sub ($sha...) \$ " ]
}

@test "what is under way, as git's prompt says it: a merge, with its conflict marked as a change" {
  repo "$HOME/r"
  git -C "$HOME/r" checkout -q -b other
  echo other >"$HOME/r/a"
  git -C "$HOME/r" commit -q -am other
  git -C "$HOME/r" checkout -q main
  echo main >"$HOME/r/a"
  git -C "$HOME/r" commit -q -am main
  fails git -C "$HOME/r" merge -q other >/dev/null 2>&1
  ibash "$SOURCE" 'cd ~/r' ': merging'
  [ "$(prompt_of ': merging' | plain)" = '~/r main|MERGING * $ ' ]
}

@test "the prompt writes nothing into the repository, its index included" {
  repo "$HOME/r"
  # A file whose time changed and content not: git diff alone would write
  # the index, to remember that it is unchanged.
  touch -d '10 seconds ago' "$HOME/r/a"
  before=$(stat -c '%Y %s' "$HOME/r/.git/index"; sha256sum <"$HOME/r/.git/index")
  ibash "$SOURCE" 'cd ~/r' ': one' ': two'
  [ "$(prompt_of ': two' | plain)" = '~/r main $ ' ]
  [ "$(stat -c '%Y %s' "$HOME/r/.git/index"; sha256sum <"$HOME/r/.git/index")" = "$before" ]
  [ ! -e "$HOME/r/.git/index.lock" ]
}

@test "after a command that failed, its status, once: an empty line or the next command shows none" {
  mkdir -p "$HOME/folder"
  ibash "$SOURCE" 'cd ~/folder' 'false' ': after-false' '(exit 3)' ': after-3' 'false' '' ': after-empty' 'nosuchcommand' ': after-127'
  [ "$(prompt_of ': after-false' | plain)" = '~/folder exit 1 $ ' ]
  [ "$(prompt_of ': after-3' | plain)" = '~/folder exit 3 $ ' ]
  [ "$(prompt_of ': after-empty' | plain)" = '~/folder $ ' ]
  [ "$(prompt_of ': after-127' | plain)" = '~/folder exit 127 $ ' ]
}

@test "after a command that took long, how long: from NOVA_PROMPT_LONG seconds, 5 unless set" {
  mkdir -p "$HOME/folder"
  ibash "$SOURCE" 'cd ~/folder' 'sleep 1.2' ': default'
  [ "$(prompt_of ': default' | plain)" = '~/folder $ ' ]

  IENV=(NOVA_PROMPT_LONG=1)
  # A command that moves its own start back stands for one that ran that long.
  ibash "$SOURCE" 'cd ~/folder' 'sleep 1.2' ': after-sleep' '' ': after-empty' ': after-quick' \
    'sleep 1.2; false' ': after-both' \
    '__nova_prompt_start=$((${EPOCHREALTIME//[!0-9]/} - 65000000))' ': after-minute' \
    '__nova_prompt_start=$((${EPOCHREALTIME//[!0-9]/} - 3725000000))' ': after-hour'
  [ "$(prompt_of ': after-sleep' | plain)" = '~/folder took 1s $ ' ]
  [ "$(prompt_of ': after-empty' | plain)" = '~/folder $ ' ]
  [ "$(prompt_of ': after-quick' | plain)" = '~/folder $ ' ]
  [ "$(prompt_of ': after-both' | plain)" = '~/folder took 1s exit 1 $ ' ]
  [ "$(prompt_of ': after-minute' | plain)" = '~/folder took 1m 5s $ ' ]
  [ "$(prompt_of ': after-hour' | plain)" = '~/folder took 1h 2m $ ' ]
}

@test "Ctrl+C on an empty line shows neither the last status nor a time" {
  mkdir -p "$HOME/folder"
  IENV=(NO_COLOR=1 NOVA_PROMPT_LONG=1)
  pty_bash "$SOURCE\r" 'cd ~/folder\r' 'sleep 1.2; false\r' '\003' ': after-ctrl-c\r'
  grep -qx '~/folder took 1s exit 1 \$ ^C' "$SCRATCH/out" || { cat -v "$SCRATCH/out"; false; }
  grep -qx '~/folder \$ : after-ctrl-c' "$SCRATCH/out" || { cat -v "$SCRATCH/out"; false; }
}

@test "a shell with errexit on lives through its prompts: in a repository, one with no commit, inside .git, after a test that said no" {
  repo "$HOME/r"
  git init -q -b main "$HOME/unborn"
  ibash "$SOURCE" 'set -e' 'cd ~/r' ': in-repo' 'cd ~/unborn' ': unborn' 'cd ~/r/.git' ': inside' 'cd ~' '[[ -e /nonexistent ]] && echo no' ': after-no' 'echo still-alive'
  grep -qx 'still-alive' "$SCRATCH/out" || { cat -v "$SCRATCH/out"; false; }
  [ "$(prompt_of ': in-repo' | plain)" = '~/r main $ ' ]
  [ "$(prompt_of ': unborn' | plain)" = '~/unborn main $ ' ]
  [ "$(prompt_of ': inside' | plain)" = '~/r/.git GIT_DIR! $ ' ]
  # The test's own "no" is not a command that failed in a shell with errexit:
  # the prompt shows it, and the shell goes on.
  [ "$(prompt_of ': after-no' | plain)" = '~ exit 1 $ ' ]
}

@test "a shell with errexit on lives through Ctrl+C on an empty line" {
  IENV=(NO_COLOR=1)
  pty_bash "$SOURCE\r" 'set -e\r' '\003' 'echo still-alive\r'
  grep -qx 'still-alive' "$SCRATCH/out" || { cat -v "$SCRATCH/out"; false; }
}

@test "inside .git, and inside a repository with no files of its own that GIT_DIR names: git's word for it and no git status" {
  repo "$HOME/r"
  git clone -q --bare "$HOME/r" "$HOME/bare.git"
  printf '#!/bin/sh\necho "$PWD: $*" >>"$HOME/git-calls"\nexec /usr/bin/git "$@"\n' >"$SCRATCH/bin/git"
  chmod +x "$SCRATCH/bin/git"
  ibash "$SOURCE" 'cd ~/r/.git' ': inside' 'cd ~/r' ': tree' 'cd ~/bare.git' 'export GIT_DIR=$PWD' ': bare'
  [ "$(prompt_of ': inside' | plain)" = '~/r/.git GIT_DIR! $ ' ]
  [ "$(prompt_of ': tree' | plain)" = '~/r main $ ' ]
  [ "$(prompt_of ': bare' | plain)" = '~/bare.git BARE:main $ ' ]
  # git status where there are files, and nowhere else.
  grep -q "^$HOME/r: .* status " "$HOME/git-calls"
  fails grep -Eq "^$HOME/(r/\.git|bare\.git): .* status " "$HOME/git-calls"
}

# A repository as an archive or a stick brings it: the user's files, and
# settings written by somebody else.
@test "a repository's own settings run nothing at the prompt: its file watcher is not started, and the marks stay" {
  repo "$HOME/r"
  echo b >>"$HOME/r/a"
  git -C "$HOME/r" config core.fsmonitor "sh -c 'echo watcher >>$HOME/ran'"
  ibash "$SOURCE" 'cd ~/r' ': one' 'git status --short >/dev/null' ': two'
  [ "$(prompt_of ': one' | plain)" = '~/r main * $ ' ]
  # Typed by hand, git status does start it: the prompt alone did not.
  [ "$(grep -c watcher "$HOME/ran")" -eq 1 ]
  fails grep -q watcher <(sed -n '1,/git status --short/p' "$SCRATCH/out")

  # With new files alone to find (bash.showDirtyState false), the same.
  rm -f "$HOME/ran"
  git -C "$HOME/r" config bash.showDirtyState false
  touch "$HOME/r/new"
  ibash "$SOURCE" 'cd ~/r' ': one'
  [ "$(prompt_of ': one' | plain)" = '~/r main % $ ' ]
  [ ! -e "$HOME/ran" ]
}

@test "a program the repository's settings name for its files is never run: no marks there, said once" {
  repo "$HOME/r"
  printf '* filter=x\n' >"$HOME/r/.git/info/attributes"
  git -C "$HOME/r" config filter.x.clean "sh -c 'echo filter >>$HOME/ran; cat'"
  # As after unpacking: the file's time is not the one git knew.
  touch -d '2020-01-01' "$HOME/r/a"
  ibash "$SOURCE" 'cd ~/r' ': one' ': two' ': three'
  [ ! -e "$HOME/ran" ]
  [ "$(prompt_of ': one' | plain)" = '~/r main $ ' ]
  [ "$(prompt_of ': three' | plain)" = '~/r main $ ' ]
  [ "$(grep -c "This repository's own settings name a program for git to run on its files (filter.x.clean)" "$SCRATCH/out")" -eq 1 ]

  # The same filter in the user's own settings is the user's word: it runs,
  # and the marks are there.
  git -C "$HOME/r" config --unset filter.x.clean
  export GIT_CONFIG_GLOBAL=$HOME/gitconfig
  IENV=(GIT_CONFIG_GLOBAL="$HOME/gitconfig")
  git config --global filter.x.clean "sh -c 'echo filter >>$HOME/ran; cat'"
  touch "$HOME/r/new"
  ibash "$SOURCE" 'cd ~/r' ': one'
  [ "$(prompt_of ': one' | plain)" = '~/r main % $ ' ]
  [ -s "$HOME/ran" ]
}

@test "a setting of several lines is one value: it cannot pass for the user's own word" {
  repo "$HOME/r"
  touch "$HOME/r/new"
  # A watcher of the repository's, then a filter whose value's second line
  # reads as the user's own "core.fsmonitor true" would, and marks off so
  # that only new files are looked for.
  git -C "$HOME/r" config core.fsmonitor "sh -c 'echo watcher >>$HOME/ran'"
  git -C "$HOME/r" config filter.x.clean $'cat\nglobal\tcore.fsmonitor true'
  git -C "$HOME/r" config bash.showDirtyState false
  ibash "$SOURCE" 'cd ~/r' ': one'
  [ "$(prompt_of ': one' | plain)" = '~/r main % $ ' ]
  [ ! -e "$HOME/ran" ]
}

@test "a branch's name made up in .git/HEAD reaches the terminal as text, without its control characters" {
  repo "$HOME/r"
  # A clipboard write (OSC 52), a cursor move, and readline's own marks.
  printf 'ref: refs/heads/x\033]52;c;ZXZpbA==\007\033[5A\001\033[2J\002y\n' >"$HOME/r/.git/HEAD"
  ibash "$SOURCE" 'cd ~/r' ': one'
  line=$(grep -a ': one$' "$SCRATCH/out")
  # The colours Nova's prompt puts on, and no other escape.
  rest=$(sed $'s/\e\\[[0-9;]*m//g' <<<"$line")
  [[ $rest != *[[:cntrl:]]* ]] || { cat -v <<<"$line"; false; }
  [[ $rest == *'x]52;c;ZXZpbA==[5A[2Jy'* ]] || { cat -v <<<"$line"; false; }
}

@test "the prompt leaves the user's shell as it was: BASH_REMATCH, an ERR trap, and few lines under set -x" {
  repo "$HOME/r"
  ibash "$SOURCE" 'cd ~/r' '[[ key=value =~ ^([a-z]+)=(.*)$ ]]' 'echo "matched ${BASH_REMATCH[*]}"' \
    'trap "echo err-trap-\$((1+1))" ERR; set -E' ': quiet' ': quiet too' 'trap - ERR; set +E'
  grep -qx 'matched key=value key value' "$SCRATCH/out"
  # What the trap would print, which the line typed to set it does not hold.
  fails grep -q 'err-trap-2' "$SCRATCH/out"

  # set -x: the prompt's own lines are a handful, not every line of it.
  ibash "$SOURCE" 'cd ~/r' 'set -x' ': traced' 'set +x'
  traced=$(sed -n '/: traced$/,/set +x$/p' "$SCRATCH/out" | grep -c '^+')
  [ "$traced" -le 20 ] || { echo "$traced traced lines for one command"; cat -v "$SCRATCH/out"; false; }
  fails grep -q '^+* git ' "$SCRATCH/out"
}

@test "only what comes after the check of bash's version is written for bash 5.3" {
  # An older bash stops at ${ …; } and ${| …; } as an error, where it reads
  # them: the file returns before them for one, so none may stand earlier.
  guard=$(grep -n '^if ((BASH_VERSINFO\[0\] < 5 || (BASH_VERSINFO\[0\] == 5 && BASH_VERSINFO\[1\] < 3))); then$' "$REPO_ROOT/data/bash/bashrc" | cut -d: -f1)
  [ -n "$guard" ]
  first=$(grep -n '^[^#]*\${[ |]' "$REPO_ROOT/data/bash/bashrc" | head -n1 | cut -d: -f1)
  [ -n "$first" ]
  [ "$guard" -lt "$first" ] || { echo "line $first uses bash 5.3's words before the check at line $guard"; false; }
  sed -n "$((guard + 1)),$((guard + 3))p" "$REPO_ROOT/data/bash/bashrc" | grep -qx '  return 0'
  # The account's own file is read by any bash at all.
  fails grep -q '\${[ |]' "$REPO_ROOT/data/skel/.bashrc"
}

@test "the arrows find the commands that start with what is typed, in both forms terminals send; on an empty line, the last" {
  printf '%s\n' 'echo aaa' 'echo bbb' 'echo ccc' >"$HOME/.bash_history"
  IENV=(NO_COLOR=1)
  pty_bash "$SOURCE\r" 'echo a\e[A\r' 'echo b\eOA\r' '\e[A\r'
  [ "$(grep -cx 'aaa' "$SCRATCH/out")" -eq 1 ]
  [ "$(grep -cx 'bbb' "$SCRATCH/out")" -eq 2 ]
  fails grep -qx 'ccc' "$SCRATCH/out"
}

@test "colours are the terminal's own: the folder, git's, and the status in red" {
  repo "$HOME/r"
  # The prompt as drawn, after the command that failed: caught by a hook
  # after the prompt's own.
  ibash "$SOURCE" 'PROMPT_COMMAND+=('\''[[ ! -e ~/want ]] || { printf %s "${PS1@P}" >~/ps1; rm ~/want; }'\'')' \
    'cd ~/r' 'echo b >>a' 'false' ': c' 'touch ~/want; false' ': d'
  [ "$(prompt_of ': c')" = $'\e[1;34m~/r\e[0m \e[32mmain\e[0m \e[31m*\e[0m \e[31mexit 1\e[0m $ ' ]
  # For readline, all that takes no room is between \001 and \002, as \[ \]
  # make it: with those parts taken out, no escape is left, and they hold
  # escapes alone.
  ps1=$(<"$HOME/ps1")
  [[ $ps1 == *$'\001'* ]]
  rest=$(printf '%s' "$ps1" | sed $'s/\001[^\002]*\002//g')
  [[ $rest != *$'\e'* && $rest != *$'\001'* && $rest != *$'\002'* ]]
  [ "$rest" = '~/r main * exit 1 $ ' ]
  parts=$(printf '%s' "$ps1" | grep -o $'\001[^\002]*\002' | tr -d '\001\002' | sed $'s/\e\\[[0-9;]*m//g' | tr -d '\n')
  [ -z "$parts" ]
}

@test "no colours with NO_COLOR or TERM=dumb, the same words" {
  repo "$HOME/r"
  IENV=(NO_COLOR=1)
  ibash "$SOURCE" 'cd ~/r' 'echo b >>a' 'false' ': c' 'bind -v >~/settings'
  [ "$(prompt_of ': c')" = '~/r main * exit 1 $ ' ]
  grep -qx 'set colored-stats off' "$HOME/settings"

  IENV=()
  ITERM=dumb
  ibash "$SOURCE" 'cd ~/r' 'false' ': c'
  [ "$(prompt_of ': c')" = '~/r main * exit 1 $ ' ]
}

@test "the picture's terminal (tools/screenshots) draws the prompt as Nova's bash does" {
  repo "$HOME/Projects/nova"
  echo b >>"$HOME/Projects/nova/a"
  ibash "$SOURCE" 'cd ~/Projects/nova' 'ls'
  # Its two helpers, from the demo script it writes.
  helpers=$(grep -E '^(c|prompt)\(\) \{' "$REPO_ROOT/tools/screenshots")
  [ "$(wc -l <<<"$helpers")" -eq 2 ]
  eval "$helpers"
  [ "$(prompt ls)" = "$(prompt_of ls)ls" ]
}

@test "reading it twice changes nothing" {
  state='{ declare -p PS1 PS0 PROMPT_COMMAND; alias; shopt; for m in emacs vi-insert vi-command; do bind -m $m -p; done; bind -v; }'
  ibash "$SOURCE" "$state >~/once" "$SOURCE" "$state >~/twice"
  [ -s "$HOME/once" ]
  diff "$HOME/once" "$HOME/twice"
}

@test "a PROMPT_COMMAND set before it still runs, and one set after as a string leaves the prompt's; the status is the command's" {
  mkdir -p "$HOME/folder"
  ibash "PROMPT_COMMAND='echo before-ran'" "$SOURCE" 'cd ~/folder' '(exit 4)' ': after-4' \
    "PROMPT_COMMAND='echo after-ran; (exit 7)'" 'true' ': after-true' 'false' ': after-false'
  grep -q '^before-ran$' "$SCRATCH/out"
  grep -q '^after-ran$' "$SCRATCH/out"
  [ "$(prompt_of ': after-4' | plain)" = '~/folder exit 4 $ ' ]
  [ "$(prompt_of ': after-true' | plain)" = '~/folder $ ' ]
  [ "$(prompt_of ': after-false' | plain)" = '~/folder exit 1 $ ' ]

  # An array, as Arch's /etc/bash.bashrc and mise make it, and an element
  # added after the prompt's that fails.
  ibash "PROMPT_COMMAND=('echo first-ran' false)" "$SOURCE" 'PROMPT_COMMAND+=(false)' 'cd ~/folder' ': one' 'declare -p PROMPT_COMMAND'
  grep -q '^first-ran$' "$SCRATCH/out"
  [ "$(prompt_of ': one' | plain)" = '~/folder $ ' ]
  grep -qF 'declare -a PROMPT_COMMAND=([0]="echo first-ran" [1]="false" [2]="__nova_prompt_precmd" [3]="false")' "$SCRATCH/out"
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

@test "a repository slow to read: after two slow prompts, no marks there, said once; git's switches turn them off" {
  repo "$HOME/r"
  echo b >>"$HOME/r/a"
  IENV=(NOVA_PROMPT_GIT_BUDGET=0)
  ibash "$SOURCE" 'cd ~/r' ': one' ': two' ': three' ': four'
  [ "$(prompt_of ': one' | plain)" = '~/r main * $ ' ]
  [ "$(prompt_of ': three' | plain)" = '~/r main $ ' ]
  [ "$(prompt_of ': four' | plain)" = '~/r main $ ' ]
  [ "$(grep -c '^Finding this repository.s changes took over 0 ms twice' "$SCRATCH/out")" -eq 1 ]

  IENV=()
  echo n >"$HOME/r/new"
  git -C "$HOME/r" config bash.showDirtyState false
  ibash "$SOURCE" 'cd ~/r' ': dirty-off' 'git config bash.showUntrackedFiles false' ': both-off' 'git config bash.showDirtyState true' ': untracked-off'
  [ "$(prompt_of ': dirty-off' | plain)" = '~/r main % $ ' ]
  [ "$(prompt_of ': both-off' | plain)" = '~/r main $ ' ]
  [ "$(prompt_of ': untracked-off' | plain)" = '~/r main * $ ' ]

  # As in git, the repository's switch wins over the global one.
  printf '[bash]\n\tshowDirtyState = false\n' >"$HOME/gitconfig"
  IENV=(GIT_CONFIG_GLOBAL="$HOME/gitconfig")
  ibash "$SOURCE" 'cd ~/r' ': repository-on' 'git config --unset bash.showDirtyState' ': global-off'
  [ "$(prompt_of ': repository-on' | plain)" = '~/r main * $ ' ]
  [ "$(prompt_of ': global-off' | plain)" = '~/r main $ ' ]
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
  ibash '. ~/.bashrc' 'cd ~/fodler' 'pwd' 'false' ': c'
  grep -qx "$HOME/folder" "$SCRATCH/out"
  [ "$(prompt_of ': c' | plain)" = '~/folder exit 1 $ ' ]

  NOVA_PATH=$SCRATCH/none
  ibash '. ~/.bashrc' 'echo "${PS0-none}"' ': c'
  grep -qx 'none' "$SCRATCH/out"
  fails grep -q 'No such file' "$SCRATCH/out"
}

@test "without the defaults (a container on this home, an older Nova) the history keeps its length, the defaults' own" {
  cp "$REPO_ROOT/data/skel/.bashrc" "$HOME/.bashrc"
  settings='echo "$HISTCONTROL $HISTSIZE $HISTFILESIZE $(shopt -p histappend)"'
  ibash '. ~/.bashrc' "$settings >~/with"
  NOVA_PATH=$SCRATCH/none
  ibash '. ~/.bashrc' "$settings >~/without"
  [ -s "$HOME/with" ]
  diff "$HOME/with" "$HOME/without"

  # bash alone keeps 500 lines, and cuts the file to that once it has read
  # its starting file. So here bash reads ~/.bashrc itself as it starts, as
  # a terminal's does, and no system file with it: bash's POSIX mode reads
  # $ENV alone.
  seq -f ': line %g' 1 700 >"$HOME/.bash_history"
  (cd "$HOME" && printf '%s\n' ': one more' | shell_env ENV="$HOME/.bashrc" bash --posix --noprofile -i >"$SCRATCH/out" 2>&1)
  [ "$(grep -c '^: line ' "$HOME/.bash_history")" -eq 700 ]
  grep -qx ': one more' "$HOME/.bash_history"
}

@test "a PS1 of the user's own costs no git, and a PROMPT_COMMAND set anew without the prompt's hook leaves nothing stale" {
  repo "$HOME/r"
  echo b >>"$HOME/r/a"
  printf '#!/bin/sh\necho "$*" >>"$HOME/git-calls"\nexec /usr/bin/git "$@"\n' >"$SCRATCH/bin/git"
  chmod +x "$SCRATCH/bin/git"
  ibash "$SOURCE" 'cd ~/r' ': nova' "PS1='mine \\$ '" 'rm -f ~/git-calls' ': mine-one' ': mine-two'
  [ "$(prompt_of ': nova' | plain)" = '~/r main * $ ' ]
  [ "$(prompt_of ': mine-two')" = 'mine $ ' ]
  [ ! -e "$HOME/git-calls" ]

  ibash "$SOURCE" 'cd ~/r' ': one' 'PROMPT_COMMAND=()' 'false' ': two'
  [ "$(prompt_of ': one' | plain)" = '~/r main * $ ' ]
  [ "$(prompt_of ': two' | plain)" = '~/r $ ' ]
}

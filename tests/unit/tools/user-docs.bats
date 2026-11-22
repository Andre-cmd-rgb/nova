#!/usr/bin/env bats

# The user pages against what Nova installs: every `nova …` command they quote
# runs one of the helpers the package installs, every Super key they name is
# bound, every key of the keys page's tables is bound, and every Settings page
# and menu entry they lead to is there under that name. The pages were written
# beside the code they describe; a renamed entry or a dropped command fails
# here, not in a newcomer's terminal.
#
# What it does not check, so that a pass is not read as more: a command's
# flags (--bundle, --dry-run), a bracketed alternative ([toggle|mode auto]),
# any word after the first verb, and the verbs of a compiled helper (nova
# theme, nova airdrop); what a command does with no verb; numbers, defaults,
# paths and sizes; what a key or a value means (only that a key is bound);
# keys without Super outside the keys page's and the README's tables; menu
# paths not written "the menu's A → B"; and a Settings item only by the
# start of a label, title or text in that page's own files.

load ../test_helper

# The user pages, as tools/build-site lists them, and the README and the
# landing page beside them.
pages() {
  local names
  names=$(sed -n 's/^  "[^|]*|\(.*\)"$/\1/p' "$REPO_ROOT/tools/build-site" | tr ' ' '\n' | grep .)
  [[ -n $names ]] || return 1
  sed 's#.*#docs/&.md#' <<<"$names"
  printf '%s\n' README.md site/index.html
}

# The helpers the package puts in /usr/lib/nova/bin, a line each as name, tab,
# the file it is made from (- for a compiled one), from what `make install`
# would run: each file installed there by name, each one a -t puts there, each
# link, and the shell plugins' commands (SHELL_CLI's loop).
installed_helpers() {
  local line word files source
  (cd "$REPO_ROOT" && make -s -n DESTDIR=/R CARGO_TARGET_DIR=/T install) |
    sed -e ':a' -e '/\\$/N; s/\\\n//; ta' |
    while IFS= read -r line; do
      if [[ $line == *"for link in "* ]]; then
        files=${line#*for link in }
        files=${files%%;*}
        for word in $files; do printf 'nova-%s\tsrc/shell/plugins/%s\n' "${word%%:*}" "${word#*:}"; done
      elif [[ $line == *"-t /R/usr/lib/nova/bin "* ]]; then
        files=${line#*-t /R/usr/lib/nova/bin }
        for word in $files; do
          (cd "$REPO_ROOT" && compgen -G "$word") | sed 's#^\(.*/\)\{0,1\}\([^/]*\)$#\2\t&#'
        done
      elif [[ $line =~ ([^ ]+)\ /R/usr/lib/nova/bin/(nova-[a-z0-9-]+)$ ]]; then
        source=${BASH_REMATCH[1]}
        [[ $source == /T/* || $source == ../* ]] && source=-
        printf '%s\t%s\n' "${BASH_REMATCH[2]}" "$source"
      fi
    done | sort -u
}

# Every `nova …` a page quotes, a line each, without a leading sudo: in
# backticks, in <code>, and on the lines of its shell blocks.
quoted_commands() {
  local page
  while IFS= read -r page; do
    grep -ohE '`(sudo )?nova [^`]*`' "$REPO_ROOT/$page" | tr -d '`'
    grep -ohE '<code>(sudo )?nova [^<]*</code>' "$REPO_ROOT/$page" | sed 's#</\?code>##g'
    awk '/^```/ { block = !block; next } block' "$REPO_ROOT/$page" | sed 's/ *#.*//' | grep -E '^(sudo )?nova ' || true
  done < <(pages) | sed 's/^sudo //' | sort -u
}

# A command a line for each alternative its words give: `nova restart
# shell|audio` is nova restart shell and nova restart audio (a Markdown
# table writes the | as \|).
alternatives() { # command line
  local words=() i alternative
  read -ra words <<<"${1//\\|/|}"
  for i in "${!words[@]}"; do
    [[ ${words[i]} =~ ^[a-z0-9-]+(\|[a-z0-9-]+)+$ ]] || continue
    for alternative in ${words[i]//|/ }; do
      words[i]=$alternative
      echo "${words[*]}"
    done
    return 0
  done
  echo "${words[*]}"
}

# The helper `nova <words>` runs, as src/cli/nova picks it: the longest name
# its leading words spell, then a tab and the word after them; or, for a
# group's name alone (nova apps), the group, which it lists.
helper_for() { # command line
  local words=() leading=() word n name
  read -ra words <<<"${1#nova }"
  for word in "${words[@]}"; do
    [[ $word =~ ^[a-z0-9][a-z0-9-]*$ ]] || break
    leading+=("$word")
  done
  for ((n = ${#leading[@]}; n > 0; n--)); do
    name=nova-$(IFS=-; echo "${leading[*]:0:n}")
    [[ $name != nova-launch ]] || continue
    [[ -n ${SOURCES[$name]:-} ]] && { printf '%s\t%s\n' "$name" "${words[n]:-}"; return 0; }
  done
  ((${#words[@]} == 1 && ${#leading[@]} == 1)) && [[ $HELPERS == *$'\n'"nova-${leading[0]}-"* ]] && { echo "nova-${leading[0]}-"; return 0; }
  return 1
}

# Whether the script <file> takes <word> as a verb: a pattern of a case that
# dispatches its first argument (case $1, ${1:-}, $#:${1:-}, or on $command,
# $cmd, $verb or $action, outside any function but main), alone or among
# others (toggle | summon), and maybe after the count of arguments it goes
# with (2:show, *:add). An arm of a case inside another arm is not one: it
# took `nova power gpu off` for a verb, from mode's own `2:off)`. A script
# with no such case is taken at any depth.
takes_verb() { # file word
  awk -v verb="$2" '
    function count(text, word,   n, rest) {
      n = 0; rest = " " text " "
      while (match(rest, "[^A-Za-z0-9_]" word "[^A-Za-z0-9_]")) { n++; rest = substr(rest, RSTART + RLENGTH - 1) }
      return n
    }
    BEGIN { arm = "^[[:space:]]*[(]?([^)#]*[ |])?([0-9*]+:)?" verb "[[:space:]]*([|]|[)])" }
    { line = $0; sub(/^[[:space:]]*#.*/, "", line); sub(/[[:space:]]#.*/, "", line) }
    line ~ /^[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*[(][)][[:space:]]*[{]/ { fn = line; sub(/[[:space:]]*[(].*/, "", fn) }
    line ~ /^[}]/ { fn = "" }
    line ~ arm { anywhere = 1; if (own && depth == own) found = 1 }
    {
      opened = (line ~ /(^|[^A-Za-z0-9_])case[[:space:]]+[^[:space:]]+[[:space:]]+in([[:space:]]|$)/) ? 1 : 0
      if (opened && depth == 0 && (fn == "" || fn == "main") &&
        line ~ /case[[:space:]]+"?([$]#:)?[$]([{]1[:}]|1([^0-9]|$)|[{]?(command|cmd|verb|action)([^A-Za-z0-9_]|$))/) { own = 1; dispatches = 1 }
      depth += opened - count(line, "esac")
      if (depth < 1) own = 0
    }
    END { exit !(dispatches ? found : anywhere) }
  ' "$REPO_ROOT/$1"
}

@test "every nova command the user pages quote runs a helper the package installs, with a verb it takes" {
  local name source
  declare -A SOURCES=()
  while IFS=$'\t' read -r name source; do SOURCES[$name]=$source; done < <(installed_helpers)
  HELPERS=$'\n'$(printf '%s\n' "${!SOURCES[@]}" | sort)
  # A sample of what is there, so that a parse gone wrong fails here.
  for name in nova-theme nova-airdrop nova-settings nova-dictation nova-usb nova-patch nova-power nova-pinentry; do
    [[ -n ${SOURCES[$name]:-} ]] || { echo "the install's helpers lack $name: the parse is wrong" >&2; return 1; }
  done
  [ "${SOURCES[nova-dictation]}" = src/shell/plugins/dictation/bin/dictation ]
  [ "${SOURCES[nova-power]}" = src/power/bin/nova-power ] && [ "${SOURCES[nova-theme]}" = - ]
  local missing=() quoted command resolved verb
  [ "$(quoted_commands | wc -l)" -ge 80 ]
  while IFS= read -r quoted; do
    # The dispatcher's own: its help, and its form.
    case $quoted in "nova help"* | "nova <group>"*) continue ;; esac
    while IFS= read -r command; do
      resolved=$(helper_for "$command") || { missing+=("$command: no helper"); continue; }
      name=${resolved%%$'\t'*} verb=${resolved#*$'\t'}
      # A word after the helper's name is a verb of its script's, where it is
      # a script (a compiled helper's are its own business).
      source=${SOURCES[$name]:--}
      [[ $resolved == *$'\t'* && $verb =~ ^[a-z][a-z-]*$ && $source != - ]] || continue
      takes_verb "$source" "$verb" || missing+=("$command: $name takes no verb $verb")
    done < <(alternatives "$quoted")
  done < <(quoted_commands)
  ((${#missing[@]} == 0)) || { printf '%s\n' "${missing[@]}" >&2; return 1; }
}

@test "the Settings pages the user pages open by name are pages nova settings opens" {
  local known page bad=()
  known=$(sed -n 's/^PAGES="\(.*\)"$/\1/p' "$REPO_ROOT/src/cli/bin/nova-settings")
  [[ -n $known ]]
  # The last column of using.md's table of pages, and nova settings <page>.
  while IFS= read -r page; do
    [[ " $known " == *" $page "* ]] || bad+=("$page")
  done < <(grep -ohE '\| `[a-z-]+` \|$' "$REPO_ROOT/docs/using.md" | tr -d '|` ';
    quoted_commands | sed -n 's/^nova settings \([a-z-]*\)$/\1/p')
  [ "$(grep -cE '\| `[a-z-]+` \|$' "$REPO_ROOT/docs/using.md")" -ge 15 ]
  ((${#bad[@]} == 0)) || { printf 'no Settings page: %s\n' "${bad[@]}" >&2; return 1; }
}

# The sidebar's names of Settings' pages, a line each.
settings_pages() {
  sed -n 's/^ *{ id: "[a-z-]*", label: "\([^"]*\)".*/\1/p' "$REPO_ROOT/src/shell/plugins/settings/Panel.qml"
}

# What one of Settings' pages says: the labels, titles and buttons in its
# block of Panel.qml (the Component whose page has that title) and in the
# Settings files it uses, and the files those use, a line each.
page_words() { # page's title
  local dir=$REPO_ROOT/src/shell/plugins/settings type file
  local -a queue=() seen=()
  local block
  block=$(awk -v title="title: \"$1\"" '/^  Component [{]/ { if (hit) exit; text = "" }
    { text = text $0 "\n" } index($0, title) { hit = 1 } END { if (hit) printf "%s", text }' "$dir/Panel.qml")
  [[ -n $block ]] || return 0
  words_in() { grep -ohE '(label|title|text): "[^"]+"' | sed 's/^[a-z]*: "\(.*\)"$/\1/'; }
  words_in <<<"$block"
  mapfile -t queue < <(grep -oE '\b[A-Z][A-Za-z]+ \{' <<<"$block" | sed 's/ {$//' | sort -u)
  while ((${#queue[@]})); do
    type=${queue[0]}
    queue=("${queue[@]:1}")
    file=$dir/$type.qml
    [[ -f $file && " ${seen[*]} " != *" $type "* ]] || continue
    seen+=("$type")
    words_in <"$file"
    mapfile -t -O "${#queue[@]}" queue < <(grep -oE '\b[A-Z][A-Za-z]+ \{' "$file" | sed 's/ {$//' | sort -u)
  done
}

@test "every Settings → page the user pages name is in Settings, and what they name on it too" {
  local sidebar words text page rest found bad=() page_file
  sidebar=$(settings_pages)
  [ "$(wc -l <<<"$sidebar")" -ge 15 ]
  # A page's words are its own: Updates' button is not on About.
  words=$(page_words Updates)
  grep -qx 'Test release candidates' <<<"$words"
  ! grep -qx 'Transparent' <<<"$words"
  while IFS= read -r page_file; do
    # "Settings → Page", then maybe " → What is on it", Markdown's ** dropped.
    while IFS= read -r text; do
      text=${text#Settings → }
      found=''
      while IFS= read -r page; do
        [[ $text == "$page"* && ${#page} -gt ${#found} ]] && found=$page
      done <<<"$sidebar"
      # The iPhone's own Settings, which the AirDrop and iPhone pages send
      # you to on the phone.
      case $text in "General → AirDrop"* | "Bluetooth → ⓘ"*) continue ;; esac
      [[ -n $found ]] || { bad+=("Settings → $text"); continue; }
      rest=${text#"$found"}
      [[ $rest == " → "* ]] || continue
      rest=${rest# → }
      words=$(page_words "$found")
      found=''
      while IFS= read -r page; do
        [[ ${rest,,} == "${page,,}"* ]] && found=yes
      done <<<"$words"
      [[ -n $found ]] || bad+=("Settings → $text")
    done < <(sed 's/\*\*//g' "$REPO_ROOT/$page_file" | grep -oE 'Settings → [^.,;:()]+')
  done < <(pages)
  ((${#bad[@]} == 0)) || { printf 'not in Settings: %s\n' "${bad[@]}" >&2; return 1; }
}

# The menu's entries as id, tab, label, from menu.jsonc's one line each.
menu_entries() {
  sed -n 's/^ *"\([a-z0-9.-]*\)": {.*"label":"\([^"]*\)".*/\1\t\2/p' "$REPO_ROOT/data/defaults/menu.jsonc"
}

@test "every path in the menu the user pages give, as the menu's A → B, is the menu's" {
  local entries text top child id label found bad=() page
  entries=$(menu_entries)
  [ "$(wc -l <<<"$entries")" -ge 60 ]
  while IFS= read -r page; do
    while IFS= read -r text; do
      top=${text%% → *}
      child=${text#* → }
      id=$(awk -F'\t' -v l="$top" '$1 !~ /\./ && $2 == l { print $1 }' <<<"$entries")
      [[ -n $id ]] || { bad+=("$text"); continue; }
      found=''
      while IFS=$'\t' read -r _ label; do
        [[ $child == "$label"* ]] && found=yes
      done < <(awk -F'\t' -v p="$id." 'index($1, p) == 1 && substr($1, length(p) + 1) !~ /\./' <<<"$entries")
      [[ -n $found ]] || bad+=("$text")
    done < <(grep -oE "menu's [A-Z][A-Za-z ]* → [A-Z][^.,;]*" "$REPO_ROOT/$page" | sed "s/^menu's //")
  done < <(pages)
  ((${#bad[@]} == 0)) || { printf 'not in the menu: %s\n' "${bad[@]}" >&2; return 1; }
}

# Every key data/hypr/keys binds, as "MODS+KEY" with its modifiers in a fixed
# order and everything in capitals, a line each.
bound_keys() {
  HYPR=$REPO_ROOT/data/hypr lua -e '
    local anything
    anything = setmetatable({}, { __index = function() return anything end, __call = function() return {} end })
    hl = setmetatable({
      bind = function(keys) print(keys) return { unbind = function() end } end,
      on = function() end,
      get_layers = function() return {} end,
    }, { __index = function() return anything end })
    dofile(os.getenv("HYPR") .. "/lib.lua")
    nova.bind_while_layer = function(_, make) make() end
    for _, file in ipairs({ "apps", "clipboard", "desktop", "dictation", "media", "windows" }) do
      dofile(os.getenv("HYPR") .. "/keys/" .. file .. ".lua")
    end' </dev/null | normal_keys
}

# Key combinations, "SUPER + SHIFT + B" or "Super+Shift+B", in one form.
normal_keys() {
  awk '{
    gsub(/ *\+ */, "+"); n = split(toupper($0), part, "+")
    mods = ""
    split("SUPER SHIFT CTRL ALT", order, " ")
    for (o = 1; o <= 4; o++) for (i = 1; i < n; i++) if (part[i] == order[o]) mods = mods order[o] "+"
    print mods part[n]
  }'
}

# A key as the pages write it, as Hyprland names it.
hypr_key() { # key
  case ${1,,} in
    [1-9]) echo "CODE:1$(($1 - 1))" ;;
    0) echo CODE:19 ;;
    minus) echo CODE:20 ;;
    equals) echo CODE:21 ;;
    arrows) echo LEFT ;;
    drag) echo MOUSE:272 ;;
    right-drag) echo MOUSE:273 ;;
    *) echo "${1^^}" ;;
  esac
}

# The combinations a cell or a sentence writes out: "Super+Ctrl+A, B, W"
# gives Super+Ctrl+A, Super+Ctrl+B and Super+Ctrl+W; "Super+1 to Super+0"
# and "Super+Alt+1 to 5" both ends. One ending in a modifier is no key.
written_keys() {
  local text part mods key
  while IFS= read -r text; do
    mods=''
    for part in $(sed -E 's/, | to | or /\n/g' <<<"$text" | tr -d ' '); do
      if [[ $part == *+* ]]; then
        mods=${part%+*}+
        key=${part##*+}
      else
        # The modifiers of the one before, or none for a key alone (Print).
        key=$part
      fi
      case ${key,,} in super | shift | ctrl | alt | "") continue ;; esac
      echo "$mods$(hypr_key "$key")"
    done
  done | normal_keys
}

@test "every key the keys page's tables list, and every Super key a user page names, is bound" {
  local bound keys missing=() key page
  bound=$(bound_keys)
  [ "$(wc -l <<<"$bound")" -ge 150 ]
  grep -qxF "SUPER+SPACE" <<<"$bound"
  # The first column of each table on the keys page and the README's, but
  # the command table's.
  keys=$(for page in docs/keys.md README.md; do
    awk -F'|' '/^## The nova command/ { stop = 1 } !stop && /^\| [A-Z]/ && $2 !~ /^ (Key|Group|Command) $/ { print $2 }' "$REPO_ROOT/$page"
  done | sed 's/Calculator key/XF86Calculator/; s/^ *//; s/ *$//' | written_keys)
  [ "$(wc -l <<<"$keys")" -ge 80 ]
  # And Super's, wherever a page names one.
  keys+=$'\n'$(while IFS= read -r page; do
    grep -oE 'Super(\+[A-Za-z0-9-]+)+(, [A-Z0-9][a-z0-9]*\b)*' "$REPO_ROOT/$page"
  done < <(pages) | written_keys)
  while IFS= read -r key; do
    [[ -z $key ]] || grep -qxF "$key" <<<"$bound" || missing+=("$key")
  done < <(sort -u <<<"$keys")
  ((${#missing[@]} == 0)) || { printf 'not bound: %s\n' "${missing[@]}" >&2; return 1; }
}

# The work each copy of a bar widget does by itself, a line each:
# "<file> <line> <kind>". Each screen's bar has a copy of every widget, so
# work done in the copy is done once for each screen; it belongs to the
# widget's service instead (Ui/BarWidgetService.qml). Run from the shell's
# folder over all of its QML files:
#   awk -v roots="<file> ..." -f widget-work.awk <file>...
#
# The roots are the widgets and what they load by address (a Loader's
# source); the files they are made of are followed as windows-reached.awk
# follows them. The kinds of work:
#   process  a Process that starts by itself (any running: of its own)
#   watch    a FileView that watches its file (watchChanges: true)
#   timer    a Timer that goes on by itself (repeat: true), but one that
#            runs only while its copy's panel is open (running: opened, or
#            opened && more), which one copy at a time is
# What it cannot see: a process started from Component.onCompleted, or by a
# signal of a shared object; a review catches those.
# POSIX awk, as the test may run under mawk.
function strip(line) {
  gsub(/\\./, "", line)
  gsub(/"[^"]*"/, "\"\"", line)
  gsub(/'[^']*'/, "''", line)
  sub(/\/\/.*/, "", line)
  return line
}

# <path> with ./ and dir/.. taken out.
function norm(path,   parts, count, i, out, kept, k) {
  count = split(path, parts, "/")
  k = 0
  for (i = 1; i <= count; i++) {
    if (parts[i] == "" || parts[i] == ".") continue
    if (parts[i] == ".." && k > 0 && kept[k] != "..") { k--; continue }
    kept[++k] = parts[i]
  }
  out = ""
  for (i = 1; i <= k; i++) out = out (i > 1 ? "/" : "") kept[i]
  return out
}

function folder(path) {
  if (path !~ /\//) return ""
  sub(/\/[^\/]*$/, "", path)
  return path
}

function under(dir, name) {
  return dir == "" ? name : dir "/" name
}

# The file that type <type> (<T> or <Alias>.<T>) used in <file> is, or "".
function resolve(file, type,   alias, candidate, i) {
  alias = ""
  if (index(type, ".")) {
    alias = type
    sub(/\..*/, "", alias)
    sub(/^[^.]*\./, "", type)
  }
  for (i = imports[file]; i >= 1; i--) {
    if (importedAs[file, i] != alias) continue
    candidate = under(imported[file, i], type ".qml")
    if (candidate in known) return candidate
  }
  if (alias != "") return ""
  candidate = under(folder(file), type ".qml")
  return (candidate in known) ? candidate : ""
}

FNR == 1 {
  file = norm(FILENAME)
  known[file] = 1
  imports[file] = 0
  uses[file] = 0
  top[file] = ""
  works[file] = 0
  inside = 0
}

# The folders it imports: one of its own (import "dir") or the shell's
# (import qs.Ui), each with its alias, or "".
/^[ \t]*import[ \t]+("[^"]+"|qs\.)/ {
  target = $0
  sub(/^[ \t]*import[ \t]+/, "", target)
  as = ""
  if (match(target, /[ \t]as[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
    as = substr(target, RSTART, RLENGTH)
    sub(/^[ \t]as[ \t]+/, "", as)
  }
  sub(/[ \t].*/, "", target)
  if (target ~ /^qs\./) {
    target = substr(target, 4)
    gsub(/\./, "/", target)
  } else {
    gsub(/"/, "", target)
    if (target ~ /\.js$/) next
    target = under(folder(file), target)
  }
  imported[file, ++imports[file]] = norm(target)
  importedAs[file, imports[file]] = as
  next
}

# The objects it is made of: the first is its top one.
{
  line = strip($0)
  while (match(line, /(^|[^A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_]*\.)?[A-Z][A-Za-z0-9_]*[ \t]*\{/)) {
    type = substr(line, RSTART, RLENGTH)
    sub(/[ \t]*\{$/, "", type)
    sub(/^[^A-Za-z_]/, "", type)
    line = substr(line, RSTART + RLENGTH)
    if (top[file] == "") top[file] = type
    else used[file, ++uses[file]] = type
  }
}


# The blocks of work in it, read whole, their braces counted.
{
  line = strip($0)
  if (!inside && match(line, /(^|[^A-Za-z0-9_.])(Process|FileView|Timer)[ \t]*\{/)) {
    kind = substr(line, RSTART, RLENGTH)
    sub(/^[^A-Z]*/, "", kind)
    sub(/[ \t]*\{$/, "", kind)
    inside = 1
    depth = 0
    body = ""
    startLine = FNR
    line = substr(line, RSTART)
  }
  if (inside) {
    body = body "\n" line
    depth += gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
    if (depth <= 0) {
      inside = 0
      what = ""
      if (kind == "Process" && body ~ /(^|[^A-Za-z0-9_.])running:/) what = "process"
      if (kind == "FileView" && body ~ /watchChanges:[ \t]*true/) what = "watch"
      if (kind == "Timer" && body ~ /repeat:[ \t]*true/ && !(body ~ /running:[ \t]*([A-Za-z_][A-Za-z0-9_]*\.)?opened[ \t]*(;|\n|\}|&&|$)/)) what = "timer"
      if (what != "") work[file, ++works[file]] = startLine " " what
    }
  }
}

END {
  count = split(roots, queue, " ")
  for (i = 1; i <= count; i++) { queue[i] = norm(queue[i]); seen[queue[i]] = 1 }
  for (head = 1; head <= count; head++) {
    file = queue[head]
    if (!(file in known)) continue
    for (k = 1; k <= works[file]; k++) print file, work[file, k]
    if (top[file] != "") {
      target = resolve(file, top[file])
      if (target != "" && !(target in seen)) { seen[target] = 1; queue[++count] = target }
    }
    for (k = 1; k <= uses[file]; k++) {
      target = resolve(file, used[file, k])
      if (target != "" && !(target in seen)) { seen[target] = 1; queue[++count] = target }
    }
  }
}

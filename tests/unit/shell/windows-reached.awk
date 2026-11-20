# The QML files that make a window and are reached from the parts loaded
# all the time, a line each. Run from the shell's folder over all of its
# QML files: awk -v roots="<file> ..." -f windows-reached.awk <file>...
#
# A file is reached from a root by the types it is made of, found as QML
# finds them: <Alias>.<T> in the folder imported as <Alias>; <T> in a folder
# imported without one (import "dir", import qs.Ui), the last first, then
# in the file's own folder; any other is Qt's or Quickshell's. A window is
# one of Quickshell's (PanelWindow, FloatingWindow, PopupWindow,
# WlSessionLock), or a file whose top object is one, as Ui/PanelSurface.qml
# is. A file counts when it makes one inside it, or is a root that is one;
# a file that is a window counts where it is used.
#
# What it cannot see: a file made from its address (a Loader's source or
# setSource, Qt.createComponent), and whether a window inside a Loader, a
# LazyLoader or a Component is made at login or later; the list says which.
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

function isWindow(file, type,   target, bare) {
  bare = type
  sub(/^.*\./, "", bare)
  if (bare in builtin) return 1
  target = resolve(file, type)
  return target != "" && (target in windowFile)
}

FNR == 1 {
  file = norm(FILENAME)
  known[file] = 1
  imports[file] = 0
  uses[file] = 0
  top[file] = ""
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

END {
  builtin["PanelWindow"] = builtin["FloatingWindow"] = builtin["PopupWindow"] = builtin["WlSessionLock"] = 1
  # Files whose top object is a window, until no more are found.
  do {
    more = 0
    for (file in known)
      if (!(file in windowFile) && top[file] != "" && isWindow(file, top[file])) { windowFile[file] = 1; more = 1 }
  } while (more)

  count = split(roots, queue, " ")
  for (i = 1; i <= count; i++) { queue[i] = norm(queue[i]); isRoot[queue[i]] = 1; seen[queue[i]] = 1 }
  for (head = 1; head <= count; head++) {
    file = queue[head]
    if (!(file in known)) continue
    reported = isRoot[file] && (file in windowFile)
    if (top[file] != "") {
      target = resolve(file, top[file])
      if (target != "" && !(target in seen)) { seen[target] = 1; queue[++count] = target }
    }
    for (k = 1; k <= uses[file]; k++) {
      if (!(file in windowFile) && isWindow(file, used[file, k])) reported = 1
      target = resolve(file, used[file, k])
      if (target != "" && !(target in seen)) { seen[target] = 1; queue[++count] = target }
    }
    if (reported) print file
  }
}

# The Timers that run all the time once their part is made, a line each:
# "<file> <line>". Run over QML files: awk -f always-running.awk <file>...
# Comments and strings are left out, and a block is read whole, its braces
# counted. A Timer counts when it starts as its part is made, by
# `running: true` as it is (not through a binding) or by its id (or the name
# of the property that holds it) in the part's Component.onCompleted, or
# when it runs while a bar widget's service is wanted (`running: wanted`,
# or an id's), which it is for as long as the bar shows the widget; and
# then goes on by itself: it says `repeat: true`, or it starts itself again
# when it fires (restart(), start() or running = true, in its own block).
# POSIX awk, as the test may run under mawk.
function strip(line) {
  gsub(/\\./, "", line)
  gsub(/"[^"]*"/, "\"\"", line)
  gsub(/'[^']*'/, "''", line)
  sub(/\/\/.*/, "", line)
  return line
}

function count(text, brace,   copy) {
  copy = text
  return gsub(brace, "", copy)
}

# The ids that <text> starts: id.start(), id.restart(), id.running = true.
function started(text,   name) {
  while (match(text, /[A-Za-z_][A-Za-z0-9_]*[ \t]*\.[ \t]*(start|restart)[ \t]*\(\)|[A-Za-z_][A-Za-z0-9_]*[ \t]*\.[ \t]*running[ \t]*=[ \t]*true/)) {
    name = substr(text, RSTART, RLENGTH)
    sub(/[ \t]*\..*/, "", name)
    loadStarted[name] = 1
    text = substr(text, RSTART + RLENGTH)
  }
}

function flush(   i, atLoad) {
  for (i = 1; i <= n; i++) {
    atLoad = running[i] || (names[i] != "" && (names[i] in loadStarted)) || (alias[i] != "" && (alias[i] in loadStarted))
    if (atLoad && (repeats[i] || again[i])) print file, starts[i]
  }
  n = 0
  split("", loadStarted)
}

FNR == 1 {
  if (NR > 1) flush()
  file = FILENAME
  inside = 0
  completing = 0
}

{
  line = strip($0)

  # The part's Component.onCompleted, on its line or a block of its own.
  if (!completing && (at = index(line, "Component.onCompleted"))) {
    rest = substr(line, at + length("Component.onCompleted"))
    if (rest ~ /^[ \t]*:[ \t]*\{/) {
      completing = 1
      done = 0
    } else {
      started(rest)
    }
  }
  if (completing) {
    text = done ? line : rest
    started(text)
    done += count(text, "{") - count(text, "}")
    if (done <= 0) completing = 0
  }

  if (!inside && line ~ /(^|[^A-Za-z0-9_.])Timer[ \t]*\{/) {
    inside = 1
    depth = 0
    n++
    starts[n] = FNR
    names[n] = ""
    alias[n] = ""
    if (match(line, /property[ \t]+Timer[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*:/)) {
      alias[n] = substr(line, RSTART, RLENGTH)
      sub(/^property[ \t]+Timer[ \t]+/, "", alias[n])
      sub(/[ \t]*:$/, "", alias[n])
    }
    body = ""
    line = substr(line, match(line, /Timer[ \t]*\{/))
  }
  if (!inside) next
  body = body "\n" line
  depth += count(line, "{") - count(line, "}")
  if (depth > 0) next
  inside = 0
  if (match(body, /(^|[^A-Za-z0-9_.])id:[ \t]*[A-Za-z_][A-Za-z0-9_]*/)) {
    names[n] = substr(body, RSTART, RLENGTH)
    sub(/^.*id:[ \t]*/, "", names[n])
  }
  repeats[n] = body ~ /repeat:[ \t]*true/
  running[n] = body ~ /running:[ \t]*(true|([A-Za-z_][A-Za-z0-9_]*[ \t]*\.[ \t]*)?wanted)[ \t]*(;|\n|\}|$)/
  again[n] = body ~ /(^|[^A-Za-z0-9_.])(restart|start)[ \t]*\(\)|(^|[^A-Za-z0-9_.])running[ \t]*=[ \t]*true/
  if (names[n] != "") {
    self = names[n] "[ \t]*\\.[ \t]*(restart|start)[ \t]*\\(\\)"
    if (body ~ self) again[n] = 1
  }
}

END { if (NR > 0) flush() }

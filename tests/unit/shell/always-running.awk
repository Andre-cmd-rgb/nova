# The Timers that repeat and run all the time, a line each: "<file> <line>".
# Run over QML files: awk -f always-running.awk <file>... A Timer's block is
# read whole, braces counted on its lines with comments and strings left
# out; it counts when it says `repeat: true` and `running: true` as they are,
# not through a binding.
function strip(line) {
  gsub(/\\./, "", line)
  gsub(/"[^"]*"/, "\"\"", line)
  gsub(/'[^']*'/, "''", line)
  sub(/\/\/.*/, "", line)
  return line
}
FNR == 1 { inside = 0 }
{
  line = strip($0)
  if (!inside && line ~ /(^|[^A-Za-z0-9_.])Timer[ \t]*\{/) {
    inside = 1
    depth = 0
    start = FNR
    body = ""
    line = substr(line, match(line, /Timer[ \t]*\{/))
  }
  if (!inside) next
  body = body "\n" line
  opens = gsub(/\{/, "{", line)
  closes = gsub(/\}/, "}", line)
  depth += opens - closes
  if (depth > 0) next
  inside = 0
  if (body ~ /repeat:[ \t]*true/ && body ~ /running:[ \t]*true[ \t]*(;|\n|\}|$)/) print FILENAME, start
}

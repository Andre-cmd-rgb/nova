#!/usr/bin/env bats

# Each maintainer tool under tools/ says in the comment at its top how it is
# run, and its --help prints that comment: an option it takes that the comment
# does not name is one nobody finds (site-palettes took --default unsaid).

load ../test_helper

@test "every option a shell tool under tools/ takes is named in the comment at its top" {
  local tool top option seen=0 missing=()
  for tool in "$REPO_ROOT"/tools/*; do
    [[ -f $tool ]] && head -n 1 "$tool" | grep -qE '^#!.*\b(ba)?sh\b' || continue
    top=$(sed -n '2,/^[^#]/p' "$tool")
    # The options its argument case takes: --name), -x | --name), --name=*).
    while IFS= read -r option; do
      [[ $option == --help ]] && continue
      seen=$((seen + 1))
      grep -qF -- "$option" <<<"$top" || missing+=("tools/${tool##*/}: $option")
    done < <(grep -oE '^[[:space:]]+(-[A-Za-z] \| )?--[a-z][a-z0-9-]*(=\*)?( \| -[A-Za-z])?\)' "$tool" |
      grep -oE -- '--[a-z][a-z0-9-]*' | sort -u)
  done
  # A parse that finds no option would pass by checking none.
  [ "$seen" -ge 20 ]
  [ "${#missing[@]}" -eq 0 ] || {
    printf 'an option its top does not name: %s\n' "${missing[@]}"
    false
  }
}

#!/usr/bin/env bats

# Every shell script of Nova's is shellchecked: `make lint-shell` checks the
# files the install.mk files list in SHELL_SOURCES, and a script left out of
# them was never checked (nova-power-resume was not, until this test).

load ../test_helper

@test "every shell script under src, data, installer and tools is in SHELL_SOURCES" {
  cd "$REPO_ROOT"
  listed=$(make -s --no-print-directory -f Makefile -f - shell-sources <<'EOF'
shell-sources:
	@printf '%s\n' $(SHELL_SOURCES)
EOF
  )
  [ -n "$listed" ]
  missing=()
  while IFS= read -r -d '' file; do
    case $file in
      *.qml | *.js | *.md | *.json | *.jsonc | *.conf | *.lua | *.rs | *.toml | *.css | *.html | *.svg | *.png | *.jpg | *.txt) continue ;;
    esac
    [[ -f $file ]] && head -n 1 -- "$file" | grep -qE '^(#!.*\b(ba)?sh\b|# shellcheck shell=(ba)?sh\b)' || continue
    grep -qxF -- "$file" <<<"$listed" || missing+=("$file")
  done < <(git ls-files -z src data installer tools)
  if ((${#missing[@]})); then
    printf 'not in SHELL_SOURCES: %s\n' "${missing[@]}"
    return 1
  fi
}

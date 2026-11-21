#!/usr/bin/env bats

# Every shell script of Nova's is shellchecked: `make lint-shell` checks the
# files the install.mk files list in SHELL_SOURCES, and a script left out of
# them was never checked (nova-power-resume was not, until this test). The
# scripts are those tools/lint-patterns checks (--list), by one rule.

load ../test_helper

@test "every shell script under src, data, installer and tools is in SHELL_SOURCES" {
  cd "$REPO_ROOT"
  listed=$(make -s --no-print-directory -f Makefile -f - shell-sources <<'MAKE'
shell-sources:
	@printf '%s\n' $(SHELL_SOURCES)
MAKE
  )
  [ -n "$listed" ]
  scripts=$(tools/lint-patterns --list | grep -vE '\.(qml|js)$')
  [ -n "$scripts" ]
  missing=$(grep -vxF -f <(printf '%s\n' "$listed") <<<"$scripts" || true)
  if [[ -n $missing ]]; then
    printf 'not in SHELL_SOURCES: %s\n' $missing
    return 1
  fi
}

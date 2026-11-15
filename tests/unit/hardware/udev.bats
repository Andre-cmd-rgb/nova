#!/usr/bin/env bats

load ../test_helper

RULES="$REPO_ROOT/data/hardware/udev/80-nova-nvidia-sleep.rules"

# The rules as udev reads them: comments out, continued lines joined.
rules() { sed -e '/^#/d' -e ':a' -e '/\\$/{N;s/\\\n *//;ba}' "$RULES"; }

@test "the NVIDIA rules: udev reads them" {
  command -v udevadm >/dev/null || skip "no udevadm here"
  udevadm verify --help >/dev/null 2>&1 || skip "this udevadm has no verify"
  run udevadm verify "$RULES"
  [ "$status" -eq 0 ]
}

@test "the NVIDIA rules: every line is for NVIDIA's functions on a laptop that is not the P1" {
  local line count=0
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    count=$((count + 1))
    [[ $line == *'SUBSYSTEM=="pci"'* ]]
    [[ $line == *'ATTR{vendor}=="0x10de"'* ]]
    [[ $line == *'ATTR{[dmi/id]chassis_type}=="8|9|10|14|30|31|32"'* ]]
    [[ $line == *'ATTR{[dmi/id]product_version}!="ThinkPad P1 Gen 4i"'* ]]
    [[ $line == *'TEST=="power/control"'* ]]
  done < <(rules)
  [ "$count" -eq 3 ]
}

@test "the NVIDIA rules: the card may sleep once its driver is bound, and is awake without one" {
  run rules
  [[ $output == *'ACTION=="bind"'*'ATTR{class}=="0x030000|0x030200"'*'ATTR{power/control}="auto"'* ]]
  [[ $output == *'ACTION=="unbind"'*'ATTR{class}=="0x030000|0x030200"'*'ATTR{power/control}="on"'* ]]
  [[ $output == *'ACTION=="add|bind"'*'ATTR{class}=="0x040300|0x0c0330|0x0c8000"'*'ATTR{power/control}="auto"'* ]]
}

@test "the NVIDIA rules: the chassis types are nova-hw-laptop's" {
  local types
  types=$(sed -n 's/^ *\([0-9 |]*\)) exit 0 ;;$/\1/p' "$REPO_ROOT/src/cli/bin/nova-hw-laptop" | tr -d ' ')
  [ "$types" = "8|9|10|14|30|31|32" ]
}

@test "install: the rules go where udev reads them, and not among the profiles" {
  grep -q 'lib/udev/rules.d $(HARDWARE_SRC)/udev/\*.rules' "$REPO_ROOT/data/hardware/install.mk"
  grep -q "! -path 'udev/\*'" "$REPO_ROOT/data/hardware/install.mk"
}

#!/usr/bin/env bats

# nova dns Custom: which server addresses it takes, and what NetworkManager's
# ipv4.dns and ipv6.dns are given of them. The functions above the command
# handling, sourced on their own.

load ../test_helper

setup() {
  setup_scratch
  sed '/^usage() {/,$d' "$REPO_ROOT/src/cli/bin/nova-dns" >"$SCRATCH/dns.sh"
  # shellcheck source=/dev/null
  source "$SCRATCH/dns.sh"
}

teardown() { teardown_scratch; }

@test "servers resolved.conf takes are taken" {
  local server
  for server in 1.1.1.1 1.2.3.4:5353 1.1.1.1#cloudflare-dns.com dns+tls://9.9.9.9#dns.quad9.net \
    2606:4700:4700::1111 '[2001:db8::1]:5353' '[2620:fe::fe]:853#dns.quad9.net' :: ::1 \
    2001:db8:0:0:0:0:0:1 fe80::; do
    valid_server "$server" || { echo "refused $server"; return 1; }
  done
}

@test "anything else is refused before something is written" {
  local server
  for server in :::: 1.2.3.256 1.2.3 1.2.3.4:70000 '[2001:db8::1]:99999' 2001:db8::1::2 \
    12345::1 1:2:3:4:5:6:7:8:9 1:2:3 :1:2 '1.1.1.1#-bad' example.org '[1.2.3.4]' '2001:db8::1]:53' \
    192.168.01.1 010.1.1.1; do
    fails valid_server "$server" || { echo "took $server"; return 1; }
  done
}

@test "NetworkManager gets the addresses alone, each in its family" {
  split_dns_servers '1.2.3.4:5353,[2001:db8::1]:5353,dns+tls://9.9.9.9#dns.quad9.net,2620:fe::fe#dns.quad9.net,1.1.1.1'
  [ "$ipv4_dns" = '1.2.3.4 9.9.9.9 1.1.1.1' ]
  [ "$ipv6_dns" = '2001:db8::1 2620:fe::fe' ]
}

# Run the argument handling with authentication stopped at the boundary. Even
# a test run as root cannot reach the writes to /etc.
dns_command() {
  require_root() { printf '%s\n' "$@" >"$SCRATCH/auth-args"; exit 0; }
  set -- "$@"
  source <(sed -n '/^usage() {/,$p' "$REPO_ROOT/src/cli/bin/nova-dns")
}

@test "Custom servers reach polkit as separate validated arguments" {
  run dns_command Custom 192.0.2.1 2001:db8::1
  [ "$status" -eq 0 ]
  [ "$(cat "$SCRATCH/auth-args")" = $'Custom\n192.0.2.1\n2001:db8::1' ]
}

@test "Custom keeps the terminal prompt before authentication" {
  run dns_command Custom <<<'192.0.2.1, 2001:db8::1'
  [ "$status" -eq 0 ]
  [[ $output == *'Enter your DNS servers'* ]]
  [ "$(cat "$SCRATCH/auth-args")" = $'Custom\n192.0.2.1\n2001:db8::1' ]
}

@test "bad or too many DNS servers never ask for authentication" {
  run dns_command Custom 999.1.1.1
  [ "$status" -eq 1 ]
  [ ! -e "$SCRATCH/auth-args" ]
  run dns_command Custom 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9
  [ "$status" -eq 1 ]
  run dns_command Custom ::1 '::;touch /tmp/no'
  [ "$status" -eq 1 ]
  run dns_command Cloudflare 1.1.1.1
  [ "$status" -eq 1 ]
  run dns_command Custom <<<' '
  [ "$status" -eq 1 ]
  [ ! -e "$SCRATCH/auth-args" ]
}

@test "Custom uses the existing NetworkManager path for both address families" {
  mkdir -p "$SCRATCH/bin"
  cat >"$SCRATCH/bin/nmcli" <<'STUB'
#!/bin/bash
if [[ $* == '-t -f UUID,TYPE connection show' ]]; then
  printf 'wifi-id:802-11-wireless\nwired-id:802-3-ethernet\nvpn-id:vpn\n'
else
  printf '%s\n' "$*" >>"$SCRATCH/nmcli-log"
fi
STUB
  chmod +x "$SCRATCH/bin/nmcli"
  export PATH="$SCRATCH/bin:$PATH"
  split_dns_servers '192.0.2.1,2001:db8::1'
  set_connection_dns "$ipv4_dns" "$ipv6_dns"
  [ "$(wc -l <"$SCRATCH/nmcli-log")" -eq 2 ]
  [[ $(cat "$SCRATCH/nmcli-log") == *'ipv4.dns 192.0.2.1 ipv6.ignore-auto-dns yes ipv6.dns 2001:db8::1'* ]]
  [[ $(cat "$SCRATCH/nmcli-log") != *vpn-id* ]]
}

@test "the unprivileged command delegates once to the packaged DNS helper" {
  ((EUID != 0)) || skip 'the wrapper is an unprivileged entry point'
  mkdir -p "$SCRATCH/bin"
  cat >"$SCRATCH/bin/pkexec" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >"$SCRATCH/pkexec-args"
exit "${AUTH_STATUS:-0}"
STUB
  chmod +x "$SCRATCH/bin/pkexec"
  export PATH="$SCRATCH/bin:$PATH"
  run "$REPO_ROOT/src/cli/bin/nova-dns" Custom 192.0.2.1 ::1
  [ "$status" -eq 0 ]
  [ "$(cat "$SCRATCH/pkexec-args")" = $'/usr/lib/nova/bin/nova-dns\nCustom\n192.0.2.1\n::1' ]
  AUTH_STATUS=126 run "$REPO_ROOT/src/cli/bin/nova-dns" Custom ::1
  [ "$status" -eq 126 ]
}

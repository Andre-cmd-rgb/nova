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
    12345::1 1:2:3:4:5:6:7:8:9 1:2:3 :1:2 '1.1.1.1#-bad' example.org '[1.2.3.4]' '2001:db8::1]:53'; do
    fails valid_server "$server" || { echo "took $server"; return 1; }
  done
}

@test "NetworkManager gets the addresses alone, each in its family" {
  split_dns_servers '1.2.3.4:5353,[2001:db8::1]:5353,dns+tls://9.9.9.9#dns.quad9.net,2620:fe::fe#dns.quad9.net,1.1.1.1'
  [ "$ipv4_dns" = '1.2.3.4 9.9.9.9 1.1.1.1' ]
  [ "$ipv6_dns" = '2001:db8::1 2620:fe::fe' ]
}

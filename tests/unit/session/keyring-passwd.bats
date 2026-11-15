#!/usr/bin/env bats

# nova-keyring-passwd: passwd's PAM stack gets pam_gnome_keyring once, after
# shadow's own lines, so changing the password changes the login keyring's.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_PAM_PASSWD=$SCRATCH/passwd
  helper=$REPO_ROOT/data/session/bin/nova-keyring-passwd
}

teardown() { teardown_scratch; }

shadow_passwd() {
  write_file "$NOVA_PAM_PASSWD" '#%PAM-1.0
auth		include		system-auth
account		include		system-auth
password	include		system-auth
'
}

@test "shadow's passwd gets the keyring line last, and only once" {
  shadow_passwd
  "$helper"
  "$helper"
  [ "$(tail -n 1 "$NOVA_PAM_PASSWD")" = '-password  optional  pam_gnome_keyring.so' ]
  [ "$(grep -c pam_gnome_keyring "$NOVA_PAM_PASSWD")" -eq 1 ]
  [ "$(head -n 4 "$NOVA_PAM_PASSWD")" = "$(printf '#%%PAM-1.0\nauth\t\tinclude\t\tsystem-auth\naccount\t\tinclude\t\tsystem-auth\npassword\tinclude\t\tsystem-auth')" ]
}

@test "a keyring line written by hand is left as it is" {
  write_file "$NOVA_PAM_PASSWD" 'password	include		system-auth
password	optional	pam_gnome_keyring.so use_authtok
'
  cp "$NOVA_PAM_PASSWD" "$SCRATCH/before"
  "$helper"
  cmp "$SCRATCH/before" "$NOVA_PAM_PASSWD"
}

@test "no passwd stack, nothing to do" {
  run "$helper"
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_PAM_PASSWD" ]
}

@test "the hook runs it after any transaction with nova or shadow" {
  hook=$REPO_ROOT/data/session/hooks/50-nova-keyring-passwd.hook
  grep -qx 'Target = nova' "$hook"
  grep -qx 'Target = shadow' "$hook"
  grep -qx 'When = PostTransaction' "$hook"
  grep -qx 'Exec = /usr/lib/nova/bin/nova-keyring-passwd' "$hook"
}

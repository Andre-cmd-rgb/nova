#!/usr/bin/env bats

# data/session/bin/nova-keyring-migrate against a real gnome-keyring, on a D-Bus
# session of its own and a scratch home: a keyring stored
# without a password, moves into the password-encrypted login keyring.

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home
  export XDG_DATA_HOME=$HOME/.local/share XDG_STATE_HOME=$HOME/.local/state XDG_RUNTIME_DIR=$SCRATCH/run
  mkdir -p "$XDG_DATA_HOME/keyrings" "$XDG_STATE_HOME/nova"
  mkdir -m 700 "$XDG_RUNTIME_DIR"
  cat >"$SCRATCH/lookup.py" <<'EOF'
import dbus
bus = dbus.SessionBus()
service = dbus.Interface(bus.get_object("org.freedesktop.secrets", "/org/freedesktop/secrets"), "org.freedesktop.Secret.Service")
_, session = service.OpenSession("plain", dbus.String("", variant_level=1))
unlocked, _ = service.SearchItems({"application": "chrome"})
print("default:", service.ReadAlias("default"))
for path in unlocked:
    print("chrome:", path, bytes(service.GetSecrets([path], session)[path][2]).decode())
EOF
}

teardown() { teardown_scratch; }

# A keyring stored without a password: plain text, holding Chrome's key.
passwordless_keyring() {
  cat >"$XDG_DATA_HOME/keyrings/Default_keyring.keyring" <<'EOF'
[keyring]
display-name=Default keyring
ctime=0
mtime=0
lock-on-idle=false
lock-after=false

[1]
item-type=0
display-name=Chrome Safe Storage
secret=chrome-key
mtime=0
ctime=0

[1:attribute0]
name=application
type=string
value=chrome
EOF
  echo Default_keyring >"$XDG_DATA_HOME/keyrings/default"
}

# A session as the lock screen leaves it at the first unlock: the login keyring
# open with the password. Then the migration, and what an app finds after it.
first_unlock() {
  dbus-run-session -- bash -c '
    printf "a login password" | gnome-keyring-daemon --login >/dev/null 2>&1
    gnome-keyring-daemon --start --components=secrets >/dev/null 2>&1
    "$1" || exit
    python3 -I "$2"' _ "$REPO_ROOT/data/session/bin/nova-keyring-migrate" "$SCRATCH/lookup.py"
}

@test "the passwordless keyring, locked until asked, moves into the login keyring and is gone" {
  passwordless_keyring
  : >"$XDG_STATE_HOME/nova/keyring-migrate-pending"
  run first_unlock
  [ "$status" -eq 0 ]
  [[ $output == *"moved 1 secrets from 'Default_keyring' into login"* ]]
  [[ $output == *"default: /org/freedesktop/secrets/collection/login"* ]]
  [[ $output == *"chrome: /org/freedesktop/secrets/collection/login/"*" chrome-key"* ]]
  [ ! -e "$XDG_DATA_HOME/keyrings/Default_keyring.keyring" ]
  [ ! -e "$XDG_STATE_HOME/nova/keyring-migrate-pending" ]
}

@test "without the marker, the keyring is left as it is" {
  passwordless_keyring
  run first_unlock
  [ "$status" -eq 0 ]
  [[ $output != *moved* ]]
  [ -e "$XDG_DATA_HOME/keyrings/Default_keyring.keyring" ]
}

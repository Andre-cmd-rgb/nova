#!/usr/bin/env bats

# nova-printers: what Settings' Printers page and nova-sessiond's notices ask
# CUPS. CUPS's tools are stubs that log what they were given, one bracket to
# an argument; ipptool answers each operation with the property list in
# $SCRATCH/plist/<operation>, and keeps the test file it was given and the
# NOVA_* variables it ran with.

bats_require_minimum_version 1.5.0
load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls"
  export NOVA_PRINTERS_CUPS_FILES="$SCRATCH/cups-files.conf"
  export NOVA_PRINTERS_SERVER=ipp://test/
  mkdir -p "$SCRATCH/bin" "$SCRATCH/plist"
  local tool
  for tool in lpadmin cupsenable cupsdisable cupsaccept lp cancel lpoptions lpinfo; do
    stub "$tool" ''
  done
  quiet id 'echo "andre wheel"'
  quiet lpstat 'echo "system default destination: Office"'
  cat >"$SCRATCH/bin/ipptool" <<'EOF'
#!/bin/bash
request=${*: -1}
operation=$(sed -n 's/^ *OPERATION //p' "$request")
{ printf 'ipptool'; printf ' [%s]' "$@"; echo " $operation"; } >>"$CALLS"
cp "$request" "$SCRATCH/request-$operation.test"
env | grep -E '^NOVA_(PRINTER|JOB|USER|AUTH_USER|AUTH_PASSWORD|SUBSCRIPTION)=' | sort >"$SCRATCH/env-$operation" || true
if [[ -f $SCRATCH/plist/$operation ]]; then
  cat "$SCRATCH/plist/$operation"
else
  cat "$SCRATCH/plist/ok"
fi
EOF
  chmod +x "$SCRATCH/bin/ipptool"
  plist_ok >"$SCRATCH/plist/ok"
  export PATH="$SCRATCH/bin:$PATH"
  helper="$REPO_ROOT/src/cli/bin/nova-printers"
}

teardown() { teardown_scratch; }

# A tool that logs its arguments and then does <body>.
stub() { # name body
  cat >"$SCRATCH/bin/$1" <<EOF
#!/bin/bash
{ printf '%s' "\${0##*/}"; printf ' [%s]' "\$@"; echo; } >>"\$CALLS"
$2
EOF
  chmod +x "$SCRATCH/bin/$1"
}

# A tool the tests do not count: what it says, and no log.
quiet() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

calls() { cat "$CALLS" 2>/dev/null || true; }

# ipptool's property list: the operation's group, then <groups>, each a dict.
plist() { # operation status dict...
  local operation=$1 status=$2
  shift 2
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<plist version="1.0"><dict>'
    echo "<key>Tests</key><array><dict><key>Operation</key><string>$operation</string>"
    echo "<key>StatusCode</key><string>$status</string><key>ResponseAttributes</key><array>"
    echo '<dict><key>attributes-charset</key><string>utf-8</string></dict>'
    printf '%s\n' "$@"
    echo '</array></dict></array></dict></plist>'
  } | sed 's|><|>\n<|g' >"$SCRATCH/plist/$operation"
}
plist_ok() { echo '<plist version="1.0"><dict><key>Tests</key><array><dict><key>StatusCode</key><string>successful-ok</string></dict></array></dict></plist>' | sed 's/></>\n</g'; }

two_printers() {
  plist CUPS-Get-Printers successful-ok \
    '<dict><key>printer-name</key><string>Office</string><key>printer-info</key><string>Office laser</string>
     <key>printer-location</key><string>Hall</string><key>printer-make-and-model</key><string>Acme Laser 9</string>
     <key>printer-state</key><integer>4</integer>
     <key>printer-state-reasons</key><array><string>media-empty-error</string><string>toner-low-warning</string></array>
     <key>printer-is-accepting-jobs</key><true/><key>device-uri</key><string>ipp://acme.local/ipp/print</string>
     <key>queued-job-count</key><integer>2</integer></dict>' \
    '<dict><key>printer-name</key><string>Hall</string><key>printer-state</key><integer>3</integer>
     <key>printer-state-reasons</key><string>none</string><key>printer-is-accepting-jobs</key><true/></dict>'
  plist Get-Jobs successful-ok \
    '<dict><key>job-id</key><integer>11</integer><key>job-name</key><string>report.pdf</string><key>job-state</key><integer>5</integer>
     <key>job-state-reasons</key><string>job-printing</string><key>job-originating-user-name</key><string>ann</string></dict>' \
    '<dict><key>job-id</key><integer>12</integer><key>job-name</key><string>a&amp;b "x"	tab</string><key>job-state</key><integer>4</integer>
     <key>job-state-reasons</key><array><string>cups-held-for-authentication</string></array><key>job-originating-user-name</key><string>bob</string></dict>'
}

@test "list: each printer in plain data, the user's default, and whether they may administer" {
  two_printers
  run "$helper" list
  [ "$status" -eq 0 ]
  [ "$(jq -r '.printers | map(.name) | join(",")' <<<"$output")" = "Office,Hall" ]
  [ "$(jq -r '.default' <<<"$output")" = Office ]
  [ "$(jq -r '.admin.allowed' <<<"$output")" = true ]
  [ "$(jq -c '.printers[0].reasons' <<<"$output")" = '["media-empty-error","toner-low-warning"]' ]
  [ "$(jq -c '.printers[1].reasons' <<<"$output")" = '[]' ]
  [ "$(jq -r '.printers[0] | [.info, .location, .model, .uri, .state, .accepting] | join("|")' <<<"$output")" = 'Office laser|Hall|Acme Laser 9|ipp://acme.local/ipp/print|4|true' ]
  # Jobs are asked only of a printer that has any.
  [ "$(jq -r '.printers[0].jobs | length' <<<"$output")" -eq 2 ]
  [ "$(jq -r '.printers[1].jobs | length' <<<"$output")" -eq 0 ]
  [ "$(calls | grep -c 'Get-Jobs$')" -eq 1 ]
}

@test "a name or a document with quotes, ampersands and tabs is data and stays as it was" {
  two_printers
  run "$helper" list
  [ "$(jq -r '.printers[0].jobs[1].name' <<<"$output")" = $'a&b "x"\ttab' ]
}

@test "CUPS out of reach is said, with nothing on standard output" {
  rm "$SCRATCH/bin/ipptool"
  stub ipptool 'exit 1'
  run --separate-stderr "$helper" list
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ $stderr == *"CUPS cannot be reached"* ]]
}

@test "a printer's name that an option, a path or a space could come out of is refused before anything runs" {
  local bad
  for bad in -x 'a b' a/b 'a#b' '' $'a\nb'; do
    run "$helper" remove "$bad"
    [ "$status" -ne 0 ] || { echo "took '$bad'"; return 1; }
    run "$helper" detail "$bad"
    [ "$status" -ne 0 ] || { echo "took '$bad'"; return 1; }
  done
  [ -z "$(calls)" ]
}

@test "a name with shell and JSON syntax in it reaches CUPS as one argument" {
  local odd='a"$(touch${IFS}x)`id`;b'
  run "$helper" remove "$odd"
  [ "$status" -eq 0 ]
  [ "$(calls)" = "lpadmin [-x] [$odd]" ]
  [ ! -e x ]
}

@test "admin: the groups cups-files.conf names, or Arch's when it cannot be read" {
  run "$helper" admin
  [ "$(jq -c . <<<"$output")" = '{"allowed":true,"groups":["sys","root","wheel"]}' ]
  quiet id 'echo "andre audio"'
  run "$helper" admin
  [ "$(jq -r '.allowed' <<<"$output")" = false ]
  printf 'SystemGroup printadmin\nSystemGroup lp\n' >"$NOVA_PRINTERS_CUPS_FILES"
  quiet id 'echo "andre lp"'
  run "$helper" admin
  [ "$(jq -c . <<<"$output")" = '{"allowed":true,"groups":["printadmin","lp"]}' ]
}

@test "without the rights, adding, removing, pausing and looking for printers say so and run nothing" {
  [ "$EUID" -ne 0 ] || skip "root may"
  quiet id 'echo "andre audio"'
  local words
  for words in "add Office ipp://x/ everywhere" "remove Office" "pause Office" "resume Office" "discover" "drivers"; do
    # shellcheck disable=SC2086
    run --separate-stderr "$helper" $words
    [ "$status" -eq 1 ] || { echo "$words ran"; return 1; }
    [[ $stderr == *"not in CUPS's admin group (sys root wheel)"* ]]
  done
  [ -z "$(calls)" ]
}

@test "add: a queue for the device, with the driver, not shared with the network" {
  run "$helper" add Office 'dnssd://Acme%20Laser._ipp._tcp.local/?uuid=1' everywhere
  [ "$status" -eq 0 ]
  [ "$(calls)" = 'lpadmin [-p] [Office] [-E] [-v] [dnssd://Acme%20Laser._ipp._tcp.local/?uuid=1] [-m] [everywhere] [-o] [printer-is-shared=false]' ]
  : >"$CALLS"
  run "$helper" add Office 'not a uri' everywhere
  [ "$status" -eq 1 ]
  run "$helper" add Office usb://x/y -m
  [ "$status" -ne 0 ]
  [ -z "$(calls)" ]
}

@test "pause, resume, default, test page, cancel and the options are each CUPS's own command" {
  "$helper" pause Office
  "$helper" resume Office
  "$helper" default Office
  "$helper" test-page Office
  "$helper" cancel Office 12
  "$helper" option Office media iso_a4_210x297mm
  "$helper" option Office sides default
  "$helper" option Office color monochrome
  [ "$(calls | grep -v '^ipptool')" = "cupsdisable [-r] [Paused] [Office]
cupsenable [Office]
cupsaccept [Office]
lpoptions [-d] [Office]
lp [-d] [Office] [-t] [Test Page] [/usr/share/cups/data/testprint]
cancel [Office-12]
lpoptions [-p] [Office] [-o] [media=iso_a4_210x297mm]
lpoptions [-p] [Office] [-r] [sides]
lpoptions [-p] [Office] [-o] [print-color-mode=monochrome]" ]
}

@test "an option's value that is not a plain word, or a job that is not a number, is refused" {
  run "$helper" option Office media 'a b'
  [ "$status" -ne 0 ]
  run "$helper" option Office media '-o'
  [ "$status" -ne 0 ]
  run "$helper" option Office quality high
  [ "$status" -ne 0 ]
  run "$helper" cancel Office '1; true'
  [ "$status" -ne 0 ]
  [ -z "$(calls)" ]
}

@test "detail: inks as levels in their colours, what the printer takes, what the user chose, the jobs" {
  two_printers
  plist Get-Printer-Attributes successful-ok \
    '<dict><key>printer-name</key><string>Office</string>
     <key>marker-names</key><array><string>Black, toner</string><string>Cyan</string><string>Waste toner</string></array>
     <key>marker-levels</key><array><integer>80</integer><integer>5</integer><integer>10</integer></array>
     <key>marker-colors</key><array><string>#000000</string><string>#00FFFF</string><string>none</string></array>
     <key>marker-types</key><array><string>toner</string><string>toner</string><string>waste-toner</string></array>
     <key>media-supported</key><array><string>iso_a4_210x297mm</string><string>na_letter_8.5x11in</string></array>
     <key>media-default</key><string>iso_a4_210x297mm</string>
     <key>sides-supported</key><array><string>one-sided</string><string>two-sided-long-edge</string></array>
     <key>sides-default</key><string>one-sided</string>
     <key>print-color-mode-supported</key><array><string>color</string><string>monochrome</string></array>
     <key>print-color-mode-default</key><string>color</string></dict>'
  quiet lpoptions 'echo "copies=1 media=na_letter_8.5x11in print-color-mode=monochrome"'
  run "$helper" detail Office
  [ "$status" -eq 0 ]
  [ "$(jq -c '.markers' <<<"$output")" = '[{"name":"Black, toner","level":80,"type":"toner","color":"#000000"},{"name":"Cyan","level":5,"type":"toner","color":"#00FFFF"}]' ]
  [ "$(jq -c '.media' <<<"$output")" = '{"supported":["iso_a4_210x297mm","na_letter_8.5x11in"],"default":"iso_a4_210x297mm","mine":"na_letter_8.5x11in"}' ]
  [ "$(jq -r '.sides.mine, .color.mine' <<<"$output" | paste -sd,)" = ",monochrome" ]
  [ "$(jq -r '.jobs | length' <<<"$output")" -eq 2 ]
  # The printer's name is in the request as a variable, not as text.
  grep -q 'ipp://localhost/printers/\$ENV\[NOVA_PRINTER\]' "$SCRATCH/request-Get-Printer-Attributes.test"
  [ "$(cat "$SCRATCH/env-Get-Printer-Attributes")" = "NOVA_PRINTER=Office" ]
}

@test "discover: a device for each address, driverless where IPP does it, the generic backends left out" {
  stub lpinfo 'cat <<OUT
Device: uri = dnssd://Acme%20Laser._ipp._tcp.local/?uuid=1
        class = network
        info = Acme Laser 9
        make-and-model = Acme Laser 9
        device-id = MFG:Acme;MDL:Laser 9;CMD:PDF,URF;
        location =
Device: uri = socket
        class = network
        info = AppSocket/HP JetDirect
        make-and-model = Unknown
        device-id =
        location =
Device: uri = usb://Acme/Inkjet%20Z?serial=1
        class = direct
        info = Acme Inkjet Z
        make-and-model = Acme Inkjet Z
        device-id = MFG:Acme;MDL:Inkjet Z;
        location =
Device: uri = dnssd://Old._pdl-datastream._tcp.local/
        class = network
        info = Old
        make-and-model = Old
        device-id =
        location =
OUT'
  run "$helper" discover
  [ "$status" -eq 0 ]
  [ "$(jq -r '.devices | map(.uri) | join(" ")' <<<"$output")" = 'dnssd://Acme%20Laser._ipp._tcp.local/?uuid=1 usb://Acme/Inkjet%20Z?serial=1 dnssd://Old._pdl-datastream._tcp.local/' ]
  [ "$(jq -r '.devices | map(.driverless) | join(" ")' <<<"$output")" = 'true false false' ]
  [ "$(jq -r '.devices[1].model, .devices[1].deviceId' <<<"$output" | paste -sd'|')" = 'Acme Inkjet Z|MFG:Acme;MDL:Inkjet Z;' ]
}

@test "drivers: the list for a make and model, or all of them" {
  stub lpinfo 'printf "%s\n" "drv:///hpcups.drv/hp-laserjet_1020.ppd HP LaserJet 1020, hpcups 3.23" "everywhere IPP Everywhere"'
  run "$helper" drivers 'HP LaserJet 1020'
  [ "$status" -eq 0 ]
  [ "$(jq -c '.drivers' <<<"$output")" = '[{"id":"drv:///hpcups.drv/hp-laserjet_1020.ppd","name":"HP LaserJet 1020, hpcups 3.23"},{"id":"everywhere","name":"IPP Everywhere"}]' ]
  [ "$(calls)" = 'lpinfo [--make-and-model] [HP LaserJet 1020] [-m]' ]
  : >"$CALLS"
  "$helper" drivers >/dev/null
  [ "$(calls)" = 'lpinfo [-m]' ]
}

@test "authenticate: the user name and password come from stdin and reach ipptool's environment alone" {
  run "$helper" authenticate Office 12 <<<$'ann\np,"w$d\\x ;'
  [ "$status" -eq 0 ]
  # Neither in ipptool's arguments nor in the test file it is given.
  fails grep -qF 'w$d' "$CALLS"
  fails grep -qF 'ann' "$CALLS"
  fails grep -qF 'w$d' "$SCRATCH/request-CUPS-Authenticate-Job.test"
  grep -q 'ATTR text auth-info "\$ENV\[NOVA_AUTH_USER\]","\$ENV\[NOVA_AUTH_PASSWORD\]"' "$SCRATCH/request-CUPS-Authenticate-Job.test"
  grep -qxF 'NOVA_AUTH_PASSWORD=p,"w$d\x ;' "$SCRATCH/env-CUPS-Authenticate-Job"
  grep -qxF 'NOVA_AUTH_USER=ann' "$SCRATCH/env-CUPS-Authenticate-Job"
  grep -qxF 'NOVA_JOB=12' "$SCRATCH/env-CUPS-Authenticate-Job"
  grep -qxF 'NOVA_PRINTER=Office' "$SCRATCH/env-CUPS-Authenticate-Job"
}

@test "authenticate: a missing line, a refusal, and a job that is not a number are each an error" {
  run "$helper" authenticate Office 12 <<<"ann"
  [ "$status" -eq 1 ]
  run "$helper" authenticate Office x <<<$'ann\nsecret'
  [ "$status" -ne 0 ]
  [ -z "$(calls)" ]
  plist CUPS-Authenticate-Job client-error-not-authorized
  run --separate-stderr "$helper" authenticate Office 12 <<<$'ann\nwrong'
  [ "$status" -eq 1 ]
  [[ $stderr == *"did not accept it (client-error-not-authorized)"* ]]
}

@test "watch: a line for each printer the user has jobs on and each of those jobs" {
  two_printers
  run "$helper" watch ann
  [ "$status" -eq 0 ]
  [ "$output" = "printer	Office	4	media-empty-error,toner-low-warning	true
job	Office	11	5	job-printing	report.pdf" ]
  run "$helper" watch bob
  [ "$(printf '%s\n' "$output" | sed -n 1p | cut -f1,2,4)" = "printer	Office	media-empty-error,toner-low-warning" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p | cut -f1,3,5)" = "job	12	cups-held-for-authentication" ]
  # The tab in the document's name is a space, so a line stays whole.
  [ "$(printf '%s\n' "$output" | tail -1 | cut -f6)" = 'a&b "x" tab' ]
  run "$helper" watch carol
  [ -z "$output" ]
}

@test "subscribe: nothing while CUPS is not running, one subscription made, and that one renewed" {
  quiet systemctl 'exit 3'
  "$helper" subscribe
  [ -z "$(calls | grep '^ipptool')" ]
  quiet systemctl 'exit 0'
  plist Get-Subscriptions successful-ok
  "$helper" subscribe
  grep -q 'ATTR uri notify-recipient-uri dbus://' "$SCRATCH/request-Create-Printer-Subscriptions.test"
  : >"$CALLS"
  plist Get-Subscriptions successful-ok \
    '<dict><key>notify-subscription-id</key><integer>7</integer><key>notify-recipient-uri</key><string>dbus://</string></dict>'
  "$helper" subscribe
  [ "$(calls | grep '^ipptool' | sed 's/.* //')" = "Get-Subscriptions
Renew-Subscription" ]
  grep -qxF 'NOVA_SUBSCRIPTION=7' "$SCRATCH/env-Renew-Subscription"
}

# shellcheck shell=bash
# installer/install-packages.bash: where the packages come from (the stick,
# or the release's Arch snapshot and [nova] repository), that every one is
# there before the disk is erased, and pacstrap installing them.
# Sourced by nova-install, never run.

# --------------------------------------------------------- the release and repos

# A string value from release.toml: key = "value"
release_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\"[[:space:]]*\$/\\1/p" "$RELEASE_FILE" | awk 'NR == 1'
}

offline_repo_ready() {
  [[ -r $OFFLINE_REPO/nova-offline.db ]]
}

# Whether a package asked for at the questions is one the stick does not
# carry (Firefox): then the release's Arch snapshot, which the stick was made
# from, comes after the stick's repository, online. Set from stick_lacks.
ONLINE_TOO=0

# Whether pacman finds any of the packages, or what they need, missing from
# the stick's repository alone. Read from its database, as the account it
# runs as: nothing is installed.
stick_lacks() { # package...
  (($#)) || return 1
  local dir status=1
  dir=$(mktemp -d /tmp/nova-stick.XXXXXX)
  mkdir "$dir/sync"
  cp -- "$OFFLINE_REPO/nova-offline.db" "$dir/sync/nova-offline.db"
  printf '[options]\nArchitecture = auto\nSigLevel = Never\n\n[nova-offline]\nServer = file://%s\n' "$OFFLINE_REPO" >"$dir/pacman.conf"
  logged pacman --config "$dir/pacman.conf" --dbpath "$dir" --logfile /dev/null -Sp --print-format %n -- "$@" ||
    status=0
  rm -rf -- "$dir"
  return "$status"
}

# The pacman.conf pacstrap uses. Offline, one repository on the stick holds
# every package; online, the same repositories the installed system will use.
# With ONLINE_TOO, the stick's first, so that only what it lacks is
# downloaded, then the Arch snapshot: not the release's [nova], which may not
# be published while its stick is tested, and whose packages the stick has.
# A directory of hooks, when given, comes after pacman's own: a hook there of
# the same name as a package's replaces it, and one linked to /dev/null masks
# it.
pacstrap_conf() { # arch-date nova-repo [hook-directory]
  local arch_date=$1 nova_repo=$2 hooks=${3:-}
  cat <<EOF
[options]
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
ParallelDownloads = 5
EOF
  [[ -z $hooks ]] || printf 'HookDir = /etc/pacman.d/hooks/\nHookDir = %s/\n' "$hooks"
  if offline_repo_ready; then
    printf '\n[nova-offline]\nServer = file://%s\n' "$OFFLINE_REPO"
  else
    printf '\n[nova]\nSigLevel = Required\nServer = %s\n' "$nova_repo"
  fi
  if ! offline_repo_ready || ((ONLINE_TOO)); then
    local repo
    for repo in core extra multilib; do
      # shellcheck disable=SC2016 # $arch is pacman's to expand
      printf '\n[%s]\nServer = https://archive.archlinux.org/repos/%s/$repo/os/$arch\n' "$repo" "$arch_date"
    done
  fi
}

# Online, every package comes from the release's Arch snapshot and its own
# repository. Both are asked for their lists, and the whole set looked up in
# them, before the disk is erased: an outage of either, or a package neither
# has, stops the install with the disk as it was. The packages themselves are
# fetched after, onto the new disk (there is nowhere else with room for
# them), so a network that goes then leaves the install to be run again.
# Nothing is installed from this, so signatures are left to pacstrap. From the
# stick alone, nothing needs asking; with ONLINE_TOO, the stick and the
# snapshot are asked together.
packages_available() { # kernel profile arch_date nova_repo [package...]
  local kernel=$1 profile=$2 arch_date=$3 nova_repo=$4 dir status=0
  local -a packages
  offline_repo_ready && ((!ONLINE_TOO)) && return 0
  dir=$(mktemp -d /tmp/nova-preflight.XXXXXX)
  mkdir "$dir/db"
  pacstrap_conf "$arch_date" "$nova_repo" | sed 's/^SigLevel = .*/SigLevel = Never/' >"$dir/pacman.conf"
  mapfile -t packages < <(package_set "$kernel" "$profile" "${@:5}")
  logged pacman --config "$dir/pacman.conf" --dbpath "$dir/db" --logfile /dev/null -Sy &&
    logged pacman --config "$dir/pacman.conf" --dbpath "$dir/db" --logfile /dev/null -Sp --print-format %n "${packages[@]}" ||
    status=$?
  rm -rf -- "$dir"
  return "$status"
}

# Hooks of the packages' that pacstrap leaves to install_bootloader, which
# does what they do once, with everything in place. pacstrap runs pacman from
# the live system, which takes the new system's hooks under /usr but not its
# /etc/pacman.d/hooks, where limine-entry-tool replaces mkinitcpio's: so in
# pacstrap mkinitcpio's own runs, and builds a plain initramfs for each
# kernel, and copies each vmlinuz to /boot, that nothing boots and nothing
# updates again. Limine boots the UKIs that limine-update builds in
# install_bootloader, from /usr/lib/modules, and the installed system's
# kernel updates run limine-entry-tool's. Limine's own deploys Limine and
# adds its firmware entry, which limine-install does again there.
PACSTRAP_MASKED=(90-mkinitcpio-install.hook 80-limine-efi-deploy.hook)

install_packages() { # kernel profile arch_date nova_repo [package...]
  local kernel=$1 profile=$2 arch_date=$3 nova_repo=$4 conf hooks hook
  conf=$(mktemp /tmp/nova-pacstrap.XXXXXX.conf)
  hooks=$(mktemp -d /tmp/nova-pacstrap-hooks.XXXXXX)
  for hook in "${PACSTRAP_MASKED[@]}"; do ln -s /dev/null "$hooks/$hook"; done
  pacstrap_conf "$arch_date" "$nova_repo" "$hooks" >"$conf"
  say "Installing packages (this is the long part)"
  mapfile -t packages < <(package_set "$kernel" "$profile" "${@:5}")
  local from="the internet"
  ! offline_repo_ready || from="the stick"
  ((!ONLINE_TOO)) || from="the stick and the internet"
  info "${#packages[@]} packages, from $from"
  # pacstrap's lines go through pacstrap_feed: to the log, and as parts and
  # counts to the progress view, or without one to the terminal. The kernels'
  # boot check is skipped: Limine is not installed yet, and install_bootloader
  # checks once it is. So are snap-pac's snapshots: snapper has no
  # configuration until configure_snapper, and the first snapshot is the
  # installed system's.
  # A network that drops for a moment fails a download: pacstrap is run again,
  # up to three times in all, and what it fetched is in the target's package
  # cache already, so it carries on where it stopped.
  local status try
  for try in 1 2 3; do
    status=0
    printf '+ pacstrap -C %s -K %s %s\n' "$conf" "$TARGET" "${packages[*]}" >>"$LOG"
    NOVA_BOOT_CHECK=skip SNAP_PAC_SKIP=y pacstrap -C "$conf" -K "$TARGET" "${packages[@]}" 2>&1 | pacstrap_feed ||
      status=$?
    ((status != 0 && try < 3)) || break
    warn "pacstrap failed; trying again in $((try * 10)) seconds"
    sleep "$((try * 10))"
  done
  rm -rf -- "$conf" "$hooks"
  ((status == 0)) || die "pacstrap failed three times; the log is in $LOG. The disk is erased already: running the install again starts it over."
}

# pacstrap's output, line by line: into the log, onto the terminal (or, under
# the progress view, its parts and counts into the view), and the time of
# each of its parts into the log as steps of their own, from the lines pacman
# starts each with (it flushes its output after every one): the keyring and
# the package lists, fetching the packages (from the stick, or the internet),
# checking their signatures, unpacking them, and the hooks. Its output is
# not a terminal, so pacman draws no bars: it says "Packages (N)" once, then
# a line as each package downloads, as each is unpacked ("installing mesa..."),
# and as each hook runs ("( 5/36) Updating linux initcpios...").
pacstrap_feed() {
  local line part='Packages: keyring and lists' started next n=0 total=0 fetching=Downloading
  started=$(now_us)
  offline_repo_ready && ((!ONLINE_TOO)) && fetching="Reading from the stick"
  while IFS= read -r line; do
    printf '%s\n' "$line" >>"$LOG"
    ((PROGRESS)) || printf '%s\n' "$line" >&2
    next=''
    case $line in
      ':: Retrieving packages...'*) next='Packages: fetching' ;;
      'checking keyring...'*) next='Packages: checking signatures' ;;
      ':: Processing package changes...'*) next='Packages: unpacking' ;;
      ':: Running post-transaction hooks...'*) next='Packages: hooks' ;;
    esac
    if [[ -n $next && $next != "$part" ]]; then
      log_step "$part" "$started"
      part=$next started=$(now_us) n=0
      case $part in
        *fetching) progress_event part "$fetching" "$total" ;;
        *signatures) progress_event part "Checking signatures" ;;
        *unpacking) progress_event part Installing "$total" ;;
        *hooks) progress_event part "Running hooks" ;;
      esac
      continue
    fi
    ((PROGRESS)) || continue
    case $part:$line in
      *':Packages ('[0-9]*')'*)
        total=${line#Packages (}
        total=${total%%)*}
        ;;
      *fetching:*' downloading...')
        ((n < total)) && n=$((n + 1))
        line=${line% downloading...}
        progress_event count "$n" "$total" "${line# }"
        ;;
      *unpacking:'installing '*)
        n=$((n + 1))
        line=${line#installing }
        progress_event count "$n" "$total" "${line%...}"
        ;;
      *hooks:'('*'/'*') '*)
        if [[ $line =~ ^\(\ *([0-9]+)/([0-9]+)\)\ (.*)$ ]]; then
          progress_event count "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]%...}"
        fi
        ;;
    esac
  done
  log_step "$part" "$started"
}

# Releasing Nova

A release is a git tag (`v1.0.0-beta.1`), built by CI into a GitHub release
and a folder of Nova's package bucket. Nothing is built or published from a
laptop.

## What a release contains

A release lives in two places. The GitHub release holds what people download,
and `release.toml`, which `nova update` and `nova-usb` look for there:

| On the GitHub release | What reads it |
|---|---|
| `nova-<version>-x86_64.iso` and its `.sha256` | people, or `nova-usb`: the installer stick |
| `nova-usb` | people: makes the installer stick, with the ISO and whatever is carried |
| `nova-<version>-raspberry-pi-5.img.xz` and its `.sha256` | people: written to a Raspberry Pi 5's card, USB stick or NVMe drive |
| `release.toml` and its `.sig` | `nova update` and the installer: the version, the Arch Linux Archive date the release was built and tested against, the address of its `[nova]` repository, and for a Pi the day its Arch Linux ARM set was pinned and where that set's files are |

Everything else is in the `nova-packages` bucket on Cloudflare R2, in a folder
named after the tag, served at `https://nova-packages.piserver.stream/<tag>`:

| In the bucket | What reads it |
|---|---|
| `nova.db`, `nova.files` and their `.sig` | pacman: the signed `[nova]` repository |
| `*.pkg.tar.zst` and their `.sig` | pacman: `nova`, `nova-keyring`, `linux-nova`, `linux-nova-headers`, `nvidia-open-nova`, `limine-entry-tool`, `limine-snapper-sync`, `ttfx` |
| `packages.txt`, the ISO's `.sha256`, and their `.sig` | `nova-usb`: the packages an install can need, to put on the stick for an offline install, and the checksum it checks the ISO with |
| `nova-usb.sig`, the Pi image's `.sha256` and its `.sig` | people: the release notes link them |
| `release.toml` and its `.sig` | a copy |
| `aarch64/`: `nova.db`, `nova.files`, `nova-alarm.db`, their `.sig`, and Nova's aarch64 packages | a Raspberry Pi's pacman: its `[nova]` repository, and `[nova-alarm]`, the Arch Linux ARM packages the release pins |
| `aarch64/alarm/`: `core.db`, `extra.db`, `alarm.db`, `aur.db` | the release workflow: Arch Linux ARM's databases as the release was built against them, to build it again on (promote) |

Arch Linux ARM keeps no archive of older packages, so the files of the
packages a release pins for the Pi go to a folder every release shares,
`alarm/aarch64/`, each the first time a release pins it (`tools/alarm-pin`,
`tools/packages-upload --pool`). `nova-alarm.db` is Arch Linux ARM's own
entries for them, with each packager's signature in it, so a Pi checks every
package against archlinuxarm-keyring as it would from Arch Linux ARM itself,
and the list against Nova's key. Each signature is also in the pool, as the
package's `.sig`, written from that entry: pacman fetches a package's `.sig`
as a file even when its database holds the signature, and refuses the package
when there is none. Each file is named with A-Z a-z 0-9 . _ - only, as Nova's
own packages are: a URL can change other characters.

`release.toml` points pacman at the release's folder, and every system stays on
its release's packages and Arch snapshot until `nova update` moves it to the
next one. Since each release names its own folder, the bucket can move to
another address at any release: `tools/release-pin --packages`. Releases up to
1.0.0-beta.5 had everything on the GitHub release, and stay that way.

The publish job puts the files in the bucket first and reads each back from the
public address (`tools/packages-upload`), so a release never appears on GitHub
before its packages can be downloaded.

GitHub limits a release asset to 2 GiB, so the ISO installs over the network
rather than carrying every package (`nova usb` adds an offline copy to the
stick). `tools/repo-build` stops on a package file name a URL or the stick's FAT
would change (an epoch's `:`, a development build's `+`).

## Versions

Tags are `vMAJOR.MINOR.PATCH`, with an optional `-beta.N` or `-rc.N`. The
`nova` package turns the tag into its pkgver: `v1.0.0-beta.1` becomes
`1.0.0beta.1`, which pacman sorts before `1.0.0` (`vercmp 1.0.0beta.1 1.0.0`
is -1), so moving from a beta to the final release is an ordinary upgrade.

A tag with a `-` becomes a GitHub pre-release, which reaches testers and
nobody else (below).

## The signing key (once)

The `[nova]` repository and every package in it are signed, and pacman refuses
anything else (`SigLevel = Required` in `installer/pacman.conf`). The files
read without pacman are signed with the same key: `nova update`
refuses a `release.toml` without a good `.sig`, and `nova-usb` checks
`release.toml`, `packages.txt` and the ISO's `.sha256` before it downloads the
ISO. The public key ships in the `nova-keyring` package, and `tools/inline-ui`
writes it into the `nova-usb` on the release page, which runs on systems
without it; the private key lives only in the `NOVA_REPO_KEY` repository
secret and in an offline backup.

1. Make a key used for nothing else. It has no passphrase, because CI signs
   unattended, so it never lives on a laptop's normal keyring:

   ```sh
   export GNUPGHOME=$(mktemp -d)
   gpg --quick-gen-key 'Nova repository <nova@users.noreply.github.com>' ed25519 sign 3y
   gpg --list-secret-keys --with-colons | awk -F: '$1 == "fpr" { print $10; exit }'
   ```

2. Write `packaging/nova-keyring` from it, and commit the three files:

   ```sh
   tools/keyring-export <fingerprint>
   ```

3. Store the private key as the secret, and keep one offline copy (an
   encrypted USB stick, not the cloud):

   ```sh
   gpg --armor --export-secret-keys <fingerprint> | gh secret set NOVA_REPO_KEY
   gpg --armor --export-secret-keys <fingerprint> > /media/backup/nova-repo-key.asc
   rm -rf "$GNUPGHOME"
   ```

The release workflow checks that the secret's key is the one in
`nova-keyring/nova-trusted`, so a mismatch fails before anything is signed.

**Replacing the key** (expiry, or a leak): pacman checks every signature
before any package's install script runs, so a system has to trust the new key
before it sees anything signed with it. That takes a transition release:

1. Make the new key. Append its public key to `nova.gpg` and its
   `FINGERPRINT:4:` line to `nova-trusted`, and release, still signing with
   the **old** key. Systems that update now trust both.
2. In a later release, run `tools/keyring-export <new> <old>`, which trusts
   only the new key and lists the old one in `nova-revoked`, put the new key in
   `NOVA_REPO_KEY`, and release.

A system that skipped the transition release fails to verify the next update.
Installing the transition release's `nova-keyring`, which the old key signed,
fixes it: `sudo pacman -U <its URL on the transition release>`, then
`nova update`. After a leak, revoke at once instead and say so in the release
notes, since a leaked key must not stay trusted for a transition.

## The package bucket (once)

The packages are public and signed, so the bucket only has to serve them; it
holds nothing secret.

1. In the Cloudflare dashboard, turn on R2 and create the bucket
   `nova-packages`, storage class Standard (the free tier covers only that).
2. In the bucket's settings, connect a custom domain from the same Cloudflare
   account (`nova-packages.piserver.stream`). Leave the `r2.dev` address off:
   it is rate-limited and not meant for real downloads. A different address
   means changing the default in `tools/release-pin`.
3. Create an Account API token for R2: Object Read & Write, on
   `nova-packages` only. Store its two halves as repository secrets, and the
   account ID (on the R2 overview page) as a repository variable:

   ```sh
   gh secret set R2_ACCESS_KEY_ID
   gh secret set R2_SECRET_ACCESS_KEY
   gh variable set R2_ACCOUNT_ID --body <account id>
   ```

A release adds about 280 MiB to the bucket for PCs (the ISO and the Pi image
stay on GitHub), and for the Pi its aarch64 packages and whatever Arch Linux
ARM changed since the release before, a few hundred MiB; the first release
with a Pi build fills the pool, about 1 GiB. R2's free 10 GB lasts most of a
year of releases; past that, storage costs $0.015 per GB a month, and
downloads are free.

## A release twice a month

Nova follows Arch two weeks behind, tested: each release is a candidate first.

1. **Candidate.** On the 1st and the 15th, `candidate.yml` runs CI on `main`,
   tags the commit it tested as the next candidate (`tools/release-next`:
   `v1.0.0-beta.N` before 1.0, then `vX.Y.0-rc.N`), and calls `release.yml`,
   which:
   1. pins yesterday's Arch Linux Archive snapshot (`tools/release-pin --verify`);
   2. builds `linux-nova` against it, or reuses the build cached by the hash of
      `packaging/linux-nova` (an uncached build takes a few hours);
   3. builds the other packages on the same snapshot, `nvidia-open-nova` at the
      snapshot's driver version;
   4. signs them into the repository (`tools/repo-build`);
   5. builds the ISO (`tools/build-iso`), and signs `release.toml`, the
      ISO's `.sha256`, `packages.txt` and `nova-usb` with the repository key;
   6. installs from it in a KVM virtual machine with no questions asked, boots
      the result and checks it from inside (`tests/install/run`); the serial
      logs are kept as the run's `install-logs`. Beside it, `upgrade-test`
      installs the release before this one and moves it forward and back
      (below);
   7. for the Raspberry Pi 5, on arm64 runners in Arch Linux ARM
      (`tools/alarm-container`): builds `nova`, `nova-keyring`, `ttfx` and
      `mise` against Arch Linux ARM's databases as the first step fetched
      them, signs them into the aarch64 repository, pins the Arch Linux ARM
      packages a Pi installs (`tools/alarm-pin`), and builds the image from
      those two repositories alone (`tools/build-pi-image`), which checks its
      boot partition and its packages' files;
   8. publishes it all as a pre-release, which only testers are offered:
      systems with Settings → Updates → Test Release Candidates on
      (`nova update --candidates on`), and those already on a candidate.

   Actions → candidate → Run cuts one at any other time; the first one needs
   the signing key (above) and takes a few hours more, for the kernel. A run
   that fails on something passing (a flaky download, say) can have its failed
   jobs re-run; one that fails on a bug is cancelled, its tag deleted
   (`git push origin :refs/tags/<tag>`), and the next run reuses the number.
   Once a release is published its files are never replaced: a re-run only
   sets its flags again, and a draft alone gets the re-run's files.
2. **Test.** CI has already installed and booted it in a virtual machine; what
   is left is the hardware: the ThinkPad P1 Gen 4i and the Raspberry Pi 5,
   the two the README supports. On each, following pre-releases, `nova
   update`, reboot, and work through the checklist below; now and then,
   install the ISO on a spare disk too. A candidate that fails is simply not
   promoted: fix `main`, and the next candidate replaces it.
3. **Approve,** within a week of the candidate: Actions → promote → Run, from
   the candidate's tag (Use workflow from: Tags) and with it as the input, or
   `gh workflow run promote.yml --ref <tag> -f candidate=<tag>`. It tags the
   same commit with the final version (`v1.1.0-rc.2` becomes `v1.1.0`), builds
   it again on the candidate's own Arch snapshot and Arch Linux ARM set, and
   publishes it as the latest release. Systems pick it up at their next update
   check. A promote that failed after tagging runs again with the same input:
   it takes the final tag as it is, on the candidate's commit. Only the
   newest published candidate of a version can be promoted: testers on a later
   one have a later Arch snapshot, which `nova update` never moves back from.

   From its tag, because promote reads `release.yml` from where it runs and
   every tool from the candidate's commit; from `main` it refuses once the
   workflows there have changed. Within a week, because Arch Linux ARM's
   mirrors drop old packages within days, and the Raspberry Pi build runs on
   the ones the candidate's containers installed, which CI keeps for a week
   unused (`tools/ci-setup --cache`). Past that, promote refuses before it
   tags anything, and the next candidate is the one to promote. A candidate
   due on the 1st or the 15th waits while promote runs, and after it is the
   next version's first (`v1.1.0-rc.1`).

### The hardware checklist

What no virtual machine can check. A line that fails is a bug to fix before
approving, or one to write down in the release notes.

- **Boot:** firmware logo to the lock screen with no console text in between;
  `systemd-analyze` no slower than the last release; a key in the first second
  shows the boot menu with snapshots, and the one from before the update starts
  and offers **Restore now** (leave it: the next restart is back on the
  update).
- **Unlock:** a wrong password is refused; the right one signs Chrome in with
  no keyring prompt; after that, the fingerprint unlocks, after suspend too.
- **Sleep:** the lid suspends and the machine wakes to the lock screen;
  `systemctl hibernate` on AC resumes to the session.
- **Power:** unplugged, the profile goes to power-saver and `nova power gpu
  status` says off (P1 Gen 4i); plugged in, both come back. *Always Off* in
  Settings keeps the card off. `nova battery limit` reads back what was set.
  On battery at idle, `src/power/test/watts.sh 300` is no worse than last time.
- **Graphics:** native resolution and refresh rate (165 Hz with VRR on the
  Legion); `chrome://gpu` shows hardware video decode; a game runs on the
  NVIDIA card (`nova power run` on the P1, `prime-run` on the Legion).
- **Sound:** speakers (`nova audio tuning status` on the P1), the microphone,
  headphones, a Bluetooth headset; the volume and brightness keys show the OSD.
- **Network:** Wi-Fi, Bluetooth pairing, mobile data where there is a SIM.
- **Desktop:** the keyboard layout, at the lock screen and at the greeter
  after a logout too; the touchpad and keyboard backlight; Chrome,
  VS Code, Nautilus, foot, Claude Code and Codex start; a theme change reaches
  every surface; `nova doctor` finds nothing.

On the Raspberry Pi 5, from its image on a spare card or stick:

- **First start:** the setup's screens fit the screen; the keyboard layout
  holds at the setup's own password prompts; Wi-Fi joins with its password;
  the time zone's country is on `/boot/cmdline.txt`; the Pi restarts into the
  lock screen with Chrome, VS Code, Claude Code and Codex there; pulling the
  power during the questions asks them again at the next start.
- **Updating:** `nova update` from the release before moves both `[nova]` and
  `[nova-alarm]`, and `nova doctor` finds nothing after a restart.
- **Desktop:** the screen's resolution, its brightness from Settings (DDC), sound
  over HDMI, Bluetooth, and the menu without Suspend.

The kernel moves only when `packaging/linux-nova` is updated
([packaging.md](packaging.md)); everything else follows the snapshot.

Pushing a tag by hand (`git tag -s v1.0.1 -m 'Nova 1.0.1' && git push origin
v1.0.1`) builds the same way but leaves a draft, for a fix between candidates.

### Withdrawing a broken release

A release that turns out broken is never deleted, and its files stay in the
bucket, because systems may already be on it. Instead:

1. **Stop offering it:** `gh release edit <tag> --draft=true`. Drafts are in
   no list `nova update` reads, so no other system moves to it; for a final
   release, `/releases/latest` falls back to the one before. Note it in the
   tag's release notes before, so the reason stays with it.
2. **Move the systems on it:** `nova update` never goes back to an older Arch
   snapshot unasked, so systems already on it stay there until a newer
   release. Cut the fix as the next candidate, from `main`, at once rather
   than at the next 1st or 15th; for a final release, a fixed version tagged
   by hand (above), its draft published once tested.
3. **Until then**, on each system: boot the snapshot from before the update
   and restore it (README, Going back), or
   `nova update --version <the release before> --allow-downgrade`.

### The upgrade test

Before anything is published, CI installs the release before this one and
takes it forward and back (`tests/install/run --upgrade`, the `upgrade-test`
job), in four starts of one virtual machine:

1. It installs the newest published release older than this one, candidates
   included, from that release's own ISO and packages, each checked against
   Nova's key by `nova-usb`'s own code. With none older, it passes with a
   notice.
2. That system's own `nova update` moves it to this release. After a restart,
   the version, the pins, the boot entries, the desktop and `nova doctor` are
   checked.
3. This release's `nova update --allow-downgrade` takes it back, and after a
   restart the older release is checked again.
4. The snapshot `nova update` took before step 2 replaces the root, as
   `limine-snapper-restore` does. After a restart, the older version, every
   one of its packages and its pins are back, byte for byte.

This release's `[nova]` repository is not published yet, so the guest reads
it from the runner, at QEMU's address for the host, over HTTPS with a
certificate from a CA made for the run and trusted by that guest alone, and
through the `--release-file` option `nova update` already has. pacman checks
every signature as it always does, and nothing in `nova update` or its root
helper changes for the test. Choosing the snapshot in the boot menu, its
overlay and the notification's **Restore now** are not in it: those are on
the hardware checklist. The serial logs are kept as the run's
`upgrade-logs`.

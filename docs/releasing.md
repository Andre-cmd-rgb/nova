# Releasing Nova

A release is a git tag (`v1.0.0-beta.1`), built by CI into a GitHub release and a folder of Nova's package bucket. Nothing is built or published from a laptop.

This page covers what a release contains, versions, the signing key and the package bucket (each set up once), the release twice a month with its hardware checklist, withdrawing a broken release, removing old ones, and the upgrade test.

## What a release contains

A release lives in two places. The GitHub release holds its notes, `nova-usb`, and `release.toml`, which `nova update` and `nova-usb` look for there:

| On the GitHub release | What reads it |
|---|---|
| `nova-usb` | people: makes the installer stick, with the ISO and whatever is carried |
| the ISO's `.sha256` | people who write the ISO to a stick themselves |
| `release.toml` and its `.sig` | `nova update` and the installer: the version, the Arch Linux Archive date the release was built and tested against, and the address of its `[nova]` repository |

Everything else is in the `nova-packages` bucket on Cloudflare R2, in a folder named after the tag, served at `https://nova-packages.piserver.stream/<tag>`:

| In the bucket | What reads it |
|---|---|
| `nova.db`, `nova.files` and their `.sig` | pacman: the signed `[nova]` repository |
| `*.pkg.tar.zst` and their `.sig` | pacman: `nova`, `nova-keyring`, `linux-nova`, `linux-nova-headers`, `nvidia-open-nova`, `limine-entry-tool`, `limine-snapper-sync`, `cmatrix`, `whisper-cpp`, `supernova`, `hyprland` |
| `nova-<version>-x86_64.iso`, its `.sha256`, and the `.sha256`'s `.sig` | people, and `nova-usb`: the installer, with every package an install can need, and the checksum it checks the ISO with |
| `nova-usb.sig` | people: the release notes link it |
| `release.toml` and its `.sig` | a copy |

- **Every system stays on its release.** `release.toml` points pacman at the release's folder, and every system stays on its release's packages and Arch snapshot until `nova update` moves it to the next one.
- **The bucket keeps the newest releases alone.** Once a release is published, the folders of the releases before it go, ISOs and all, but for the newest final release's ([below](#removing-old-releases)). A system on an older release has its packages installed already, and `nova update` needs only the newest folder to move it on.
- **The bucket can move.** Since each release names its own folder, the bucket can move to another address at any release: `tools/release-pin --packages`.
- **Packages first, then the release.** The publish job puts the files in the bucket first and reads each back from the public address (`tools/packages-upload`), so a release never appears on GitHub before its packages can be downloaded.
- **The ISO carries every package.** `tools/build-iso` puts every package any install can need on it, as the `[nova-offline]` repository in `nova/repo` (`tools/offline-repo`), so every stick installs without internet, a stick of an older release too. That makes it about 3 GB, more than GitHub takes a release file (2 GiB): it is in the bucket, beside the packages it carries.
- **File names:** `tools/repo-build` stops on a package file name a URL or the stick's FAT would change (an epoch's `:`, a development build's `+`).

## Versions

Tags are `vMAJOR.MINOR.PATCH`, with an optional `-beta.N` or `-rc.N`.

- **The pkgver:** the `nova` package turns the tag into its pkgver. `v1.0.0-beta.1` becomes `1.0.0beta.1`, which pacman sorts before `1.0.0` (`vercmp 1.0.0beta.1 1.0.0` is -1), so moving from a beta to the final release is an ordinary upgrade.
- **Pre-releases:** a tag with a `-` becomes a GitHub pre-release, which reaches testers and nobody else ([below](#a-release-twice-a-month)).

After a final release:

- **The next is a patch version**: v1.0.0, then v1.0.1, the fortnight's fixes and Arch's updates.
- **New features make a minor version** (v1.1.0), and a major one is for what breaks how Nova is used: Actions → candidate → Run with *minor* or *major*, or `gh workflow run candidate.yml -f version=minor`.
- **A version once started** is continued by every candidate after it, the scheduled ones too, until it is final. A patch candidate still open when a minor one starts is left behind, never promoted.

## The signing key (once)

**Everything a system installs or reads is signed with one key.**

- The `[nova]` repository and every package in it are signed, and pacman refuses anything else (`SigLevel = Required` in `installer/pacman.conf`).
- The files read without pacman are signed with the same key: `nova update` refuses a `release.toml` without a good `.sig`, and `nova-usb` checks `release.toml` and the ISO's `.sha256` before it downloads the ISO.
- The public key ships in the `nova-keyring` package, and `tools/inline-ui` writes it into the `nova-usb` on the release page, which runs on systems without it.
- The private key lives only in the `NOVA_REPO_KEY` repository secret and in an offline backup.

### Making it

1. Make a key used for nothing else. It has no passphrase, because CI signs unattended, so it never lives on a laptop's normal keyring:

   ```sh
   export GNUPGHOME=$(mktemp -d)
   gpg --quick-gen-key 'Nova repository <nova@users.noreply.github.com>' ed25519 sign 3y
   gpg --list-secret-keys --with-colons | awk -F: '$1 == "fpr" { print $10; exit }'
   ```

2. Write `packaging/nova-keyring` from it, and commit the three files:

   ```sh
   tools/keyring-export <fingerprint>
   ```

3. Store the private key as the secret, and keep one offline copy (an encrypted USB stick, not the cloud):

   ```sh
   gpg --armor --export-secret-keys <fingerprint> | gh secret set NOVA_REPO_KEY
   gpg --armor --export-secret-keys <fingerprint> > /media/backup/nova-repo-key.asc
   rm -rf "$GNUPGHOME"
   ```

The release workflow checks that the secret's key is the one in `nova-keyring/nova-trusted`, so a mismatch fails before anything is signed.

### Replacing the key

**Replacing the key (expiry, or a leak) takes a transition release.** pacman checks every signature before any package's install script runs, so a system has to trust the new key before it sees anything signed with it.

**CI says when.** The key is made to last three years. From 180 days before it expires, CI's check job fails (`tools/keyring-check`, at every push and every candidate) until `nova-keyring` holds a trusted key with longer to go, which step 1 puts there. Once the key has expired, pacman refuses everything it signed.

1. Make the new key. Append its public key to `nova.gpg` and its `FINGERPRINT:4:` line to `nova-trusted`, and release, still signing with the **old** key. Systems that update now trust both.
2. In a later release, run `tools/keyring-export <new> <old>`, which trusts only the new key and lists the old one in `nova-revoked`, put the new key in `NOVA_REPO_KEY`, and release.

- **A system that skipped the transition release** fails to verify the next update. Installing the transition release's `nova-keyring`, which the old key signed, fixes it: `sudo pacman -U <its URL on the transition release>`, then `nova update`.
- **After a leak**, revoke at once instead and say so in the release notes, since a leaked key must not stay trusted for a transition.

## The package bucket (once)

The packages are public and signed, so the bucket only has to serve them; it holds nothing secret.

1. In the Cloudflare dashboard, turn on R2 and create the bucket `nova-packages`, storage class Standard (the free tier covers only that).
2. In the bucket's settings, connect a custom domain from the same Cloudflare account (`nova-packages.piserver.stream`). Leave the `r2.dev` address off: it is rate-limited and not meant for real downloads. A different address means changing the default in `tools/release-pin`.
3. Create an Account API token for R2: Object Read & Write, on `nova-packages` only. Store its two halves as repository secrets, and the account ID (on the R2 overview page) as a repository variable:

   ```sh
   gh secret set R2_ACCESS_KEY_ID
   gh secret set R2_SECRET_ACCESS_KEY
   gh variable set R2_ACCOUNT_ID --body <account id>
   ```

A release takes about 3.3 GB of the bucket, 3 GB of it the ISO, and the bucket keeps the newest release and the newest final one ([below](#removing-old-releases)): 7 GB at most, within R2's free 10 GB. Past that, storage costs $0.015 per GB a month, and downloads are free.

## A release twice a month

Nova follows Arch two weeks behind, tested: each release is a candidate first.

### 1. Candidate

On the 1st and the 15th, `candidate.yml` runs CI on `main`, tags the commit it tested as the next candidate (`tools/release-next`: `v1.0.0-rc.1` with no release yet, then the next `-rc.N`, and after a final release the next patch version's `-rc.1`), and calls `release.yml`, which:

1. pins yesterday's Arch Linux Archive snapshot (`tools/release-pin --verify`);
2. builds `linux-nova` against it, or reuses the build cached by the hash of `packaging/linux-nova` (an uncached build takes a few hours; `kernel-cache.yml` reads the cache every third day, since GitHub drops one nothing has read for a week);
3. builds the other packages on the same snapshot, in five jobs side by side (`nova` with the three it depends on, `whisper-cpp`, `supernova`, `hyprland` while the snapshot's Hyprland is the version Nova's patch is for, and `nvidia-open-nova` at the snapshot's driver version), and meanwhile fetches Arch's packages for the ISO and the upgrade test, once for both (`tools/arch-packages`);
4. signs them into the repository (`tools/repo-build`);
5. builds the ISO (`tools/build-iso`), with every package an install can need on it, and signs `release.toml`, the ISO's `.sha256` and `nova-usb` with the repository key;
6. installs from it in a KVM virtual machine with no questions asked, boots the result and checks it from inside (`tests/install/run`), three times: onto a plain disk and an encrypted one on virtio, and onto a plain one on NVMe; the serial logs are kept as the run's `install-logs`. Beside it, `upgrade-test` installs the release before this one and moves it forward and back ([below](#the-upgrade-test));
7. publishes it all as a pre-release, which only testers are offered: systems with Settings → Updates → Test release candidates on (`nova update --candidates on`), and those already on a candidate; then removes the releases before it from the bucket.

The release's notes say what changed (`tools/release-notes`): the commits since the release before it whose subjects are a `feat`, a `fix` or a `perf`, each under its part of Nova, and a link to every commit. A candidate is compared with the tag before it, a final release with the final one before it. So a commit's subject is written for the person reading the notes: what Nova now does, not what the code was changed to.

Cutting one at another time, and when a run fails:

- **Nothing is built twice:** every build but `nova`'s own is kept under its snapshot and the files it is made from, so a run started again, and a promote, take the packages as they were built.
- **Actions → candidate → Run** cuts one at any other time. The first one needs the [signing key](#the-signing-key-once) and takes a few hours more, for the kernel.
- **A run that fails on something passing** (a flaky download, say) can have its failed jobs re-run.
- **One that fails on a bug** is cancelled, its tag deleted (`git push origin :refs/tags/<tag>`), and the next run reuses the number.
- **Once a release is published its files are never replaced:** a re-run only sets its flags again, and a draft alone gets the re-run's files.

### 2. Test

CI has already installed and booted it in a virtual machine. What is left is the hardware: the ThinkPad P1 Gen 4i, the machine Nova is tuned for.

1. On it, following pre-releases, run `nova update` and reboot.
2. Work through the [hardware checklist](#the-hardware-checklist).
3. Now and then, install the ISO on a spare disk too.

A candidate that fails is not promoted: fix `main`, and the next candidate replaces it.

### 3. Approve

Actions → promote → Run, from the candidate's tag (Use workflow from: Tags) and with it as the input, or:

```sh
gh workflow run promote.yml --ref <tag> -f candidate=<tag>
```

- It tags the same commit with the final version (`v1.1.0-rc.2` becomes `v1.1.0`), builds it again on the candidate's own Arch snapshot, and publishes it as the latest release. Systems pick it up at their next update check.
- Only `nova` is really built again, for its version: the other packages are the candidate's own builds, which GitHub keeps for a week after they were last read (after that, they are built again too, from the same sources). The kernel's are kept longer: `kernel-cache.yml` reads them every three days.
- A promote that failed after tagging runs again with the same input: it takes the final tag as it is, on the candidate's commit.
- Only the newest published candidate of a version can be promoted: testers on a later one have a later Arch snapshot, which `nova update` never moves back from.
- It runs from its tag because promote reads `release.yml` from where it runs, and every tool from the candidate's commit; from `main` it refuses once the workflows there have changed.
- A candidate due on the 1st or the 15th waits while promote runs, and after it is the next version's first (`v1.0.1-rc.1`).

### The hardware checklist

What no virtual machine can check. A line that fails is a bug to fix before approving, or one to write down in the release notes.

- **Boot:** firmware logo to the lock screen with no console text in between; `systemd-analyze` no slower than the last release; a key in the first second shows the boot menu with snapshots, and the one from before the update starts and offers **Restore now** (leave it: the next restart is back on the update).
- **Unlock:** a wrong password is refused; the right one signs Chrome in with no keyring prompt; after that, the fingerprint unlocks, after suspend too.
- **Sleep:** the lid suspends and the machine wakes to the lock screen; `systemctl hibernate` on AC resumes to the session.
- **Power:** unplugged, the profile goes to the battery's mode (balanced unless one was chosen) and `nova power gpu status` says off; plugged in, it is performance and the card comes back. *Always Off* in Settings keeps the card off. `nova battery limit` reads back what was set. On battery at idle, `src/power/test/watts.sh 300` is no worse than last time.
- **Graphics:** native resolution and refresh rate; `chrome://gpu` shows hardware video decode; a game runs on the NVIDIA card with `nova power run`.
- **Sound:** speakers (`nova audio tuning status`), the microphone, headphones, a Bluetooth headset; the volume and brightness keys show the OSD.
- **Network:** Wi-Fi, Bluetooth pairing, mobile data where there is a SIM.
- **Desktop:** the keyboard layout, at the lock screen and at the greeter after a logout too; the touchpad and keyboard backlight; Chrome, VS Code, Nautilus, foot, Claude Code and Codex start; a theme change reaches every surface; `nova doctor` finds nothing.

The kernel moves only when `packaging/linux-nova` is updated ([packaging.md](packaging.md#updating-the-kernel)); everything else follows the snapshot.

Pushing a tag by hand (`git tag -s v1.0.1 -m 'Nova 1.0.1' && git push origin v1.0.1`) builds the same way but leaves a draft, for a fix between candidates.

### Withdrawing a broken release

A release that turns out broken is never deleted, and its files stay in the bucket, because systems may already be on it. Instead:

1. **Stop offering it:** `gh release edit <tag> --draft=true`. Drafts are in no list `nova update` reads, so no other system moves to it; for a final release, `/releases/latest` falls back to the one before. Note it in the tag's release notes before, so the reason stays with it. The candidate before has no folder in the bucket any more ([below](#removing-old-releases)), so `nova-usb`, falling back to it, finds no ISO until the fix is out, unless it is the newest final release: one more reason to cut the fix at once.
2. **Move the systems on it:** `nova update` never goes back to an older Arch snapshot unasked, so systems already on it stay there until a newer release. Cut the fix as the next candidate, from `main`, at once rather than at the next 1st or 15th; for a final release, a fixed version tagged by hand (above), its draft published once tested.
3. **Until then**, on each system: boot the snapshot from before the update and restore it ([going back](updates.md#going-back-to-before-an-update)).

### Removing old releases

The bucket keeps the newest releases alone, to keep what it costs to the least: once a release is published, `release.yml` removes the folder of every release before it, ISO and all (`tools/packages-prune --older-than <tag> --delete`), but for the newest final release's, which systems that take no candidates are on until the next final one (`--keep`). Folders of releases newer than it, which a build beside it may be filling, stay.

- **A system on an older release** reads nothing new from its folder: its packages are installed, and `nova update` moves it on with the newest folder alone. Until then, `pacman -Sy` finds no `[nova]` database.
- **A stick of an older release** still installs: its ISO carries every package. The new system's first `nova update` moves it to the newest.
- **Going back a whole release** is to a snapshot: the root snapshot `nova update` takes before it changes anything is on the computer's own disk. `nova update --version <tag> --allow-downgrade` to a release whose folder is gone says so and changes nothing.
- **The upgrade test** installs the release before the one being built, which is the newest published, and so still there. A release run again once a newer one is out finds it gone, and passes that test with a notice.

By hand, for a folder no release removed:

1. **The packages:** Actions → prune → Run, with the releases to keep (`gh workflow run prune.yml -f keep='v1.0.0 v1.0.1-rc.1'`). It lists what would go, by folder and size, and removes nothing; with *delete* ticked (`-f delete=true`) it removes it, and reads the bucket again to see that only the kept releases' own files are left (`tools/packages-prune`). It runs there because the bucket's token lives only in the repository's secrets.
2. **The release on GitHub:** `gh release delete <tag> --yes`, and its tag with `git push origin :refs/tags/<tag>`.

- **Keep the newest release's tag.** The next candidate's number comes from the tags there are (`tools/release-next`); with none at all it is `v1.0.0-rc.1`.

On 2026-11-15 every release up to v1.0.2 was removed this way, with the Raspberry Pi's packages (`alarm/` and each release's `aarch64/`): Nova had been written anew since, part by part, and the numbering began again at v1.0.0-rc.1. A system still on v1.0.2 moves to it with `nova update --version v1.0.0-rc.1 --allow-downgrade`, once, since 1.0.0 counts as older than 1.0.2. On 2026-11-19 the folders of v1.0.0-rc.1 to rc.10 went too (2.7 GB), and the releases after v1.0.0-rc.11 remove those before them themselves.

### The upgrade test

Before anything is published, CI installs the release before this one and takes it forward and back (`tests/install/run --upgrade`, the `upgrade-test` job), in four starts of one virtual machine:

1. It installs the newest published release older than this one, candidates included, from that release's own ISO and packages, each checked against Nova's key by `nova-usb`'s own code. With none older, it passes with a notice.
2. That system's own `nova update` moves it to this release. After a restart, the version, the pins, the boot entries, the desktop and `nova doctor` are checked, and that the boot menu has the snapshot `nova update` took before it: limine-snapper-sync's entry under Snapshots in `limine.conf`, the one whose command line boots that snapshot.
3. This release's `nova update --allow-downgrade` takes it back, and after a restart the older release is checked again.
4. The snapshot `nova update` took before step 2 replaces the root, as `limine-snapper-restore` does. After a restart, the older version, every one of its packages and its pins are back, byte for byte.

How the guest reaches a release not yet published:

- This release's `[nova]` repository is not published yet, so the guest reads it from the runner, at QEMU's address for the host, over HTTPS with a certificate from a CA made for the run and trusted by that guest alone, and through the `--release-file` option `nova update` already has.
- pacman checks every signature as it always does, and nothing in `nova update` or its root helper changes for the test.

Each start is checked with its own release's probe: the one where this release runs with this release's `tests/install/probe`, the ones where the older release runs with the probe of that release's tag. This release's probe checks what this release brings, which the older one has not: rc.13's upgrade test failed on rc.12, which had no nova-sessiond and no Printers, before its probe was the tag's.

Choosing the snapshot's entry in the boot menu, its overlay and the notification's **Restore now** are not in it: those are on the hardware checklist. The serial logs are kept as the run's `upgrade-logs`.

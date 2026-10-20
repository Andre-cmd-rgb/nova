# Releasing Nova

A release is a git tag (`v1.0.0-beta.1`), built by CI into a GitHub release.
Nothing is built or published from a laptop.

## What a release contains

| Asset | What reads it |
|---|---|
| `release.toml` | `nova update` and the installer: the version, the Arch Linux Archive date the release was built and tested against, and the URL of its `[nova]` repository |
| `nova.db`, `nova.files` and their `.sig` | pacman: the signed `[nova]` repository |
| `*.pkg.tar.zst` and their `.sig` | pacman: `nova`, `nova-keyring`, `linux-nova`, `linux-nova-headers`, `nvidia-open-nova`, `limine-entry-tool`, `limine-snapper-sync` |
| `nova-<version>-x86_64.iso` and `.sha256` | people: the installer stick |

The repository *is* the release page: `release.toml` points pacman at
`https://github.com/Andre-cmd-rgb/nova/releases/download/<tag>`, and every
system stays on its release's packages and Arch snapshot until `nova update`
moves it to the next one.

GitHub limits a release asset to 2 GiB and renames assets with unusual
characters, so the ISO installs over the network rather than carrying every
package (`nova usb` adds an offline copy to the stick), and `tools/repo-build`
stops on a package file name pacman would not find again (an epoch's `:`, a
development build's `+`).

## Versions

Tags are `vMAJOR.MINOR.PATCH`, with an optional `-beta.N` or `-rc.N`. The
`nova` package turns the tag into its pkgver: `v1.0.0-beta.1` becomes
`1.0.0beta.1`, which pacman sorts before `1.0.0` (`vercmp 1.0.0beta.1 1.0.0`
is -1), so moving from a beta to the final release is an ordinary upgrade.

A tag with a `-` becomes a GitHub pre-release, which reaches testers and
nobody else (below).

## The signing key (once)

The `[nova]` repository and every package in it are signed, and pacman refuses
anything else (`SigLevel = Required` in `installer/pacman.conf`). The public
key ships in the `nova-keyring` package; the private key lives only in the
`NOVA_REPO_KEY` repository secret and in an offline backup.

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

## A release every other week

Nova follows Arch two weeks behind, tested: each release is a candidate first.

1. **Candidate.** On the 1st and the 15th, `candidate.yml` runs CI on `main`,
   tags the next candidate (`tools/release-next`: `v1.0.0-beta.N` before 1.0,
   then `vX.Y.0-rc.N`), and calls `release.yml`, which:
   1. pins yesterday's Arch Linux Archive snapshot (`tools/release-pin --verify`);
   2. builds `linux-nova` against it, or reuses the build cached by the hash of
      `packaging/linux-nova` (an uncached build takes a few hours);
   3. builds the other packages on the same snapshot, `nvidia-open-nova` at the
      snapshot's driver version;
   4. signs them into the repository (`tools/repo-build`);
   5. builds the ISO (`tools/build-iso`);
   6. publishes it all as a pre-release, which only testers are offered:
      systems with Settings → Updates → Test Release Candidates on
      (`nova update --candidates on`), and those already on a candidate.

   Actions → candidate → Run cuts one at any other time.
2. **Test.** On a machine following pre-releases, `nova update`, then reboot;
   install the ISO on a spare disk or in QEMU (OVMF, tmpfs-backed disk); work
   through the hardware checklist for each supported laptop. A candidate that
   fails is simply not promoted: fix `main`, and the next candidate replaces it.
3. **Approve.** Actions → promote → Run, with the candidate's tag. It tags the
   same commit with the final version (`v1.1.0-rc.2` becomes `v1.1.0`), builds
   it again on the candidate's own Arch snapshot, and publishes it as the
   latest release. Systems pick it up at their next update check.

The kernel moves only when `packaging/linux-nova` is updated
([packaging.md](packaging.md)); everything else follows the snapshot.

Pushing a tag by hand (`git tag -s v1.0.1 -m 'Nova 1.0.1' && git push origin
v1.0.1`) builds the same way but leaves a draft, for a fix between candidates.

A release that turns out broken is never deleted, because systems may already
be on it: tag a fixed one. `nova update --version <tag> --allow-downgrade`
takes a system back, and snapper has the snapshot from before the update.

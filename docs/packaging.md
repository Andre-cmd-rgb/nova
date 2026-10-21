# Packaging

Every package Nova publishes has its PKGBUILD under `packaging/`. CI builds
them (`.github/workflows/release.yml`) against the Arch Linux Archive snapshot
a release pins, and nothing is built on a laptop except to test a PKGBUILD.

| Package | Built from | Why Nova builds it |
|---|---|---|
| `nova` | this repository, `make install` | everything Nova is |
| `nova-keyring` | `packaging/nova-keyring` | the key the `[nova]` repository is signed with, small enough for the installer ISO |
| `linux-nova`, `linux-nova-headers` | Arch's `linux` packaging plus BORE | the kernel Nova boots on x86-64-v3 CPUs |
| `nvidia-open-nova` | Arch's `nvidia-open` packaging | NVIDIA's open modules prebuilt for `linux-nova`, so no DKMS on the laptop |
| `limine-entry-tool`, `limine-snapper-sync` | the AUR recipes, pinned | the boot-entry and snapshot-menu tools, which are AUR-only |

Arch's own `linux` stands in for `linux-nova` on CPUs older than x86-64-v3,
with `nvidia-open`, and `linux-lts` is always installed as the fallback entry,
with `nvidia-open-lts` when there is an NVIDIA card.

## Building one locally

To check a PKGBUILD change, in a container or a spare machine, never on a
machine whose state matters:

```sh
cd packaging/<name> && makepkg --syncdeps --cleanbuild
```

`nova` builds the committed `HEAD` of this checkout (not uncommitted changes);
`NOVA_SOURCE='git+https://…#tag=v…'` builds a tag instead. CI's containers are
prepared by `tools/ci-setup` and build through `tools/build-package`.

## linux-nova

The PKGBUILD is Arch's `linux` with three changes, and the header comment says
which Arch packaging commit it follows:

- the BORE scheduler patch, pinned to a commit and a checksum;
- `nova-config.sh`, the complete list of config differences from Arch's
  `config.x86_64` (`apply` before `make olddefconfig`, `check` after, so a
  Kconfig change that drops one of them fails the build);
- `KCFLAGS=-march=x86-64-v3`.

### Updating the kernel

1. Take the new version's `PKGBUILD` and `config.x86_64` from Arch's packaging
   (`https://gitlab.archlinux.org/archlinux/packaging/packages/linux`) and
   carry over the three changes above. Note the new packaging commit in the
   header.
2. Check that the pinned BORE patch still applies. BORE names its patches after
   the first kernel of a series (`linux7.2-rc1`), so a point release keeps the
   same patch and a new series needs the matching one, pinned to a commit.
3. Update `b2sums` (`updpkgsums`) and build. `nova-config.sh check` fails the
   build if a delta did not survive.

A changed `packaging/linux-nova` means the next release rebuilds the kernel
instead of reusing the cached one.

## nvidia-open-nova

Its `pkgver` joins two versions, NVIDIA's and the `linux-nova` build the
modules are for: `615.78.08_7.2.11.arch1_1`. NVIDIA's must equal
`extra/nvidia-utils` in the release's Arch snapshot, because userspace and
modules have to match exactly. The release workflow writes both from the
snapshot and the kernel it built, so a new driver in Arch, or a new kernel,
needs nothing by hand; the committed value is only the last one released.

## limine-entry-tool and limine-snapper-sync

Rebuilt from their AUR recipes with the source pinned to a commit, not a tag
(tags can move). `limine-entry-tool` follows the AUR's `limine-mkinitcpio-hook`,
the entry tool with its mkinitcpio half: `limine-update`, the pacman hook that
rebuilds the UKIs and boot entries whenever a kernel changes, and the
`sd-btrfs-overlayfs` initramfs hook a snapshot boots with. To update: take the
new AUR PKGBUILD, compare it with ours, pin the commit behind the new tag, and
update the checksums. Their gradle builds download dependencies, so they need
network access at build time.

## nova-keyring

Holds `nova.gpg`, `nova-trusted` and `nova-revoked`, written by
`tools/keyring-export`. Its `pkgver` is the date the key set last changed.
Making and replacing the key is in [releasing.md](releasing.md).

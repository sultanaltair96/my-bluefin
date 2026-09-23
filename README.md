# my-bluefin

A personal, reproducible Bluefin desktop: one immutable image that carries a
specific set of applications, GNOME extensions and preferences, plus the signed
update path to keep it current.

## What this is

This is a **thin derivative**, not a rebuild. The base is the real
`ghcr.io/ublue-os/bluefin-nvidia-open` image, pinned by digest, so the desktop,
kernel, NVIDIA driver, Homebrew mechanism and ujust runtime are the tested
upstream ones. This repository adds only what is personal to one workstation:

| Added | Where |
|---|---|
| 34 Flatpak applications | `custom/flatpaks/default.preinstall` |
| 19 command-line tools | `custom/brew/default.Brewfile` |
| 7 GNOME Shell extensions enabled, 1 installed | `build/40-gnome-extensions.sh` |
| GNOME preferences as system defaults | `custom/files/usr/share/my-bluefin/gnome-settings.dconf` |
| Key-based signature policy for verified updates | `build/35-signing-policy.sh` |

Deliberately **not** here: personal files, browser state, SSH keys, tokens,
keyrings, AppImages and application data. Those live in an encrypted snapshot —
see [docs/recovery.md](docs/recovery.md).

## Updates are verified on the device

Most custom images sign in CI and then install with an unverified update
transport, so nothing checks the signature where it matters. This one does
verify:

- CI signs the published digest with a repository keypair, in addition to the
  keyless signature the promotion gate uses.
- The image ships the public key, a `sigstoreSigned` scope for its own namespace
  in `/etc/containers/policy.json`, and the matching `registries.d` entry.
- `image-info.json` therefore records a **signed** transport, and `bootc upgrade`
  checks the signature before deploying.

The private key is **not** in this repository. Losing it means future updates
cannot be signed under the same identity, so it is backed up separately and must
stay out of Git.

## Install

Installer media is built from a published digest by the **Build Installer**
workflow (manual dispatch). It boot-tests a qcow2 first and only then builds the
ISO, so the artifact you download has actually started successfully. The ISO uses
the interactive Anaconda installer: disk selection stays your decision, and no
account or password is baked in.

To move an existing bootc system onto this image instead:

```bash
sudo bootc switch --transport registry --enforce-container-sigpolicy \
  ghcr.io/sultanaltair96/my-bluefin:stable
sudo systemctl reboot
```

Do not point a working machine at a new image until it has booted in a VM.

After first login, on a machine with networking:

```bash
ujust install-default-apps      # the 19 Homebrew tools
ujust apply-gnome-settings      # re-apply GNOME preferences explicitly
ujust configure-dev-groups      # add yourself to docker and libvirt
```

Flatpaks install on first boot from Flathub, which needs a working network
connection. They are declarations, not payloads embedded in the ISO, so a first
boot performed offline installs nothing until the next boot online.

## What the desktop looks like

Seven extensions are enabled: AppIndicator support, Bazaar Companion, Blur my
Shell, Caffeine, Logo Menu, Search Light, and Resource Monitor. Resource Monitor
is the only extension the base does not ship; it is installed from a
checksum-pinned archive.

That list is pinned by this repository rather than inherited. Bluefin enables
`dash-to-dock`, `gradia-integration` and `gsconnect` on every account and this
image leaves them installed but not enabled, matching the source desktop.
Enabling one later in Extension Manager is a user-level change and takes
precedence.

GNOME preferences are installed as **system defaults** in
`/etc/dconf/db/local.d/`, which sits below the user's own database. A new account
starts with dark mode, the slate accent, `Ctrl+Q` to close a window, and the
other captured preferences; any setting you change afterwards wins, so the image
never fights you.

## Build and test

```bash
just check               # Justfile syntax
just lint                # shellcheck every tracked script
just validate-brewfiles  # Brewfile declarations
just validate-flatpaks   # Flatpak ids exist on Flathub
just test-unit           # the contract and template suites
just build               # build the image against the pinned base
just build-qcow2         # a bootable test disk
just build-iso           # installer media
```

`tests/contract/` covers the interfaces the image must satisfy, including that
every phase the Containerfile invokes exists, is executable, and fails closed
rather than silently overriding upstream.

## Honest limits

- **Declarative, not bit-reproducible.** The base is pinned by digest and the
  extensions by checksum, but Flatpaks and Homebrew formulae install current
  upstream versions. The application *selection* reproduces; exact package
  versions drift.
- **NVIDIA is inherited, not proven here.** The driver comes from the base image
  and the build can only confirm the packages and kernel pairing. The VM check
  verifies the module matches the running kernel; it cannot prove a physical GPU
  works, which needs the real laptop.
- **The ISO is installation media, not a copy of a desktop.** It reproduces the
  system; your data comes from the encrypted snapshot.
- **Private state is dated.** The recovery snapshot is a point-in-time copy.
  Refresh it before migrating.

## Recovery

See [docs/recovery.md](docs/recovery.md) for the encrypted snapshot, how to
refresh it, and how to restore onto a new machine.

## Upstream

- [Project Bluefin](https://docs.projectbluefin.io/)
- [Finpilot](https://github.com/projectbluefin/finpilot) — the template this
  started from
- [bootc](https://containers.github.io/bootc/)

# Build scripts

Scripts that run during image assembly. The Containerfile names each one in its
own `RUN` block, so the order is whatever the Containerfile says — there is no
prefix auto-discovery. The numbers communicate intent.

This image is a thin derivative: it inherits a complete, tested Bluefin image
and layers one user's declarations on top. It does not rebuild the desktop,
kernel, NVIDIA driver, Homebrew mechanism or ujust runtime, because the base
already owns those and a second copy can regress them.

## Phases

| Script | Does |
|---|---|
| `00-image-info.sh` | Writes the image identity into `os-release` and `image-info.json`: the base image name, the Fedora major derived from the base's `os-release`, the version string, and the tag. |
| `25-personal-overlay.sh` | Overlays `custom/files`, installs the `custom/ujust` recipes into the seam Bluefin's entry point already imports, copies the Brewfile and Flatpak declarations, and installs the GNOME settings as system defaults. Installs no packages. |
| `35-signing-policy.sh` | Merges this repository's key-based trust scope into the inherited container policy, so `bootc upgrade` verifies the image signature on the device. |
| `40-gnome-extensions.sh` | Adds only the extensions the base does not ship, from checksum-pinned archives, and pins the enabled list to the source desktop's set. |

Helpers, not phases: `validate-brewfiles.sh` and `validate-flatpaks.sh`, called
by the Justfile, the pre-commit hook and CI.

## Rules

- **Do not re-apply what the base provides.** Overlaying upstream layers or
  reinstalling a driver the base already ships duplicates work and can replace a
  patched upstream file with a generic one.
- **Do not overwrite an inherited file.** Every phase writes into a seam the
  base leaves open. A name collision with upstream is a bug here, so the phases
  that could collide fail closed instead of silently winning.
- **Overriding an upstream default is deliberate and documented.** Pinning
  `enabled-extensions` replaces Bluefin's set, so the phase states why and what
  it drops. An unexplained override is indistinguishable from an accident.
- **Pin anything fetched at build time.** An archive pulled by tag alone can
  change without a commit to this repository. Extensions are pinned by version
  tag and SHA-256, and a mismatch fails the build.
- **Fail closed.** Prefer a build error over an image that installs but does not
  behave as documented. `dconf update`, checksum verification and the policy
  validation all abort rather than warn.
- Use `dnf5`, never `dnf` or `yum`, and always `-y`, if a phase ever installs a
  package. None currently does.
- Scripts run as root with the build context at `/ctx`, and must be executable:
  the Containerfile invokes them by path.

## Adding one

Copy an existing phase's shape: `#!/usr/bin/env bash`, `set -euo pipefail`, one
purpose per script, and a matching `RUN` block in the Containerfile in the
position the dependency order requires.

## Testing

`tests/contract/` covers the interfaces the image must satisfy, including these
phases. `just test-unit` runs the suite, and `just build` proves the whole
assembly against the real base.

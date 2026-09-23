#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Personal overlay
###############################################################################
# This phase layers one user's declarations onto an intact Bluefin image. It
# installs no packages and rebuilds nothing: the base already owns the desktop,
# kernel, NVIDIA driver, Homebrew mechanism and ujust runtime. Re-applying any
# of those here would duplicate upstream work and can regress it.
#
# Order is the contract. Each step writes only into a seam Bluefin leaves open:
#
#   1. custom/files  -> the image root (trust material, settings source)
#   2. custom/ujust  -> /usr/share/ublue-os/just/60-custom.just, which
#                       Bluefin's 00-entry.just already imports optionally
#   3. custom/brew   -> /usr/share/ublue-os/homebrew/
#   4. custom/flatpaks -> /usr/share/flatpak/preinstall.d/
#   5. GNOME settings -> /etc/dconf/db/local.d/ as system defaults
#
# Nothing here overwrites an inherited file. A name collision with upstream is
# a bug in this repository, not a precedence rule to rely on, so step 2 and 5
# fail closed when the seam they write is already occupied.
###############################################################################

echo "::group:: Verify the base image provides the seams this phase writes"

# Fail early and clearly rather than silently installing into a path the base
# does not read, which would produce an image that looks built but is inert.
for required in \
	/usr/share/ublue-os/just/00-entry.just \
	/etc/dconf/profile/user \
	/etc/dconf/db \
	/usr/share/ublue-os/homebrew \
	/usr/share/flatpak/preinstall.d; do
	test -e "${required}" || {
		echo "Base image is missing ${required}; this phase targets Bluefin." >&2
		exit 1
	}
done

# The ujust entry point must import the custom seam, or the recipes copied
# below would be installed and never reachable.
grep -qF '/usr/share/ublue-os/just/60-custom.just' /usr/share/ublue-os/just/00-entry.just || {
	echo '00-entry.just does not import 60-custom.just; recipes would be unreachable' >&2
	exit 1
}

echo "::endgroup::"

echo "::group:: Overlay personal system files"

# custom/files mirrors the image root. This carries the image's own signing
# public key, the sigstore registries.d entry that pairs with it, and the
# GNOME settings source consumed by the apply-gnome-settings recipe.
# The leading slash anchors the exclusion to the copy root, so the seam's own
# README never lands in the image while a nested file named README.md still
# ships.
rsync -rvKl --exclude=/README.md /ctx/custom/files/ /

echo "::endgroup::"

echo "::group:: Install personal ujust recipes"

# Bluefin's entry point ends with an optional import of 60-custom.just, which
# the base does not ship. Writing it is the supported extension point. Refuse
# to clobber the file if a future base starts shipping one, because silently
# replacing upstream recipes would be a surprising loss of function.
CUSTOM_JUST=/usr/share/ublue-os/just/60-custom.just
test -e "${CUSTOM_JUST}" && {
	echo "${CUSTOM_JUST} already exists in the base image; refusing to overwrite" >&2
	exit 1
}

# Walk the tree so recipes can be grouped into subdirectories, and sort the
# inputs so the merged result is deterministic and reproducible.
: >"${CUSTOM_JUST}"
if [[ -d /ctx/custom/ujust ]]; then
	mapfile -t recipes < <(find /ctx/custom/ujust -type f -iname '*.just' | LC_ALL=C sort)
	for recipe in "${recipes[@]}"; do
		cat "${recipe}" >>"${CUSTOM_JUST}"
		printf '\n' >>"${CUSTOM_JUST}"
	done
fi
test -s "${CUSTOM_JUST}" || {
	echo 'No ujust recipes were consolidated' >&2
	exit 1
}

echo "::endgroup::"

echo "::group:: Install personal Homebrew declarations"

# Files land beside Bluefin's own Brewfiles rather than replacing any of them,
# so `ujust install-default-apps` installs this list while the inherited
# recipes keep working.
cp /ctx/custom/brew/*.Brewfile /usr/share/ublue-os/homebrew/

echo "::endgroup::"

echo "::group:: Install personal Flatpak preinstalls"

# The base ships bazaar.preinstall, which installs the application store and
# must stay. These declarations are additive and install on first boot, which
# needs a network connection: they are declarations, not embedded payloads.
cp /ctx/custom/flatpaks/*.preinstall /usr/share/flatpak/preinstall.d/

echo "::endgroup::"

echo "::group:: Install personal GNOME system defaults"

# The settings source is written for `dconf load /org/gnome/`, so its section
# headers are relative to that prefix. A system database file needs the full
# path, so re-anchor each header to org/gnome/. One source, two consumers.
#
# These land in local.d, which sits above Bluefin's distro.d and below the
# user's own database. A new account therefore starts with these values and
# any change the user makes afterwards wins, which is what keeps this from
# fighting the person using the machine.
SETTINGS_SOURCE=/usr/share/my-bluefin/gnome-settings.dconf
test -s "${SETTINGS_SOURCE}" || {
	echo "Missing ${SETTINGS_SOURCE}" >&2
	exit 1
}

SYSTEM_DEFAULTS=/etc/dconf/db/local.d/10-my-bluefin
test -e "${SYSTEM_DEFAULTS}" && {
	echo "${SYSTEM_DEFAULTS} already exists in the base image; refusing to overwrite" >&2
	exit 1
}

install -d -m0755 /etc/dconf/db/local.d
# Re-anchor the header itself: the path goes inside the brackets, not before them.
awk '/^\[/ { sub(/^\[/, "[org/gnome/"); print; next } { print }' \
	"${SETTINGS_SOURCE}" >"${SYSTEM_DEFAULTS}"
chmod 0644 "${SYSTEM_DEFAULTS}"

# Compile the databases so the settings are readable without a live session.
# dconf update is required here: the text files alone are not consulted.
dconf update

echo "::endgroup::"

echo "Personal overlay complete!"

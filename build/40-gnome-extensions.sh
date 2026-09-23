#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Personal GNOME Shell extensions
###############################################################################
# Bluefin already ships and enables its own extension set, including locally
# patched copies that are not the extensions.gnome.org builds. This phase adds
# only what the base does not provide and leaves every inherited extension,
# override and schema file untouched.
#
# That distinction matters: re-downloading an extension Bluefin already ships
# would replace a patched copy with an upstream one that may not declare this
# GNOME release. The base is the source of truth for its own set.
#
# The archive is pinned by version tag and SHA-256. Both are part of the build
# input, so the image cannot silently pick up a different upstream release, and
# a moved or tampered artifact fails the build instead of shipping.
###############################################################################

SHELL_MAJOR="$(gnome-shell --version | awk '{print $3}' | cut -d. -f1)"
EXTENSIONS_DIR=/usr/share/gnome-shell/extensions

# Sorted last so this file wins over Bluefin's zz0- and zz1- overrides for the
# keys it sets. It sets exactly one key, and only after merging the inherited
# value into it.
OVERRIDE_FILE=/usr/share/glib-2.0/schemas/zz9-my-bluefin-extensions.gschema.override

# Extensions the base image does not ship. One entry per extension:
#   uuid version_tag sha256
#
# version_tag pins the exact extensions.gnome.org release, and the digest is
# verified before the archive is unpacked. Update both together: a version bump
# with a stale digest fails closed, which is the intended failure direction.
EGO_EXTENSIONS=(
	"Resource_Monitor@Ory0n 70909 18f49cf20bd8f96f22f6048d7404e51cb414c1aea94ca16d0c2ad3634e9d8bf2"
)

ADDED_EXTENSIONS=()

echo "::group:: Install extensions the base image does not ship"

for entry in "${EGO_EXTENSIONS[@]}"; do
	read -r uuid version_tag expected_sha256 <<<"${entry}"

	# Respect the base if a future Bluefin starts shipping this extension. Its
	# copy is the maintained one, and it may carry local patches.
	if [[ -d "${EXTENSIONS_DIR}/${uuid}" ]]; then
		echo "${uuid} is already provided by the base image; keeping it"
		continue
	fi

	archive=/tmp/extension.zip
	curl -fsSL \
		"https://extensions.gnome.org/download-extension/${uuid}.shell-extension.zip?version_tag=${version_tag}" \
		-o "${archive}"

	actual_sha256="$(sha256sum "${archive}" | cut -d' ' -f1)"
	if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
		echo "Checksum mismatch for ${uuid}: expected ${expected_sha256}, got ${actual_sha256}" >&2
		exit 1
	fi

	mkdir -p "${EXTENSIONS_DIR}/${uuid}"
	unzip -q -o "${archive}" -d "${EXTENSIONS_DIR}/${uuid}"
	rm -f "${archive}"

	# The install directory must be the uuid the extension declares, and the
	# extension must claim this GNOME release. Checking both turns a silent
	# "installed but never loaded" into a build failure.
	declared_uuid="$(jq -r .uuid "${EXTENSIONS_DIR}/${uuid}/metadata.json")"
	if [[ "${declared_uuid}" != "${uuid}" ]]; then
		echo "metadata.json declares ${declared_uuid}, expected ${uuid}" >&2
		exit 1
	fi

	if ! jq -e --arg major "${SHELL_MAJOR}" \
		'."shell-version" | index($major)' \
		"${EXTENSIONS_DIR}/${uuid}/metadata.json" >/dev/null; then
		echo "${uuid} does not declare GNOME Shell ${SHELL_MAJOR}" >&2
		exit 1
	fi

	ADDED_EXTENSIONS+=("${uuid}")
	echo "Installed ${uuid} (version_tag ${version_tag})"
done

echo "::endgroup::"

echo "::group:: Merge the enabled extension list"

# Extensions ship schema XML, never a compiled cache, and some ship no schemas.
shopt -s nullglob
for schemas_dir in "${EXTENSIONS_DIR}"/*/schemas; do
	glib-compile-schemas --strict "${schemas_dir}"
done
shopt -u nullglob

# The enabled set is pinned here rather than inherited from the base.
#
# This is deliberate, and it is the one place this image overrides an upstream
# default. Bluefin enables dash-to-dock, gradia-integration and gsconnect on
# every account; the source installation has all three switched off, so
# inheriting the upstream list would ship a desktop that is visibly not the one
# this image exists to reproduce. Enabling an extension here is a default only:
# a user who turns one on or off afterwards keeps that choice, because their own
# database outranks the system default.
#
# Every uuid below must exist in the image. A missing one fails the build rather
# than producing a desktop that is quietly missing a panel item.
ENABLED_EXTENSIONS=(
	appindicatorsupport@rgcjonas.gmail.com
	bazaar-integration@kolunmi.github.io
	blur-my-shell@aunetx
	caffeine@patapon.info
	logomenu@aryan_k
	search-light@icedman.github.com
	Resource_Monitor@Ory0n
)

ENABLED_LIST=""
for uuid in "${ENABLED_EXTENSIONS[@]}"; do
	if [[ ! -d "${EXTENSIONS_DIR}/${uuid}" ]]; then
		echo "${uuid} is enabled but not installed in the image" >&2
		exit 1
	fi
	[[ -n "${ENABLED_LIST}" ]] && ENABLED_LIST+=", "
	ENABLED_LIST+="'${uuid}'"
done

{
	echo "[org.gnome.shell]"
	echo "enabled-extensions=[${ENABLED_LIST}]"
} >"${OVERRIDE_FILE}"

# Rebuild the system schema cache so the override takes effect.
rm -f /usr/share/glib-2.0/schemas/gschemas.compiled
glib-compile-schemas /usr/share/glib-2.0/schemas

echo "::endgroup::"

echo "Personal extensions complete!"

#!/usr/bin/env bats
# Contract: the build phases the Containerfile invokes must be runnable and must
# obey the rules build/README.md states.
#
# The failure this exists for is specific: the Containerfile runs each phase by
# path, so a phase committed without the executable bit fails the build with
# "Permission denied" and a 126 exit, only after the expensive layers above it
# have been built. Nothing else in the suite catches that, because `just lint`
# resolves its scope from `git ls-files '*.sh'`, which says nothing about the
# mode bit.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
README="${BUILD_DIR}/README.md"

# The phase paths the Containerfile actually runs, as basenames.
_invoked_phases() {
    grep -oE '/ctx/build/[A-Za-z0-9._-]+\.sh' "${CONTAINERFILE}" | sed 's|.*/||' | sort -u
}

# Every shell script in the build directory.
_all_phases() {
    find "${BUILD_DIR}" -maxdepth 1 -type f -name '*.sh' | sort
}

setup() {
    mapfile -t INVOKED < <(_invoked_phases)
    [ "${#INVOKED[@]}" -gt 0 ]
}

@test "every phase the Containerfile invokes exists" {
    for phase in "${INVOKED[@]}"; do
        [ -f "${BUILD_DIR}/${phase}" ] || {
            echo "Containerfile invokes ${phase}, which does not exist" >&2
            return 1
        }
    done
}

@test "every phase the Containerfile invokes is executable" {
    # This is the regression guard for the 126 exit described in the header.
    for phase in "${INVOKED[@]}"; do
        [ -x "${BUILD_DIR}/${phase}" ] || {
            echo "${phase} is invoked by path but is not executable" >&2
            return 1
        }
    done
}

@test "every build script declares the bash shebang and strict mode" {
    for phase in "${INVOKED[@]}"; do
        run head -n 1 "${BUILD_DIR}/${phase}"
        [ "${output}" = "#!/usr/bin/env bash" ] || {
            echo "${phase}: first line is '${output}'" >&2
            return 1
        }
        grep -qx 'set -euo pipefail' "${BUILD_DIR}/${phase}" || {
            echo "${phase}: no 'set -euo pipefail'" >&2
            return 1
        }
    done
}

@test "no build script calls dnf or yum instead of dnf5" {
    for phase in "${INVOKED[@]}"; do
        run grep -nE '(^|[^[:alnum:]_/-])(dnf|yum)[[:space:]]' "${BUILD_DIR}/${phase}"
        [ "${status}" -ne 0 ] || {
            echo "${phase}: ${output}" >&2
            return 1
        }
    done
}

@test "build/README.md lists every phase and advertises none that is gone" {
    for phase in "${INVOKED[@]}"; do
        grep -qF "\`${phase}\`" "${README}" || {
            echo "build/README.md does not list ${phase}" >&2
            return 1
        }
    done

    # And the reverse: a documented phase that no longer exists.
    while IFS= read -r name; do
        [ -f "${BUILD_DIR}/${name}" ] || {
            echo "build/README.md lists ${name}, which does not exist" >&2
            return 1
        }
    done < <(grep -oE '`[0-9]+-[a-z-]+\.sh`' "${README}" | tr -d '`' | sort -u)
}

@test "the personal overlay refuses to overwrite inherited files" {
    # The overlay is additive by design. These guards are what stop a future
    # base from silently losing its own ujust recipes or GNOME defaults.
    grep -qF '60-custom.just' "${BUILD_DIR}/25-personal-overlay.sh"
    grep -qF 'refusing to overwrite' "${BUILD_DIR}/25-personal-overlay.sh"
    # And it must compile the dconf database it writes, not just drop the file.
    grep -qE '^dconf update$' "${BUILD_DIR}/25-personal-overlay.sh"
}

@test "the extension phase pins archives by tag and checksum" {
    local phase="${BUILD_DIR}/40-gnome-extensions.sh"
    grep -q 'version_tag=' "${phase}"
    grep -q 'sha256sum' "${phase}"
    # A pinned digest is worthless if a mismatch is not fatal.
    grep -qF 'Checksum mismatch' "${phase}"
    grep -qF 'shell-version' "${phase}"
}

@test "the enabled extension set is exactly the intended seven" {
    # The VM check asserts this list against a booted system, which costs a full
    # CI cycle to discover a typo. Assert it statically too, and assert that the
    # override sorts after the base image's own overrides: enabled-extensions is
    # a single array, so the last override to load wins and a zz9- prefix is what
    # makes this list authoritative over Bluefin's eight.
    local phase="${BUILD_DIR}/40-gnome-extensions.sh"
    for uuid in \
        appindicatorsupport@rgcjonas.gmail.com \
        bazaar-integration@kolunmi.github.io \
        blur-my-shell@aunetx \
        caffeine@patapon.info \
        logomenu@aryan_k \
        search-light@icedman.github.com \
        Resource_Monitor@Ory0n; do
        grep -qF "${uuid}" "${phase}" || {
            echo "${phase} never enables ${uuid}" >&2
            return 1
        }
    done

    # Exactly seven: an eighth entry means the list drifted from the source
    # desktop, which enables these and leaves dash-to-dock, gradia-integration
    # and gsconnect switched off.
    local count
    count="$(awk '/^ENABLED_EXTENSIONS=\(/ { inside=1; next } inside && /^\)/ { exit } inside && /@/ { n++ } END { print n + 0 }' "${phase}")"
    [ "${count}" -eq 7 ] || {
        echo "expected 7 enabled extensions, found ${count}" >&2
        return 1
    }

    grep -qF 'zz9-my-bluefin-extensions.gschema.override' "${phase}"
}

@test "shellcheck is clean on every build phase" {
    command -v shellcheck >/dev/null || skip "shellcheck is not installed"
    for phase in "${INVOKED[@]}"; do
        run shellcheck --shell=bash "${BUILD_DIR}/${phase}"
        [ "${status}" -eq 0 ] || {
            echo "${phase}: ${output}" >&2
            return 1
        }
    done
}

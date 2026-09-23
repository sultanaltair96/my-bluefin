#!/usr/bin/env bats

setup() {
    REPO="${BATS_TEST_DIRNAME}/../.."
    ROOT="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${ROOT}/usr/share/ublue-os/just" "${ROOT}/usr/share/flatpak/preinstall.d" "${ROOT}/etc/dconf/profile"
    printf 'import? "/usr/share/ublue-os/just/60-custom.just"\n' >"${ROOT}/usr/share/ublue-os/just/00-entry.just"
    printf '# inherited custom import\n' >"${ROOT}/usr/share/ublue-os/just/60-custom.just"
    printf 'user-db:user\nsystem-db:local\nsystem-db:site\nsystem-db:distro\n' >"${ROOT}/etc/dconf/profile/user"
    touch "${ROOT}/usr/share/flatpak/preinstall.d/upstream.preinstall"
}

@test "assembly inherits pinned complete Bluefin without rebuilding upstream phases" {
    grep -qx 'FROM ghcr.io/ublue-os/bluefin-nvidia-open:stable@sha256:3b4a36dc0cc2337ebbafcd9926f35614447f2fdee4b028d2e3a720e49254b4a5' "${REPO}/Containerfile"
    ! grep -E '/ctx/build/(10-overlay|20-packages-and-services|50-nvidia|90-cleanup)\.sh|^FROM .* (common|brew)$' "${REPO}/Containerfile"
    grep -q '/ctx/build/25-personal-overlay.sh' "${REPO}/Containerfile"
    grep -q 'bootc container lint --fatal-warnings' "${REPO}/Containerfile"
}

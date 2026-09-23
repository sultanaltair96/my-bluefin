#!/usr/bin/env bats
# Keep signed update transport, scoped policy and CI signatures in agreement.
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

setup() {
    export ROOT_DIR="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${ROOT_DIR}/etc/containers"
    cat >"${ROOT_DIR}/etc/containers/policy.json" <<'JSON'
{"default":[{"type":"reject"}],"transports":{"docker":{"ghcr.io/ublue-os":[{"type":"sigstoreSigned","keyPath":"/upstream.pub","signedIdentity":{"type":"matchRepository"}}],"":[{"type":"insecureAcceptAnything"}]},"atomic":{"example.com":[{"type":"reject"}]}}}
JSON
    cp "${ROOT_DIR}/etc/containers/policy.json" "${BATS_TEST_TMPDIR}/before.json"
    # This is the custom overlay's responsibility in the real image build.
    if [[ -d "${REPO_ROOT}/custom/files/etc/containers" ]]; then
        cp -a "${REPO_ROOT}/custom/files/etc/containers/." "${ROOT_DIR}/etc/containers/"
    fi
}

@test "image-signing: merge enforces only this repository and preserves inherited scopes" {
    run bash "${REPO_ROOT}/build/35-signing-policy.sh"
    [ "$status" -eq 0 ]
    jq -e '.transports.docker["ghcr.io/sultanaltair96/my-bluefin"] == [{"type":"sigstoreSigned","keyPath":"/etc/containers/keys/my-bluefin.pub","signedIdentity":{"type":"matchRepository"}}]' "${ROOT_DIR}/etc/containers/policy.json"
    jq 'del(.transports.docker["ghcr.io/sultanaltair96/my-bluefin"])' "${ROOT_DIR}/etc/containers/policy.json" >"${BATS_TEST_TMPDIR}/after.json"
    diff -u <(jq -S . "${BATS_TEST_TMPDIR}/before.json") <(jq -S . "${BATS_TEST_TMPDIR}/after.json")
    [ -s "${ROOT_DIR}/etc/containers/keys/my-bluefin.pub" ]
    grep -q 'BEGIN PUBLIC KEY' "${ROOT_DIR}/etc/containers/keys/my-bluefin.pub"
    grep -q '^  ghcr.io/sultanaltair96/my-bluefin:$' "${ROOT_DIR}/etc/containers/registries.d/my-bluefin.yaml"
    grep -q '^    use-sigstore-attachments: true$' "${ROOT_DIR}/etc/containers/registries.d/my-bluefin.yaml"
}

@test "image-signing: rejects invalid inherited policy without replacing it" {
    for content in 'null' '{}' '{invalid'; do
        printf '%s\n' "$content" >"${ROOT_DIR}/etc/containers/policy.json"
        run bash "${REPO_ROOT}/build/35-signing-policy.sh"
        [ "$status" -ne 0 ]
        [ "$(cat "${ROOT_DIR}/etc/containers/policy.json")" = "$content" ]
    done
}

@test "image-signing: missing overlay trust material fails closed" {
    rm "${ROOT_DIR}/etc/containers/keys/my-bluefin.pub"
    run bash "${REPO_ROOT}/build/35-signing-policy.sh"
    [ "$status" -ne 0 ]
    cmp "${ROOT_DIR}/etc/containers/policy.json" "${BATS_TEST_TMPDIR}/before.json"
}

@test "image-signing: repeated merge is idempotent" {
    run bash "${REPO_ROOT}/build/35-signing-policy.sh"
    [ "$status" -eq 0 ]
    cp "${ROOT_DIR}/etc/containers/policy.json" "${BATS_TEST_TMPDIR}/once.json"
    run bash "${REPO_ROOT}/build/35-signing-policy.sh"
    [ "$status" -eq 0 ]
    cmp "${ROOT_DIR}/etc/containers/policy.json" "${BATS_TEST_TMPDIR}/once.json"
    [ ! -e "${REPO_ROOT}/custom/files/etc/containers/policy.json" ]
}

@test "image-signing: CI retains keyless then requires a legacy key signature" {
    run python3 - "${REPO_ROOT}" <<'PY'
import pathlib, sys, re
repo = pathlib.Path(sys.argv[1])
steps = re.split(r'^      - name: ', (repo / '.github/workflows/build-image.yml').read_text(), flags=re.M)[1:]
keyless = next(s for s in steps if 'signing-mode: keyless' in s)
key = next(s for s in steps if s.startswith('Sign for on-device verification\n'))
assert steps.index(keyless) < steps.index(key)
assert 'continue-on-error: true' not in keyless + key
assert '\n        if:' not in key  # default success(): no signing after keyless failure
assert 'COSIGN_PRIVATE_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}' in key
assert 'COSIGN_PASSWORD: ${{ secrets.COSIGN_PASSWORD }}' in key
assert 'DIGEST: ${{ steps.push.outputs.digest }}' in key
script = key.split('        run: |\n', 1)[1]
for required in ('set -euo pipefail', '--key env://COSIGN_PRIVATE_KEY', '--new-bundle-format=false', '--use-signing-config=false', '${IMAGE}@${DIGEST}', 'scripts/verify-image-signature.sh'):
    assert required in script, required
assert '|| true' not in script

# Verification must go through containers/image, not cosign's own verifier.
# The digest carries a keyless signature (for the promotion gate) and a
# key-based one (for on-device verification) at the same time, and
# `cosign verify --key` refuses that combination with "expected key signature,
# not certificate". containers/image accepts it and is what bootc calls on a
# device. See scripts/verify-image-signature.sh.
code = '\n'.join(
    line for line in script.splitlines()
    if not line.lstrip().startswith('#')
)
assert 'cosign verify' not in code, code
assert 'verify-image-signature.sh' in code

# And the script the workflows share must exist and be the one that fails closed.
verifier = repo / 'scripts/verify-image-signature.sh'
assert verifier.exists()
verifier_text = verifier.read_text()
for required in ('skopeo copy', 'sigstoreSigned', 'matchRepository',
                 'custom/files/etc/containers/keys/my-bluefin.pub',
                 'custom/files/etc/containers/registries.d/my-bluefin.yaml'):
    assert required in verifier_text, required
assert 'set -euo pipefail' in verifier_text
PY
    [ "$status" -eq 0 ]
}

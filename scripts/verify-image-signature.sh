#!/usr/bin/env bash
# Verify that a published digest carries this repository's key signature, using
# the same trust material and the same mechanism a booted machine uses.
#
# Run as root: the policy and registries.d it installs are read from
# /etc/containers, and installing them is the point. The check must exercise the
# file a device will use, not a CI-only rewrite of it.
#
# Why not cosign: the published digest deliberately carries two signatures, a
# keyless one for the promotion gate and a key-based one for on-device
# verification. `cosign verify --key` rejects that combination outright with
# "expected key signature, not certificate", because it walks the signature
# layers and refuses the certificate one. containers/image accepts the set and
# matches the key-based layer, and containers/image is what bootc actually calls
# on a device, so this is both the only workable check and the more faithful one.
set -euo pipefail

IMAGE_REF=${1:-}
if [[ ! ${IMAGE_REF} =~ ^[a-z0-9./:_-]+@sha256:[0-9a-f]{64}$ ]]; then
    echo "usage: verify-image-signature.sh IMAGE@sha256:DIGEST" >&2
    exit 2
fi

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
PUBLIC_KEY="${REPO_ROOT}/custom/files/etc/containers/keys/my-bluefin.pub"
REGISTRIES_D="${REPO_ROOT}/custom/files/etc/containers/registries.d/my-bluefin.yaml"
NAMESPACE="${IMAGE_REF%@*}"
KEY_PATH=/etc/containers/keys/my-bluefin.pub

if [[ ${EUID} -ne 0 ]]; then
    echo 'Run as root: the trust policy is read from /etc/containers' >&2
    exit 2
fi
for tool in skopeo jq install; do
    command -v "${tool}" >/dev/null || {
        echo "Missing dependency: ${tool}" >&2
        exit 2
    }
done
for file in "${PUBLIC_KEY}" "${REGISTRIES_D}"; do
    [[ -s ${file} ]] || {
        echo "Missing shipped trust material: ${file}" >&2
        exit 2
    }
done

# Install the shipped files verbatim rather than generating equivalents, so a
# drift between what ships and what CI checks is impossible.
install -D -m0644 "${PUBLIC_KEY}" "${KEY_PATH}"
install -D -m0644 "${REGISTRIES_D}" /etc/containers/registries.d/my-bluefin.yaml

# Add only this repository's scope. Every other scope and the default entry are
# preserved, mirroring build/35-signing-policy.sh, so unrelated pulls on this
# machine keep working.
tmp="$(mktemp)"
if [[ -s /etc/containers/policy.json ]]; then
    jq --arg ns "${NAMESPACE}" --arg key "${KEY_PATH}" \
        '.transports.docker[$ns] = [{
            type: "sigstoreSigned",
            keyPath: $key,
            signedIdentity: {type: "matchRepository"}
        }]' /etc/containers/policy.json >"${tmp}"
else
    jq -n --arg ns "${NAMESPACE}" --arg key "${KEY_PATH}" \
        '{default: [{type: "insecureAcceptAnything"}],
          transports: {docker: {($ns): [{
              type: "sigstoreSigned",
              keyPath: $key,
              signedIdentity: {type: "matchRepository"}
          }]}}}' >"${tmp}"
fi
install -m0644 "${tmp}" /etc/containers/policy.json
rm -f "${tmp}"

# A copy is the check: containers/image resolves the manifest, fetches the
# signature, and enforces the policy before any layer is written. An unsigned or
# foreign image fails here.
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
skopeo copy "docker://${IMAGE_REF}" "dir:${work}"

echo "Verified ${IMAGE_REF} against the signature policy this image ships"

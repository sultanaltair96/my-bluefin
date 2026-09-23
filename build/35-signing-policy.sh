#!/usr/bin/env bash
# Run after the personal overlay; retain all inherited trust scopes.
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-}"
POLICY="${ROOT_DIR}/etc/containers/policy.json"
KEY_PATH="/etc/containers/keys/my-bluefin.pub"
REGISTRIES="${ROOT_DIR}/etc/containers/registries.d/my-bluefin.yaml"

# Fail closed if the base policy or the overlay's trust material is missing.
test -s "${ROOT_DIR}${KEY_PATH}"
test -s "${REGISTRIES}"

# Validate the inherited policy before touching it. Merging into a null or
# truncated policy would succeed as far as jq is concerned and leave a policy
# with no default and no inherited scopes, which rejects every other image on
# the machine. Only a well-formed policy with a docker transport is safe to
# extend, so refuse anything else and leave the original file untouched.
jq -e '
    type == "object"
    and has("default")
    and (.transports | type == "object")
    and (.transports.docker | type == "object")
' "${POLICY}" >/dev/null || {
    echo "Inherited ${POLICY} is not a usable policy; refusing to merge" >&2
    exit 1
}

TEMP_POLICY="$(mktemp "${POLICY}.XXXXXX")"
trap 'rm -f "${TEMP_POLICY}"' EXIT
jq --arg key "${KEY_PATH}" '
    .transports.docker["ghcr.io/sultanaltair96/my-bluefin"] = [{
        type: "sigstoreSigned",
        keyPath: $key,
        signedIdentity: {type: "matchRepository"}
    }]
' "${POLICY}" >"${TEMP_POLICY}"
chmod 0644 "${TEMP_POLICY}"
mv "${TEMP_POLICY}" "${POLICY}"

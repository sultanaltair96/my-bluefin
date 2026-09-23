#!/usr/bin/env bats

setup() {
    REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

@test "installer rejects malformed digest and unsafe channel before tools" {
    for digest in sha256:abc "sha256:$(printf '%064d' 0);touch /tmp/no" "SHA256:$(printf '%064d' 0)"; do
        run bash "$REPO/scripts/verify-vm.sh" validate "$digest" stable-testing
        [ "$status" -eq 2 ]
        [[ "$output" == *"Invalid digest"* ]]
    done
    run bash "$REPO/scripts/verify-vm.sh" validate "sha256:$(printf '%064d' 0)" latest
    [ "$status" -eq 2 ]
    [[ "$output" == *"Invalid channel"* ]]
}

@test "test-only disk configuration contains keys and no passwords or installer" {
    ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/key"
    run bash "$REPO/scripts/verify-vm.sh" config "$BATS_TEST_TMPDIR/key.pub" "$BATS_TEST_TMPDIR/disk.json"
    [ "$status" -eq 0 ]
    run python3 - "$BATS_TEST_TMPDIR/disk.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))['customizations']
assert 'installer' not in c
assert {u['name'] for u in c['user']} == {'root', 'ci-smoke'}
assert all('password' not in u and u['key'].startswith('ssh-ed25519 ') for u in c['user'])
assert 'systemd.wants=sshd.service' in c['kernel']['append']
assert 'console=ttyS0' in c['kernel']['append']
PY
    [ "$status" -eq 0 ]
}

@test "VM refuses missing disk before launching QEMU" {
    run bash "$REPO/scripts/verify-vm.sh" run /nonexistent "$BATS_TEST_TMPDIR/key" "sha256:$(printf '%064d' 0)" stable-testing "$BATS_TEST_TMPDIR/logs"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Missing qcow2"* ]]
}

@test "guest checks reject malformed identity without modifying the system" {
    run bash "$REPO/scripts/verify-vm-guest.sh" nope stable
    [ "$status" -eq 2 ]
    [[ "$output" == *"Invalid identity"* ]]
}

@test "installer accepts only explicit published channels" {
    for channel in stable stable-testing; do
        run bash "$REPO/scripts/verify-vm.sh" validate "sha256:$(printf '%064d' 0)" "$channel"
        [ "$status" -eq 0 ]
    done
}

# The workflow is the only thing that turns a digest into media, so its shape is
# an interface: it must stay manual, must never rebuild an image, and must not
# hand installer media the test credentials the qcow2 carries.
@test "installer workflow consumes a digest and never builds an image" {
    wf="$REPO/.github/workflows/build-installer.yml"
    [ -f "$wf" ]

    run python3 - "$wf" "$REPO" <<'PY'
import pathlib, sys, yaml
workflow = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
repo = pathlib.Path(sys.argv[2])

# Manual dispatch only: a push must not start producing installation media.
triggers = workflow[True] if True in workflow else workflow['on']
assert list(triggers) == ['workflow_dispatch'], list(triggers)

inputs = triggers['workflow_dispatch']['inputs']
assert inputs['digest']['required'] is True
assert set(inputs['channel']['options']) == {'stable', 'stable-testing'}

steps = workflow['jobs']['installer']['steps']
bodies = [s.get('run', '') for s in steps]
joined = '\n'.join(bodies)

# It consumes a published image; it must not run a container build itself.
assert 'just build' not in joined
assert 'podman build' not in joined

# A digest-pinned origin cannot be upgraded, so the installed system has to
# track the tag, and the tag must be proven to point at the tested digest.
assert '${IMAGE}:${CHANNEL}' in joined
assert 'resolved' in joined

# Signature verification happens before the image becomes media.
policy = next(i for i, s in enumerate(steps) if 'Install the trust policy' in (s.get('name') or ''))
verify = next(i for i, s in enumerate(steps) if 'Verify the image signature' in (s.get('name') or ''))
# The builder image is named once in the workflow env and referenced as
# ${BIB_IMAGE} by the steps that run it.
assert 'bootc-image-builder' in workflow['env']['BIB_IMAGE']
first_bib = next(i for i, b in enumerate(bodies) if '${BIB_IMAGE}' in b)
assert policy < verify < first_bib
assert 'custom/files/etc/containers/keys/my-bluefin.pub' in bodies[policy]
assert 'custom/files/etc/containers/registries.d/my-bluefin.yaml' in bodies[policy]

# The gate must be containers/image, not cosign.
#
# The digest carries both a keyless and a key-based signature, and
# `cosign verify --key` rejects that combination with "expected key signature,
# not certificate". containers/image accepts it and matches the key-based layer,
# and it is what bootc calls on the device, so it is both the only workable
# check and the more faithful one. Verified by hand against the published digest.
assert 'skopeo copy' in bodies[verify]
# Check invocations, not mentions: the step explains the cosign limitation in a
# comment, and a comment is not a call.
code = '\n'.join(
    line for body in bodies for line in body.splitlines()
    if not line.lstrip().startswith('#')
)
assert 'cosign' not in code

# The shipped policy is installed verbatim, so the check exercises the file a
# booted machine uses rather than a CI-only rewrite.
assert 'install -D' in bodies[policy]

# The qcow2 gets test users and an ephemeral key; the ISO must not.
iso_step = next(b for b in bodies if '--type iso' in b)
assert 'disk.json' not in iso_step
assert 'iso/iso.toml' in iso_step
qcow2_step = next(b for b in bodies if '--type qcow2' in b)
assert 'disk.json' in qcow2_step

# Boot-testing must precede ISO construction, and the ISO must not be uploaded
# unless that test ran successfully.
boot = next(i for i, s in enumerate(steps) if (s.get('name') or '').startswith('Boot-test'))
iso_build = next(i for i, s in enumerate(steps) if '--type iso' in bodies[i])
assert boot < iso_build

upload = next(s for s in steps if (s.get('name') or '').startswith('Upload installer'))
assert 'if:' not in upload  # default success(): no ISO after a failed boot test

# Boot logs are evidence, so they survive a failure.
logs = next(s for s in steps if (s.get('name') or '').startswith('Upload boot-test logs'))
assert logs['if'] == 'always()'

# Every referenced script and config exists.
for relative in ('scripts/verify-vm.sh', 'iso/iso.toml',
                 'custom/files/etc/containers/keys/my-bluefin.pub'):
    assert (repo / relative).exists(), relative
PY
    [ "$status" -eq 0 ]
}

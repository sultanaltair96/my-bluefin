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

# The checks must observe the system the installer produced, not one the test
# rewrote first. An earlier version ran `bootc switch --mutate-in-place` to
# rewrite the origin, which cannot work here (/sysroot is read-only, so it fails
# with "Read-only file system") and would have validated a modified deployment.
# Verification is proven instead through the shipped policy, which is
# read-only and is the same mechanism bootc uses.
@test "guest checks do not mutate the deployment they verify" {
    ! grep -qE '^[[:space:]]*bootc switch' "$REPO/scripts/verify-vm-guest.sh"
    grep -q 'skopeo copy' "$REPO/scripts/verify-vm-guest.sh"
    grep -q 'sigstoreSigned' "$REPO/scripts/verify-vm-guest.sh"
}

# containers/image rejects `repo:tag@sha256:...` with "Docker references with both
# a tag and digest are currently not supported", so a digest may only ever be
# appended to the bare repository. Passing the tagged reference is the natural
# mistake and it fails immediately, which is how this was found.
@test "guest verification appends the digest to the repository, not the tag" {
    grep -q 'repo=ghcr.io/sultanaltair96/my-bluefin' "$REPO/scripts/verify-vm-guest.sh"
    grep -qF 'docker://${repo}@${digest}' "$REPO/scripts/verify-vm-guest.sh"
    ! grep -qF 'docker://${ref}@' "$REPO/scripts/verify-vm-guest.sh"
    ! grep -qE ':\$?\{?channel\}@sha256' "$REPO/scripts/verify-vm-guest.sh"
}

# `rpm -q --whatprovides "kernel-uname-r = <uname -r>"` matches nothing, even on a
# machine where kernel-core plainly provides that capability and the NVIDIA driver
# is loaded. It cost a full VM cycle to find, because it fails inside the guest
# long after the interesting checks have passed. Compare the installed package's
# NEVR against the running kernel instead.
@test "guest kernel check does not use the versioned whatprovides form" {
    ! grep -q 'whatprovides "kernel-uname-r = ' "$REPO/scripts/verify-vm-guest.sh"
    grep -qF "rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\\n'" "$REPO/scripts/verify-vm-guest.sh"
    grep -q 'grep -qx "$kernel"' "$REPO/scripts/verify-vm-guest.sh"
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
verify = next(i for i, s in enumerate(steps) if 'Verify the image signature' in (s.get('name') or ''))
# The builder image is named once in the workflow env and referenced as
# ${BIB_IMAGE} by the steps that run it.
assert 'bootc-image-builder' in workflow['env']['BIB_IMAGE']
first_bib = next(i for i, b in enumerate(bodies) if '${BIB_IMAGE}' in b)
assert verify < first_bib

# The gate is the shared script, which installs the shipped trust material and
# verifies through containers/image. cosign cannot be the gate: the digest
# carries a keyless and a key-based signature on purpose, and `cosign verify
# --key` rejects that combination with "expected key signature, not certificate".
# See scripts/verify-image-signature.sh, checked by hand against the published
# digest and against an unsigned one.
assert 'scripts/verify-image-signature.sh' in bodies[verify]
assert 'custom/files/etc/containers/keys/my-bluefin.pub' not in bodies[verify]

# The qcow2 gets test users and an ephemeral key; the ISO must not.
iso_step = next(b for b in bodies if '--type iso' in b)
assert 'disk.json' not in iso_step
assert 'iso/iso.toml' in iso_step
qcow2_step = next(b for b in bodies if '--type qcow2' in b)
assert 'disk.json' in qcow2_step

# The builder reads its config inside its own container, so --config must name an
# in-container path backed by a mount, and the builder picks its parser from the
# extension. Both mistakes were made here and each failed only at runtime:
# a host path gives "cannot read config: ... no such file or directory", and
# JSON mounted at /config.toml gives "expected '.' or '='".
import re
for body in bodies:
    if '--config' not in body:
        continue
    mount = re.search(r'(\S+?):(/config\.\w+):ro', body)
    assert mount, body
    source, destination = mount.group(1), mount.group(2)
    assert source.endswith(destination.replace('/config', '')), (source, destination)
    argument = re.search(r'--config\s+(\S+)', body)
    assert argument and argument.group(1) == destination, body

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

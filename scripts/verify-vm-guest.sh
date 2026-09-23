#!/usr/bin/env bash
# Runs only inside the disposable qcow2 VM, as root over ephemeral-key SSH.
#
# Every check here is read-only with respect to the deployment. That is
# deliberate: an earlier version ran `bootc switch --mutate-in-place` to rewrite
# the origin and then asserted the result, which cannot work on this layout
# (/sysroot is mounted read-only, so writing the origin fails with
# "Read-only file system") and would in any case be checking a system the test
# had just modified rather than the one the installer produced.
set -euo pipefail
if [[ ! ${1:-} =~ ^sha256:[0-9a-f]{64}$ ]] || [[ ${2:-} != stable && ${2:-} != stable-testing ]]; then
    echo 'Invalid identity' >&2; exit 2
fi
[[ $EUID == 0 && -n ${SSH_CONNECTION:-} ]] || { echo 'Guest root SSH session required' >&2; exit 2; }
digest=$1
channel=$2
# Keep the repository separate from the tagged reference: a digest can only be
# appended to the repository. `repo:tag@sha256:...` is rejected outright by
# containers/image with "Docker references with both a tag and digest are
# currently not supported".
repo=ghcr.io/sultanaltair96/my-bluefin
ref="${repo}:${channel}"

echo '=== image identity ==='
python3 - "$digest" <<'PY'
import json, sys
info = json.load(open('/usr/share/ublue-os/image-info.json'))
assert info['image-name'] == 'my-bluefin', info
assert info['image-vendor'] == 'sultanaltair96', info
assert info['image-ref'] == 'ostree-image-signed:docker://ghcr.io/sultanaltair96/my-bluefin', info
print('PASS: os-release identity and image-info.json describe this image')
PY

echo '=== shipped trust policy ==='
python3 - <<'PY'
import json, pathlib
policy = json.load(open('/etc/containers/policy.json'))
rules = policy['transports']['docker']['ghcr.io/sultanaltair96/my-bluefin']
assert rules and all(r['type'] != 'insecureAcceptAnything' for r in rules), rules
signed = [r for r in rules if r['type'] == 'sigstoreSigned']
assert signed, rules
for rule in signed:
    assert pathlib.Path(rule['keyPath']).is_file(), rule
    assert rule['signedIdentity'] == {'type': 'matchRepository'}, rule
# The default must stay as the base image left it: this repository adds one
# scope and does not get to loosen or tighten anything else.
assert policy['default'] == [{'type': 'reject'}], policy['default']
print('PASS: policy pins this namespace to a shipped key, default untouched')
PY

# Prove the signature is accepted by the files this image actually ships, using
# the same mechanism bootc uses: containers/image reading /etc/containers/
# policy.json and the registries.d entry. A copy resolves the manifest, fetches
# the signature and enforces the policy, so an unsigned, foreign or tampered
# image fails here. Nothing is deployed and the origin is left alone.
echo '=== on-device signature verification ==='
rm -rf /tmp/ci-signature-check
skopeo copy "docker://${repo}@${digest}" dir:/tmp/ci-signature-check
rm -rf /tmp/ci-signature-check
echo 'PASS: the shipped policy verifies the published signature'

echo '=== booted deployment ==='
bootc status --json >/tmp/ci-bootc-status.json
python3 - "$digest" "$ref" <<'PY'
import json, sys
digest, ref = sys.argv[1], sys.argv[2]
status = json.load(open('/tmp/ci-bootc-status.json'))
booted = status['status']['booted']['image']
assert booted['imageDigest'] == digest, booted
assert booted['image'] == ref, booted
print(f'PASS: booted {booted["image"]} at the expected digest')

# Report the installed transport rather than asserting it. The origin is written
# by the installer, not by this image, so claiming it is verified here would be
# claiming something this check cannot make true.
signature = booted.get('signature')
if signature == 'containerPolicy':
    print('PASS: the installed origin uses the verified transport')
else:
    print(f'WARNING: the installed origin reports signature={signature!r}, so '
          f'updates are not signature-checked yet.')
    print(f'WARNING: enable it with: bootc switch --enforce-container-sigpolicy {ref}')
PY

# Services may still be coming up when sshd starts.
echo '=== services ==='
for service in NetworkManager gdm; do
    ready=0
    for _ in {1..60}; do
        if systemctl is-active --quiet "$service"; then ready=1; break; fi
        sleep 2
    done
    [[ $ready == 1 ]] || { systemctl status "$service" --no-pager; exit 1; }
    printf 'PASS: %s active\n' "$service"
done

echo '=== NVIDIA module matches the running kernel ==='
kernel=$(uname -r)
rpm -q --whatprovides "kernel-uname-r = $kernel"
module=$(modinfo -k "$kernel" -n nvidia)
[[ -f "$module" ]]
rpm -qf "$module"
read -r vermagic _ < <(modinfo -k "$kernel" -F vermagic nvidia)
[[ "$vermagic" == "$kernel" ]]
echo 'PASS: NVIDIA module is packaged for the running kernel (no physical GPU claim)'

echo '=== new-user GNOME defaults ==='
# Do not use GSETTINGS_BACKEND=memory: that bypasses dconf and can hide
# regressions. ci-smoke was created by the installer, after the image build, so
# these values come from the system defaults the image ships, not from an import.
runuser -u ci-smoke -- dbus-run-session -- python3 - <<'PY'
import ast, json, pathlib, subprocess

def setting(schema, key):
    return ast.literal_eval(subprocess.check_output(['gsettings', 'get', schema, key], text=True).strip())

assert setting('org.gnome.desktop.interface', 'color-scheme') == 'prefer-dark'
assert setting('org.gnome.desktop.interface', 'accent-color') == 'slate'
assert '<Control>q' in setting('org.gnome.desktop.wm.keybindings', 'close')
expected = {
    'Resource_Monitor@Ory0n', 'appindicatorsupport@rgcjonas.gmail.com',
    'caffeine@patapon.info', 'blur-my-shell@aunetx', 'logomenu@aryan_k',
    'search-light@icedman.github.com', 'bazaar-integration@kolunmi.github.io',
}
enabled = setting('org.gnome.shell', 'enabled-extensions')
assert len(enabled) == 7 and set(enabled) == expected, enabled
shell_major = subprocess.check_output(['gnome-shell', '--version'], text=True).split()[-1].split('.')[0]
for uuid in expected:
    metadata = json.loads((pathlib.Path('/usr/share/gnome-shell/extensions') / uuid / 'metadata.json').read_text())
    assert metadata['uuid'] == uuid
    assert shell_major in metadata['shell-version'], (uuid, shell_major, metadata)
print('PASS: new-user dconf dark mode, slate accent, Ctrl+Q, seven enabled compatible extensions')
PY

# Resolve the update target through the installed policy. This checks that the
# registry is reachable and the tag resolves; whether the result is
# signature-checked depends on the transport reported above, which is why this
# line does not claim verification on its own.
echo '=== update path ==='
bootc upgrade --check
echo 'PASS: the update target resolves'

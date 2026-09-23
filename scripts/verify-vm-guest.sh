#!/usr/bin/env bash
# Runs only inside the disposable qcow2 VM, as root over ephemeral-key SSH.
set -euo pipefail
if [[ ! ${1:-} =~ ^sha256:[0-9a-f]{64}$ ]] || [[ ${2:-} != stable && ${2:-} != stable-testing ]]; then
    echo 'Invalid identity' >&2; exit 2
fi
[[ $EUID == 0 && -n ${SSH_CONNECTION:-} ]] || { echo 'Guest root SSH session required' >&2; exit 2; }
digest=$1
ref="ghcr.io/sultanaltair96/my-bluefin:$2"

# Mirror the Anaconda %post fixup. BIB's default origin is unverified.
# This changes origin metadata, not the booted content, and fetches no new tag.
bootc switch --mutate-in-place --enforce-container-sigpolicy "$ref"
bootc status --json > /tmp/ci-bootc-status.json
python3 - "$digest" "$ref" <<'PY'
import json, pathlib, sys
s = json.load(open('/tmp/ci-bootc-status.json'))
booted = s['status']['booted']['image']
assert booted['imageDigest'] == sys.argv[1], booted
for image in (booted['image'], s['spec']['image']):
    assert image['image'] == sys.argv[2], image
    assert image['signature'] == 'containerPolicy', image
info = json.load(open('/usr/share/ublue-os/image-info.json'))
assert info['image-name'] == 'my-bluefin', info
assert info['image-vendor'] == 'sultanaltair96', info
assert info['image-ref'] == 'ostree-image-signed:docker://ghcr.io/sultanaltair96/my-bluefin', info
policy = json.load(open('/etc/containers/policy.json'))
rules = policy['transports']['docker']['ghcr.io/sultanaltair96/my-bluefin']
assert rules and all(r['type'] != 'insecureAcceptAnything' for r in rules), rules
signed = [r for r in rules if r['type'] == 'sigstoreSigned']
assert signed, rules
for rule in signed:
    assert pathlib.Path(rule['keyPath']).is_file(), rule
print('PASS: booted digest, image identity, tagged origin and signature policy')
PY

# Services may still be coming up when sshd starts.
for service in NetworkManager gdm; do
    ready=0
    for _ in {1..60}; do
        if systemctl is-active --quiet "$service"; then ready=1; break; fi
        sleep 2
    done
    [[ $ready == 1 ]] || { systemctl status "$service" --no-pager; exit 1; }
    printf 'PASS: %s active\n' "$service"
done
kernel=$(uname -r)
rpm -q --whatprovides "kernel-uname-r = $kernel"
module=$(modinfo -k "$kernel" -n nvidia)
[[ -f "$module" ]]
rpm -qf "$module"
read -r vermagic _ < <(modinfo -k "$kernel" -F vermagic nvidia)
[[ "$vermagic" == "$kernel" ]]
echo 'PASS: NVIDIA module is packaged for the running kernel (no physical GPU claim)'

# Do not use GSETTINGS_BACKEND=memory: that bypasses dconf and can hide regressions.
# ci-smoke was created by BIB, after the image build; no settings import is run.
runuser -u ci-smoke -- dbus-run-session -- python3 - <<'PY'
import ast, json, pathlib, subprocess

def setting(schema, key):
    return ast.literal_eval(subprocess.check_output(['gsettings', 'get', schema, key], text=True).strip())

assert setting('org.gnome.desktop.interface', 'color-scheme') == 'prefer-dark'
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
print('PASS: new-user dconf dark mode, Ctrl+Q, seven enabled compatible extensions')
PY
# Check the real registry through the installed signature policy. No layers are
# downloaded; failure (including unavailable/missing signatures) is fatal.
bootc upgrade --check
printf 'PASS: signed update check\n'

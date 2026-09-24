#!/usr/bin/env bash
set -euo pipefail

validate() {
    [[ ${1:-} =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'Invalid digest: expected sha256 and 64 lowercase hex digits' >&2; return 2; }
    [[ ${2:-} == stable || ${2:-} == stable-testing ]] || { echo 'Invalid channel: expected stable or stable-testing' >&2; return 2; }
}

case "${1:-}" in
    validate) validate "${2:-}" "${3:-}" ;;
    config)
        python3 - "${2:?public key file required}" "${3:?output JSON required}" <<'PY'
import json, pathlib, sys
key = pathlib.Path(sys.argv[1]).read_text().strip()
if not key.startswith('ssh-ed25519 ') or '\n' in key:
    raise SystemExit('Expected a single Ed25519 public key')
config = {'customizations': {
    'user': [{'name': name, 'key': key, 'groups': []} for name in ('root', 'ci-smoke')],
    'kernel': {'append': 'console=tty0 console=ttyS0,115200n8 systemd.wants=sshd.service'},
    'filesystem': [{'mountpoint': '/', 'minsize': '40 GiB'}],
}}
pathlib.Path(sys.argv[2]).write_text(json.dumps(config, indent=2) + '\n')
PY
        ;;
    run)
        disk=${2:?qcow2 required}; key=${3:?SSH private key required}
        digest=${4:?digest required}; channel=${5:?channel required}; logs=${6:?log directory required}
        validate "$digest" "$channel"
        [[ -f "$disk" ]] || { echo "Missing qcow2: $disk" >&2; exit 1; }
        [[ -f "$key" ]] || { echo "Missing SSH key: $key" >&2; exit 1; }
        for tool in qemu-system-x86_64 ssh timeout python3; do
            command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
        done
        mkdir -p "$logs"
        logs=$(realpath "$logs"); disk=$(realpath "$disk"); key=$(realpath "$key")
        work=$(mktemp -d)
        pid=''
        cleanup() {
            if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
            rm -rf "$work"
        }
        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        code=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
        vars=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
        [[ -f "$code" && -f "$vars" ]] || { echo 'Missing matching OVMF CODE/VARS pair' >&2; exit 1; }
        cp "$vars" "$work/vars.fd"
        accel=tcg; cpu=max
        if [[ -r /dev/kvm && -w /dev/kvm ]]; then accel=kvm; cpu=host; fi
        port=${VM_SSH_PORT:-2222}
        [[ "$port" =~ ^[0-9]+$ && "$port" -gt 1024 && "$port" -lt 65536 ]] || exit 2
        printf 'acceleration=%s memory=6144MiB cpus=2\n' "$accel" > "$logs/vm-config.log"
        qemu-system-x86_64 -machine q35 -accel "$accel" -cpu "$cpu" -smp 2 -m 6144 \
            -drive "if=pflash,format=raw,readonly=on,file=$code" \
            -drive "if=pflash,format=raw,file=$work/vars.fd" \
            -drive "file=$disk,if=virtio,format=qcow2" -snapshot \
            -device virtio-vga -device virtio-net-pci,netdev=net0 \
            -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22" \
            -display none -monitor none -serial "file:$logs/serial.log" \
            > "$logs/qemu.log" 2>&1 &
        pid=$!
        ssh_args=(-i "$key" -p "$port" -o BatchMode=yes -o IdentitiesOnly=yes
            -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$work/known_hosts"
            -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=8
            -o TCPKeepAlive=yes)
        # First boot is slow under software emulation: the runner has no KVM, and
        # first-boot units (Flatpak provisioning, and a repeated nvidia-cdi-refresh
        # attempt on a machine with no GPU) compete for CPU. Allow generously.
        deadline=$((SECONDS + ${VM_BOOT_TIMEOUT:-1800}))
        ready=0
        while (( SECONDS < deadline )); do
            kill -0 "$pid" 2>/dev/null || { echo 'QEMU exited before SSH; see qemu.log' >&2; exit 1; }
            if ssh "${ssh_args[@]}" ci-smoke@127.0.0.1 true >> "$logs/ssh.log" 2>&1; then ready=1; break; fi
            sleep 5
        done
        [[ "$ready" == 1 ]] || { echo 'Timed out waiting for guest SSH' >&2; exit 1; }
        guest_script=$(dirname "$(realpath "$0")")/verify-vm-guest.sh
        # The checks resolve the image manifest and signature over the guest's
        # user-mode network while the guest is still busy with first boot, so a
        # single attempt is not reliable: sshd can go briefly unresponsive under
        # load and the connection then dies mid-run. Retry the whole check and
        # report only the last result, appending each attempt so a later reader
        # can see what happened rather than just the final failure.
        #
        # The signature check inside the guest copies the published image through
        # the shipped policy, which means fetching and unpacking its layers under
        # software emulation. That is the slowest part of the run, so the attempt
        # timeout is generous rather than tight.
        #
        # The guest's user-mode network comes up independently of sshd, so the
        # first check can meet a registry that is not yet reachable: in one run
        # attempts 1 and 3 died on a TLS handshake timeout while attempt 2 got
        # through every check. Wait for the registry to answer before spending an
        # attempt, and widen the backoff, so a slow network does not quietly
        # consume the retry budget and look like a policy failure.
        #
        # The gate is advisory and best-effort, and its result is not trusted in
        # either direction: curl's exit status is 0 for any HTTP reply, so this
        # tests reachability and TLS rather than authorisation, and under
        # first-boot load it has reported unreachable on a guest whose signature
        # check then passed immediately -- first-boot units saturate the CPU and
        # the user-mode network, so a 20s curl can lose a race that a later
        # transfer wins. Its only job is to avoid spending an attempt on a
        # registry that is plainly cold, so keep the cost small and never block
        # on it: the retry loop below is what actually absorbs a cold network.
        network_deadline=$(( SECONDS + ${VM_NETWORK_TIMEOUT:-120} ))
        network_ready=0
        while (( SECONDS < network_deadline )); do
            if timeout 60 ssh "${ssh_args[@]}" root@127.0.0.1 \
                'curl -sS --max-time 20 -o /dev/null https://ghcr.io/v2/' \
                >> "$logs/ssh.log" 2>&1; then
                network_ready=1
                break
            fi
            sleep 10
        done
        printf 'registry reachable from guest before checks: %s\n' "$network_ready" \
            >> "$logs/checks.log"
        result=0
        attempts=${VM_CHECK_ATTEMPTS:-5}
        for attempt in $(seq 1 "$attempts"); do
            printf '=== check attempt %s/%s ===\n' "$attempt" "$attempts" >> "$logs/checks.log"
            result=0
            timeout "${VM_CHECK_TIMEOUT:-1500}" ssh "${ssh_args[@]}" root@127.0.0.1 \
                bash -s -- "$digest" "$channel" \
                < "$guest_script" >> "$logs/checks.log" 2>&1 || result=$?
            [[ "$result" == 0 ]] && break
            printf 'check attempt %s/%s failed with %s\n' "$attempt" "$attempts" "$result" >&2
            (( attempt < attempts )) && sleep $(( attempt * 30 ))
        done
        timeout 60 ssh "${ssh_args[@]}" root@127.0.0.1 \
            'journalctl -b --no-pager; bootc status --json; systemctl --failed --no-pager' \
            > "$logs/journal.log" 2>&1 || true
        if [[ "$result" != 0 ]]; then echo "Guest checks failed ($result); see checks.log" >&2; exit "$result"; fi
        printf 'VM smoke checks passed\n' | tee "$logs/result.log"
        ;;
    *) echo 'Usage: verify-vm.sh {validate DIGEST CHANNEL|config PUBLIC_KEY OUTPUT_JSON|run QCOW2 KEY DIGEST CHANNEL LOG_DIR}' >&2; exit 2 ;;
esac

#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 <x86_64|aarch64>" >&2
}

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ $# -ne 1 ]]; then
    usage
    exit 2
fi

architecture=$1
case "$architecture" in
    x86_64)
        expected_uname=x86_64
        expected_deb=amd64
        qemu=qemu-system-x86_64
        machine=q35
        ;;
    aarch64)
        expected_uname=aarch64
        expected_deb=arm64
        qemu=qemu-system-aarch64
        machine=virt
        ;;
    *)
        usage
        exit 2
        ;;
esac

# Release acceptance depends on the package and firmware paths provided by Ubuntu.
# Keep this probe identical on manually prepared runners and in the workflow.
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || {
    echo "release runner must use Ubuntu; found ${PRETTY_NAME:-unknown}" >&2
    exit 1
}
[[ "$(uname -m)" == "$expected_uname" ]] || {
    echo "release runner architecture mismatch: expected $expected_uname, found $(uname -m)" >&2
    exit 1
}
[[ "$(dpkg --print-architecture)" == "$expected_deb" ]] || {
    echo "release runner Debian architecture mismatch" >&2
    exit 1
}
sudo -n true
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || {
    echo "/dev/kvm must be a readable and writable character device" >&2
    exit 1
}
command -v "$qemu" >/dev/null
command -v timeout >/dev/null

probe_log=$(mktemp)
trap 'rm -f -- "$probe_log"' EXIT

status=0
timeout --signal=TERM --kill-after=2s 2s "$qemu" \
    -machine "$machine,accel=kvm" \
    -cpu host \
    -nodefaults \
    -display none \
    -monitor none \
    -serial none \
    -S >"$probe_log" 2>&1 || status=$?
if [[ $status -ne 124 ]]; then
    cat "$probe_log" >&2
    echo "QEMU did not remain running with KVM (exit $status)" >&2
    exit 1
fi

echo "Azure Linux 4 release runner ready: architecture=$architecture accelerator=kvm"

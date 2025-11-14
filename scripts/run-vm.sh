#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2025 Vasiliy Kovalev <kovalev@altlinux.org>

set -exo pipefail
source "$(dirname "$0")/01-setup-env.sh"
source "$(dirname "$0")/../project.env"

help() {
    echo "Usage: $0 [-p PORT]"
    echo ""
    echo "Starts a QEMU VM for manual testing."
    echo ""
    echo "Options:"
    echo "  -p PORT    Specify the host port to forward for SSH (default from project.env: $DEFAULT_VM_SSH_PORT)."
    echo "  -h         Show this help message."
}

PORT=$DEFAULT_VM_SSH_PORT
while getopts "hp:" opt; do
    case ${opt} in
        h) help; exit 0 ;;
        p) PORT=$OPTARG ;;
        \?) echo "Invalid option -$OPTARG" >&2; help; exit 1 ;;
    esac
done

echo "▶ Starting QEMU VM..."
echo "➡️ SSH will be available on host port: $PORT"

rm -f "$DEBUG_VM_LOG_FILE"

script -q -c "
\"$QEMU_BUILD_DIR\"/usr/bin/qemu-system-x86_64 \
    -hda \"$IMAGE_PATH\" \
    -kernel \"$KERNEL_BZIMAGE\" \
    -m 4G \
    -smp 4 \
    -enable-kvm \
    -cpu host \
    -netdev user,id=net0,hostfwd=tcp::${PORT}-:22 \
    -device virtio-net,netdev=net0 \
    -append 'root=/dev/sda3 console=ttyS0 i2c-stub.chip_addr=0x48,0x49' \
    -nographic
" "$DEBUG_VM_LOG_FILE"

echo "VM has been shut down. Log is at $DEBUG_VM_LOG_FILE"

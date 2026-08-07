#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# vm-lib.sh — boot the guest image in the background and drive it over SSH.
#
# This mirrors the QEMU invocation of scripts/run-vm.sh but runs headless so a
# caller (scripts/06-run-unit-tests.sh) can boot the VM, push work in, run
# commands and shut it down non-interactively.
#
# Source order matters: the caller must have sourced project.env and
# scripts/01-setup-env.sh first (for QEMU_BUILD_DIR, IMAGE_PATH, KERNEL_BZIMAGE,
# SSH_KEY_PATH and DEFAULT_VM_SSH_PORT).

# Host port forwarded to the guest's sshd; defaults to the project-wide value.
VM_SSH_PORT="${VM_SSH_PORT:-$DEFAULT_VM_SSH_PORT}"
VM_PID=""

_vm_ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=5 -i "$SSH_KEY_PATH" -p "$VM_SSH_PORT")

# vm_boot [boot_log] — start QEMU headless and wait until sshd answers.
# Before starting, we evict any leftover QEMU from a previous --keep-vm run.
# Without this, the new QEMU fails to bind the host forwarding port and the
# orchestrator silently connects to the stale VM, causing stale-module coverage.
vm_boot() {
    local boot_log="${1:-$DEBUG_VM_LOG_FILE}"
    [ -e /dev/kvm ] || echo "⚠️  /dev/kvm not present — QEMU will be slow or fail." >&2

    # Evict any QEMU still holding the SSH forwarding port.
    if command -v fuser >/dev/null 2>&1; then
        fuser -k "${VM_SSH_PORT}/tcp" >/dev/null 2>&1 || true
    else
        # fuser not available: try pkill by port via ss/lsof
        _old=$(ss -tlnp 2>/dev/null \
               | awk -v p=":${VM_SSH_PORT}" '$0~p{match($0,/pid=([0-9]+)/,a); print a[1]}')
        [ -n "$_old" ] && kill "$_old" 2>/dev/null || true
    fi
    sleep 1   # give the port a moment to free

    rm -f "$boot_log"

    "$QEMU_BUILD_DIR"/usr/bin/qemu-system-x86_64 \
        -hda "$IMAGE_PATH" \
        -kernel "$KERNEL_BZIMAGE" \
        -m 4G \
        -smp 4 \
        -enable-kvm \
        -cpu host \
        -netdev user,id=net0,hostfwd=tcp::"${VM_SSH_PORT}"-:22 \
        -device virtio-net,netdev=net0 \
        -append 'root=/dev/sda3 console=ttyS0' \
        -display none \
        -serial file:"$boot_log" &
    VM_PID=$!

    echo "▶ Booting VM (pid $VM_PID), waiting for SSH on port $VM_SSH_PORT..."
    local i
    for i in $(seq 1 90); do
        if ! kill -0 "$VM_PID" 2>/dev/null; then
            echo "❌ QEMU exited during boot. See $boot_log" >&2
            return 1
        fi
        if ssh -q "${_vm_ssh_opts[@]}" root@localhost true 2>/dev/null; then
            echo "✅ VM is up."
            return 0
        fi
        sleep 4
    done
    echo "❌ VM did not become reachable in time. See $boot_log" >&2
    return 1
}

# vm_ssh CMD... — run a command in the guest as root.
vm_ssh() {
    ssh -q "${_vm_ssh_opts[@]}" root@localhost "$@"
}

# vm_scp_to LOCAL REMOTE — copy from host into the guest.
vm_scp_to() {
    scp -q -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i "$SSH_KEY_PATH" -P "$VM_SSH_PORT" "$1" root@localhost:"$2"
}

# vm_scp_from REMOTE LOCAL — copy from the guest to the host.
vm_scp_from() {
    scp -q -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i "$SSH_KEY_PATH" -P "$VM_SSH_PORT" root@localhost:"$1" "$2"
}

# vm_poweroff — ask the guest to power off, then make sure QEMU is gone.
vm_poweroff() {
    [ -n "$VM_PID" ] || return 0
    vm_ssh 'poweroff' 2>/dev/null || true
    local i
    for i in $(seq 1 15); do
        kill -0 "$VM_PID" 2>/dev/null || { VM_PID=""; return 0; }
        sleep 2
    done
    kill "$VM_PID" 2>/dev/null || true
    VM_PID=""
}

#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2025 Vasiliy Kovalev <kovalev@altlinux.org>

set -e
source "$(dirname "$0")/../project.env"
# Sourcing this second to get SSH_KEY_PATH which is set up inside the container
source "$(dirname "$0")/../scripts/01-setup-env.sh" &>/dev/null

help() {
    echo "Usage: $0 [-p PORT]"
    echo ""
    echo "Connects to the running VM via SSH."
    echo ""
    echo "Options:"
    echo "  -p PORT    Specify the VM's SSH port (default: $DEFAULT_VM_SSH_PORT)."
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

HOST_KERNEL_DIR="$KERNEL_DIR"
HOST_KERNEL_BUILD_DIR="$KERNEL_BUILD_DIR"

VM_KERNEL_DIR_TAG="kernel_dir"
VM_KERNEL_DIR="$HOST_KERNEL_DIR"

echo "------------------------------------------"
echo "  host kernel directory is: $HOST_KERNEL_DIR"
echo "  9P mount tag is:          $VM_KERNEL_DIR_TAG"
echo "---- run this commands to collect kernel coverage:"
echo "  mkdir -p ${VM_KERNEL_DIR}"
echo "  mount -t 9p -o trans=virtio,version=9p2000.L kernel_dir ${VM_KERNEL_DIR}"
echo "  git clone https://github.com/kovalev0/usb-gadget-tests.git && cd ./usb-gadget-tests"
echo "----"
echo "  TEST_NAME=\"\"   , example: TEST_NAME=\"sisusbvga-FULL_SPEED\""
echo "  echo \${TEST_NAME} > tests/list.txt && make \${TEST_NAME} && ./check.sh"
echo "  SRC_PATH=\"\"    , example: SRC_PATH=\"drivers/usb/misc/sisusbvga/\""
echo "  LCOV_FILTER=\"\" , example: LCOV_FILTER=\"*sisusbvga*\" "
echo "  lcov -c -d /sys/kernel/debug/gcov/${HOST_KERNEL_BUILD_DIR}/\${SRC_PATH} -o coverage.info"
echo "  lcov --extract coverage.info \"\${LCOV_FILTER}\" -o coverage.\${TEST_NAME}"
echo "  genhtml coverage.\${TEST_NAME} --output-directory report_coverage.\${TEST_NAME}"
echo "  tar -czf report_coverage.\${TEST_NAME}.tar.gz report_coverage.\${TEST_NAME} --remove-files"
echo "------------------------------------------"

echo "▶ Connecting to VM via SSH on port $PORT..."
ssh -i "$SSH_KEY_PATH" \
    -p "$PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    root@localhost

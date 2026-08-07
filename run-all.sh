#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2025 Vasiliy Kovalev <kovalev@altlinux.org>

set -eo pipefail
source "$(dirname "$0")/project.env"

help() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Main control script for the fuzzing environment. Runs specified commands or all if none are provided."
    echo ""
    echo "Commands:"
    echo "  build         Build the Docker image."
    echo "  container     Run the Docker container."
    echo "  setup         Run all setup scripts inside the container (kernel, qemu, syzkaller, image)."
    echo "  kernel        Build the kernel."
    echo "  qemu          Build the qemu."
    echo "  syzkaller     Build syzkaller."
    echo "  image         Prepare the guest image."
    echo "  fuzzer        Start the fuzzer in the background."
    echo "  unit-tests    Build a gcov kernel, build the out-of-tree target modules,"
    echo "                run their tests in a VM and collect per-module coverage."
    echo "  all           Run all stages: build, container, setup, fuzzer (default)."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message."
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    help
    exit 0
fi

COMMAND=${1:-all}
CONTAINER_NAME=$DEFAULT_CONTAINER_NAME

run_build() {
    echo "▶ (build) Building Docker image..."
    ./build-docker-image.sh
}

run_container() {
    if [ "$(docker ps -q -f name=^${CONTAINER_NAME}$)" ]; then
        echo "ℹ️ (run) Container '$CONTAINER_NAME' is already running. Skipping."
    else
        echo "▶ (run) Starting Docker container..."
        ./run-container.sh
    fi
}

exec_in_container() {
    echo "▶ ($1) Executing setup script..."
    docker exec "$CONTAINER_NAME" "./scripts/0${2}-build-${1}.sh"
}

run_fuzzer() {
    echo "🚀 (fuzzer) Launching the fuzzer in the background..."
    docker exec -d "$CONTAINER_NAME" sh -c './scripts/start-fuzzer.sh > /tmp/alt-syz-box.log 2>&1'
    echo "✅ Fuzzing process started. Monitor with './monitor-fuzzer.sh'."
    echo "🌍 Web UI is available at http://localhost:${DEFAULT_WEB_PORT}"
}

case "$COMMAND" in
    build)
        run_build
        ;;
    container)
        run_container
        ;;
    kernel|qemu|syzkaller|image)
        run_container
        STEP_NUM=$(case $COMMAND in kernel) echo 2;; qemu) echo 3;; syzkaller) echo 4;; image) echo 5;; esac)
        exec_in_container "$COMMAND" "$STEP_NUM"
        ;;
    setup)
        run_container
        exec_in_container "kernel" "2"
        exec_in_container "qemu" "3"
        exec_in_container "syzkaller" "4"
        exec_in_container "image" "5"
        ;;
    fuzzer)
        run_container
        run_fuzzer
        ;;
    unit-tests)
        run_build
        run_container
        echo "▶ (unit-tests) Running the unit-test coverage flow inside the container..."
        docker exec \
            ${TARGETS:+-e "TARGETS=$TARGETS"} \
            ${ENABLE_SANITIZERS:+-e "ENABLE_SANITIZERS=$ENABLE_SANITIZERS"} \
            "$CONTAINER_NAME" "./scripts/06-run-unit-tests.sh" "${@:2}"
        echo "ℹ️ Coverage reports are under ./volume/unit-tests/<target>/reports/ on the host."
        ;;
    all)
        run_build
        run_container
        exec_in_container "kernel" "2"
        exec_in_container "qemu" "3"
        exec_in_container "syzkaller" "4"
        exec_in_container "image" "5"
        run_fuzzer
        ;;
    *)
        echo "Error: Unknown command '$COMMAND'"
        help
        exit 1
        ;;
esac

echo "✅ Command '$COMMAND' finished."

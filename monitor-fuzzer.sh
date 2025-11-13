#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2025 Vasiliy Kovalev <kovalev@altlinux.org>

source "$(dirname "$0")/project.env"

help() {
    echo "Usage: $0 [CONTAINER_NAME]"
    echo "Tails the fuzzer's log file from inside the container."
    echo "Defaults to CONTAINER_NAME from project.env ('$DEFAULT_CONTAINER_NAME')."
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    help
    exit 0
fi

CONTAINER_NAME=${1:-$DEFAULT_CONTAINER_NAME}

echo "▶ Tailing fuzzer log from container '$CONTAINER_NAME'. Press Ctrl+C to exit."
docker exec -it "$CONTAINER_NAME" tail -f /tmp/alt-syz-box.log

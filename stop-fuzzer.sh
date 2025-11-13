#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2025 Vasiliy Kovalev <kovalev@altlinux.org>

source "$(dirname "$0")/project.env"

help() {
    echo "Usage: $0 [CONTAINER_NAME]"
    echo "Stops the syz-manager process inside the running container."
    echo "Defaults to CONTAINER_NAME from project.env ('$DEFAULT_CONTAINER_NAME')."
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    help
    exit 0
fi

CONTAINER_NAME=${1:-$DEFAULT_CONTAINER_NAME}

echo "▶ Stopping syz-manager in container '$CONTAINER_NAME'..."
docker exec -it "$CONTAINER_NAME" sh -c 'pkill -9 syz-manager || true'
echo "✅ Stop command sent."

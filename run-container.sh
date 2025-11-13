#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2025 Vasiliy Kovalev <kovalev@altlinux.org>

set -e
source "$(dirname "$0")/project.env"

help() {
    echo "Usage: $0 [CONTAINER_NAME] [IMAGE_NAME]"
    echo ""
    echo "Runs the Docker container in detached mode."
    echo "Arguments are optional and default to values from project.env."
    echo "  - CONTAINER_NAME: '${DEFAULT_CONTAINER_NAME}'"
    echo "  - IMAGE_NAME:     '${DEFAULT_IMAGE_NAME}'"
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message."
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    help
    exit 0
fi

CONTAINER_NAME=${1:-$DEFAULT_CONTAINER_NAME}
IMAGE_NAME=${2:-$DEFAULT_IMAGE_NAME}

if [ "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
    echo "ℹ️ Container '$CONTAINER_NAME' is already running."
    exit 0
fi

if [ "$(docker ps -aq -f status=exited -f name=$CONTAINER_NAME)" ]; then
    echo "🗑️ Removing existing stopped container '$CONTAINER_NAME'..."
    docker rm "$CONTAINER_NAME"
fi

if [ ! -d ./volume ]; then
    echo "📁 Creating local './volume' directory for persistent storage..."
    mkdir ./volume
fi

echo "▶ Starting container '$CONTAINER_NAME' from image '$IMAGE_NAME'..."
docker run -d \
    --name "$CONTAINER_NAME" \
    --privileged \
    --group-add "$(stat -c "%g" /dev/kvm)" \
    --group-add "$(stat -c "%g" /dev/loop0)" \
    -p "${DEFAULT_WEB_PORT}:${DEFAULT_SYZ_HTTP_INTERNAL_PORT}" \
    -p "${DEFAULT_VM_SSH_PORT}:${DEFAULT_VM_SSH_PORT}" \
    -v ./volume:/home/user/volume:Z \
    "$IMAGE_NAME" \
    tail -f /dev/null # Keep container running

echo "✅ Container '$CONTAINER_NAME' started."
echo "➡️ To get a shell inside, run: ./enter-container.sh"

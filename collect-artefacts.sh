#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>

source "$(dirname "$0")/project.env"

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $(basename "$0") [--with-rawcover] [--trim-crashes]"
    echo "Runs artefact collection inside container '$DEFAULT_CONTAINER_NAME'."
    echo "The resulting archive is placed in ./volume/workdir-*/ on the host."
    echo ""
    echo "  --with-rawcover    Also include vmlinux and rawcover in the archive."
    echo "  --trim-crashes     Trim repeated log/report/machineInfo files to 3 most recent."
    exit 0
fi

EXTRA_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --with-rawcover|--trim-crashes) EXTRA_ARGS+=("$arg") ;;
        *) echo "ERROR: unknown argument: $arg" >&2; exit 1 ;;
    esac
done

echo "▶ Collecting artefacts inside container '$DEFAULT_CONTAINER_NAME'..."
docker exec -it "$DEFAULT_CONTAINER_NAME" \
    bash -c "~/alt-syz-box/scripts/tools/collect-artefacts.sh ${EXTRA_ARGS[*]}"

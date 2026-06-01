#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>

source "$(dirname "$0")/project.env"

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat <<USAGE
Usage: $(basename "$0") [--with-rawcover] [--trim-crashes]
                        [--with-analysis-table] [--with-page-snapshot]

Runs artefact collection inside container '$DEFAULT_CONTAINER_NAME'.
The resulting archive is placed in ./volume/workdir-*/ on the host.

  --with-rawcover         Also include vmlinux and rawcover in the archive.
  --trim-crashes          Trim repeated log/report/machineInfo files to 3 most recent.
  --with-analysis-table   Also generate crash_analysis_table_<TIMESTAMP>.ods
                          next to the archive (NOT inside the archive — the
                          spreadsheet is meant to be edited by hand and the
                          archive should stay sealed).
  --with-page-snapshot    Also save the syz-manager main page (Expert mode)
                          as syzmanager_page_<TIMESTAMP>.html next to the
                          archive (NOT inside).
USAGE
    exit 0
fi

EXTRA_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --with-rawcover|--trim-crashes|--with-analysis-table|--with-page-snapshot)
            EXTRA_ARGS+=("$arg") ;;
        *) echo "ERROR: unknown argument: $arg" >&2; exit 1 ;;
    esac
done

echo "▶ Collecting artefacts inside container '$DEFAULT_CONTAINER_NAME'..."
docker exec -it "$DEFAULT_CONTAINER_NAME" \
    bash -c "~/alt-syz-box/scripts/tools/collect-artefacts.sh ${EXTRA_ARGS[*]}"

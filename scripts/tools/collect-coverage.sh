#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# collect-coverage.sh — fetch the HTML coverage report from the running
# syz-manager and save it to a directory.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../project.env"
source "$SCRIPT_DIR/../01-setup-env.sh" &>/dev/null

die() { echo "ERROR: $*" >&2; exit 1; }

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $(basename "$0") [-o DIR]"
    echo "Fetches the HTML coverage report from syz-manager and saves it to DIR."
    echo "Default output: \$SYZKALLER_WORKDIR/coverage_<TIMESTAMP>"
    exit 0
fi

OUTPUT_DIR=""
if [[ "$1" == "-o" ]]; then
    [[ -z "${2:-}" ]] && die "'-o' requires a directory argument"
    OUTPUT_DIR="$2"
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${OUTPUT_DIR:-${SYZKALLER_WORKDIR}/coverage_${TIMESTAMP}}"

mkdir -p "$OUTPUT_DIR"

echo "▶ Fetching coverage from http://0.0.0.0:${DEFAULT_SYZ_HTTP_INTERNAL_PORT}/cover ..."
curl -sf "http://0.0.0.0:${DEFAULT_SYZ_HTTP_INTERNAL_PORT}/cover" \
    > "$OUTPUT_DIR/index.html" \
    || die "curl failed — is syz-manager running on port ${DEFAULT_SYZ_HTTP_INTERNAL_PORT}?"
[[ -s "$OUTPUT_DIR/index.html" ]] \
    || die "empty response from syz-manager"
echo "  $(wc -c < "$OUTPUT_DIR/index.html") bytes written."

echo "✅ Coverage report ready: $OUTPUT_DIR/index.html"

#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2025 Vasiliy Kovalev <kovalev@altlinux.org>

set -exo pipefail
source "$(dirname "$0")/../project.env"
source "$(dirname "$0")/01-setup-env.sh"

help() {
    echo "Usage: $0"
    echo "Generates the syzkaller config file and starts the syz-manager."
    echo "The config template is chosen via SYZ_CONFIG_TEMPLATE in 01-setup-env.sh."
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    help
    exit 0
fi

echo "▶ Preparing to run the fuzzer..."

# Create the workdir if it doesn't exist
mkdir -p "$SYZKALLER_WORKDIR"

# Generate syzkaller config from template
echo "Generating syzkaller config at $SYZKALLER_CONFIG_PATH..."
export DOL_SIGN='$'
envsubst < "$(dirname "$0")/../config/syzkaller/$SYZ_CONFIG_TEMPLATE.config.template" > "$SYZKALLER_CONFIG_PATH"

echo "Syzkaller config generated:"
cat "$SYZKALLER_CONFIG_PATH"

echo "🚀 Starting syz-manager..."
"$SYZKALLER_DIR/bin/syz-manager" -config "$SYZKALLER_CONFIG_PATH"

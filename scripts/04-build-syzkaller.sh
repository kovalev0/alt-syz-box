#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2025 Vasiliy Kovalev <kovalev@altlinux.org>

set -exo pipefail
source "$(dirname "$0")/01-setup-env.sh"

help() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Clones, patches, configures, and builds the syzkaller (all by default)."
    echo ""
    echo "Commands:"
    echo "  clean         Clean all."
    echo "  init          Re-initializing the syzkaller directory and applying patches, if any."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message."
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    help
    exit 0
fi

COMMAND=$1

PATCH_DIR="$CONTAINER_REPO_DIR/patches/syzkaller"

echo "▶ Starting Syzkaller build..."

# Clean all ?
if [ -d "$SYZKALLER_DIR" ] && [[ "$COMMAND" == "clean" ]]; then
    echo "Clean all"
    pushd "$SYZKALLER_DIR"
    make clean -j`nproc`
    popd
    exit 0
fi

# Re-init ?
if [[ "$COMMAND" == "init" ]]; then
    echo "Re-initializing the syzkaller directory"
    rm -rf "$SYZKALLER_DIR"
fi

if [ ! -d "$SYZKALLER_DIR" ]; then
    mkdir -p "$SYZKALLER_DIR"
    echo "Cloning Syzkaller from $SYZKALLER_GIT_URL..."
    git clone --depth=1 --branch="$SYZKALLER_GIT_TAG" "$SYZKALLER_GIT_URL" "$SYZKALLER_DIR"

    if ls "$PATCH_DIR"/*.patch.applied 1> /dev/null 2>&1; then
        rename .applied "" "$PATCH_DIR"/*.patch.applied
    fi
else
    echo "Syzkaller directory $SYZKALLER_DIR already exists. Skipping clone."
fi

cd "$SYZKALLER_DIR"

# Apply patches if any exist
if [ -d "$PATCH_DIR" ] && [ -n "$(ls -A $PATCH_DIR/*.patch 2>/dev/null)" ]; then
    echo "▶ Applying syzkaller patches..."
    for patch in $PATCH_DIR/*.patch; do
        echo "Applying $(basename $patch)..."
        git apply "$patch"
        mv "$patch" "$patch".applied
    done
else
    echo "No syzkaller patches found to apply."
fi

# syz-extract: regenerate .const for out-of-tree descriptions
# Space-separated .txt basenames relative to sys/linux/ in the syzkaller tree.
# Skip if all corresponding .const files already exist
if [ -n "${SYZ_EXTRACT_TARGETS:-}" ]; then
    echo "▶ Checking syz-extract targets: $SYZ_EXTRACT_TARGETS"

    all_const_exist=true
    for txt in $SYZ_EXTRACT_TARGETS; do
        const_file="sys/linux/${txt%.txt}.txt.const"
        if [ ! -f "$const_file" ]; then
            all_const_exist=false
            echo "  Missing: $const_file"
            break
        fi
    done

    if [ "$all_const_exist" = "true" ]; then
        echo "  All .const files present, skipping syz-extract."
    else
        echo "▶ Building syz-extract..."
        go build -o bin/syz-extract ./sys/syz-extract

        echo "▶ Running syz-extract for each target..."
        for txt in $SYZ_EXTRACT_TARGETS; do
            echo "  syz-extract: sys/linux/$txt"
            ./bin/syz-extract \
                -os=linux \
                -arch=amd64 \
                -sourcedir="${KERNEL_DIR}" \
                -builddir="${KERNEL_BUILD_DIR}" \
                "$txt"
        done

        echo "▶ Running make generate..."
        # clang-format warnings are informational only; suppress them.
        make generate 2>&1 | grep -v "^clang-format" || true
    fi
fi

make -j"$(nproc)"

echo "✅ Syzkaller build finished successfully."

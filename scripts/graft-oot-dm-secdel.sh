#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# graft-oot-dm-secdel.sh -- Grafts dm-secdel (a dm-linear derivative that turns
# DISCARD into an overwrite with erase patterns) into drivers/md/ so it can be
# built =y and covered by KCOV.
#
# The out-of-tree Makefile builds with "obj-m += dm-secdel.o" against an
# already-built kernel. A module built that way is invisible to
# KCOV_INSTRUMENT_ALL and to syz-manager's coverage attribution, so the source
# is dropped into drivers/md/ with a Kconfig symbol and one Makefile line
# instead.
#
# Source: git://git.altlinux.org/gears/d/dm-secdel.git  ref: p11
#         (upstream mirror: https://github.com/vt-alt/dm-secdel)
#
# Usage (called automatically by 02-build-kernel.sh):
#   KERNEL_DIR=/path/to/kernel ./scripts/graft-oot-dm-secdel.sh
#   NO_CLONE=1 ./scripts/graft-oot-dm-secdel.sh  (skip git clone)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${KERNEL_DIR:-}" ]; then
    source "$SCRIPT_DIR/01-setup-env.sh" >/dev/null
fi
: "${KERNEL_DIR:?KERNEL_DIR is not set}"
: "${TMPDIR:=/tmp/graft-oot}"

GIT_URL="git://git.altlinux.org/gears/d/dm-secdel.git"
GIT_REF="p11"
SRC="$TMPDIR/dm-secdel"
DST="$KERNEL_DIR/drivers/md"

log() { echo "[graft dm-secdel] $*"; }
die() { echo "[graft dm-secdel] ERROR: $*" >&2; exit 1; }

command -v git &>/dev/null || die "required: git"
[ -f "$KERNEL_DIR/Kconfig" ] || die "not a kernel source tree: $KERNEL_DIR"
[ -f "$DST/Makefile" ] || die "$DST/Makefile not found"

mkdir -p "$TMPDIR"

# 1. Clone or update
if [ "${NO_CLONE:-0}" = "1" ] && [ -d "$SRC/.git" ]; then
    log "NO_CLONE=1, skipping clone"
elif [ -d "$SRC/.git" ]; then
    log "updating $SRC"
    git -C "$SRC" fetch --depth=1 origin "$GIT_REF"
    git -C "$SRC" checkout FETCH_HEAD
else
    log "cloning $GIT_URL ref=$GIT_REF -> $SRC"
    git clone --depth=1 --branch "$GIT_REF" "$GIT_URL" "$SRC"
fi

# 2. Locate and copy the source
#
# Gear repositories sometimes ship sources as a tarball under .gear/ rather than
# in the working tree, so fall back to unpacking if the .c is not there.
SECDEL_C=$(find "$SRC" -maxdepth 2 -name 'dm-secdel.c' 2>/dev/null | head -1)
if [ -z "$SECDEL_C" ]; then
    tarball=$(ls "$SRC"/*.tar.* "$SRC"/.gear/*.tar.* 2>/dev/null | head -1 || true)
    [ -n "$tarball" ] || die "cannot find dm-secdel.c in $SRC"
    log "unpacking $tarball"
    tar xf "$tarball" -C "$TMPDIR"
    SECDEL_C=$(find "$TMPDIR" -maxdepth 3 -name 'dm-secdel.c' | head -1)
    [ -n "$SECDEL_C" ] || die "dm-secdel.c not found after unpack"
fi

log "grafting $(basename "$SECDEL_C") -> $DST/"
cp "$SECDEL_C" "$DST/dm-secdel.c"

# 3. Kconfig symbol
#
# drivers/md/Kconfig ends with "endif # MD", so the entry goes just above it.
# There is no separate menu: DM_SECDEL belongs with the other dm targets.
MD_K="$DST/Kconfig"
if ! grep -q "config DM_SECDEL" "$MD_K"; then
    log "adding DM_SECDEL to $MD_K"
    tmp="${MD_K}.tmp"
    awk '
        /^endif[[:space:]]*#[[:space:]]*MD/ && !done {
            print "config DM_SECDEL";
            print "\ttristate \"Secure deletion on discard target (dm-secdel)\"";
            print "\tdepends on BLK_DEV_DM";
            print "\tdefault y";
            print "\thelp";
            print "\t  dm-linear with secure deletion on discard: a DISCARD sent to";
            print "\t  the mapped device is turned into one or more overwrite passes";
            print "\t  of the discarded region. Out-of-tree module grafted into the";
            print "\t  tree by alt-syz-box/scripts/graft-oot-dm-secdel.sh.";
            print "";
            done = 1;
        }
        { print }
    ' "$MD_K" > "$tmp"
    grep -q "config DM_SECDEL" "$tmp" || die "failed to patch $MD_K (no 'endif # MD'?)"
    mv "$tmp" "$MD_K"
fi

# 4. Makefile entry
MD_M="$DST/Makefile"
if ! grep -q "CONFIG_DM_SECDEL" "$MD_M"; then
    log "adding obj-\$(CONFIG_DM_SECDEL) to $MD_M"
    printf '\n# dm-secdel (grafted)\nobj-$(CONFIG_DM_SECDEL)\t\t+= dm-secdel.o\n' >> "$MD_M"
fi

# 5. Sanity check against a known build breaker
#
# The module is version-gated with LINUX_VERSION_CODE in most places.
# kmap_atomic() is deprecated but still present in 6.12 and removed later, so
# warn loudly rather than fail at the -j$(nproc) stage.
if grep -q "kmap_atomic" "$DST/dm-secdel.c" && \
   ! grep -rq "kmap_atomic" "$KERNEL_DIR/include/linux/highmem.h"; then
    log "WARNING: dm-secdel.c uses kmap_atomic() but this kernel no longer"
    log "         provides it; replace with kmap_local_page()/kunmap_local()."
fi

log "done"
log ""
log "Note: the fuzzer needs a backing block device with a fixed, known size."
log "The dm-secdel config template boots the guest with brd ramdisks:"
log "  brd.rd_nr=8 brd.rd_size=32768   (8 x 32 MiB -> /dev/ram0../dev/ram7)"
log "The 65536-sector table length in sys/linux/dev_dm.txt matches that."

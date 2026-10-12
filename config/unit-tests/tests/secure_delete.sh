#!/bin/sh
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# In-guest unit test for secure_delete (THC srm/sfill/sswap/smem). Runs as root
# inside the QEMU VM. The orchestrator ships the built source tree to ./src with
# the four coverage-instrumented binaries (gcc --coverage) alongside their .gcno.
#
# Coverage model (userspace, not kernel): each tool is built with --coverage, so
# at exit libgcov writes its .gcda to the filesystem. We redirect those writes to
# a single flat directory with GCOV_PREFIX / GCOV_PREFIX_STRIP; the orchestrator's
# "userspace" branch then tars $GCOV_PREFIX back and pairs the .gcda with the
# host-side .gcno. (Keep GCOV_PREFIX in step with GCOV_USERSPACE_DIR in
# scripts/lib/gcov-lib.sh.)
#
# The secure-wiping core is sdel-lib.c (sdel_overwrite with the Gutmann 38-pass /
# 0xff+random / single-random modes, sdel_unlink's truncate+rename+unlink, and
# sdel_wipe_inodes); each tool is a thin main() over it. We drive every tool
# through its option/dispatch paths AND the real wipe paths, while staying inside
# the VM safely. Two upstream quirks shape how we do that WITHOUT losing coverage:
#
#   * sdel_wipe_inodes() opens one fd per probe file and never closes them (an
#     upstream fd leak). On a normal filesystem it would create thousands of
#     files, exhaust the ~1024 fd limit, and then libgcov could not even open the
#     .gcda at exit ("profiling: ...gcda: Cannot open"). We therefore run sfill on
#     a loop fs built with a SMALL inode count (mkfs -N), so the leak stays well
#     under the fd limit and the .gcda is still written — and we raise the fd
#     limit too, best effort.
#   * smem deliberately grabs ALL free RAM and never frees it, so capping its
#     address space (ulimit -v) would also stop libgcov allocating to write the
#     .gcda. Instead we run smem in its SECURE mode (whose /dev/urandom reads and
#     38 passes make allocation slow) under a short timeout, so it touches only a
#     few MB before we stop it — bounded, and the .gcda is written normally.
#
# Other safety rules: srm/sfill/sswap only ever wipe a small dedicated loop
# device, never a real or large filesystem; the space wipers use the single-pass
# insecure mode (-ll) except where a couple of passes are needed to leave a window
# to deliver a signal; the secure-raising -s branch is covered via error-exit
# scenarios; and srm is never pointed at "/" (upstream sleeps, then wipes it).
#
# NOTE: the repo also carries the ancient sdel-mod.c kernel module; it is not
# built or loaded here (see secure_delete.conf) — dm-secdel covers the in-kernel
# secure-erase-on-DISCARD path.
set -x
SRC=./src
FAIL=0   # functional-assertion failure count (see the summary at the end)

# --- userspace gcov collection -------------------------------------------------
# libgcov writes <path>/<src>.gcda for the compile-time <path>; STRIP=99 drops all
# leading components so everything lands flat in $GCOV_PREFIX as <src>.gcda.
export GCOV_PREFIX=/root/gcov-out
export GCOV_PREFIX_STRIP=99
rm -rf "$GCOV_PREFIX"
mkdir -p "$GCOV_PREFIX"

# Raise the open-file limit (best effort) so sdel_wipe_inodes' fd leak cannot stop
# libgcov opening the .gcda. The small-inode loop fs below is the real guarantee;
# this is belt-and-suspenders and simply falls back if the hard limit is lower.
ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null \
    || ulimit -n 4096 2>/dev/null || true

# Resolve ./src to an ABSOLUTE path up front: the blocks below change directory
# (cd into per-tool work dirs), so the tool paths must not be relative to cwd.
SRC=$(cd "$SRC" 2>/dev/null && pwd || echo "$SRC")

# --- locate the built tools (top of $SRC, or one level down for a tarball gear)
find_bin() {
    _n="$1"
    if [ -x "$SRC/$_n" ]; then
        echo "$SRC/$_n"; return 0
    fi
    _p=$(find "$SRC" -maxdepth 3 -type f -name "$_n" -perm -u+x 2>/dev/null | head -1)
    [ -n "$_p" ] && { echo "$_p"; return 0; }
    return 1
}

SRM=$(find_bin srm)
SFILL=$(find_bin sfill)
SSWAP=$(find_bin sswap)
SMEM=$(find_bin smem)
echo "tools: srm=$SRM sfill=$SFILL sswap=$SSWAP smem=$SMEM"

modprobe loop 2>/dev/null || true

# --- ALT -p/-P option: a user-supplied pattern file replaces /dev/urandom -------
# This is the ALT "configure-rand-file" patch (added to all four tools): with -p
# <file>, sdel_init opens that file as random_dev and __sdel_random_buf reads from
# it, rewinding when the file is shorter than the buffer. We prepare two pattern
# files so both the short-file (rewind) and the full-read paths get exercised.
# NB: -p only takes effect WITHOUT -f — fast mode never opens a random source.
PAT_SMALL=/var/tmp/sd-pat-small   # << bufsize: forces the rewind loop
PAT_BIG=/var/tmp/sd-pat-big       # >= bufsize: one read, no rewind
printf 'PATTERN-0123456789' > "$PAT_SMALL"
dd if=/dev/zero bs=1024 count=96 2>/dev/null | tr '\0' 'P' > "$PAT_BIG"

# ==============================================================================
# srm — secure file removal
# ==============================================================================
if [ -n "$SRM" ]; then
    WORK=/var/tmp/sd-srm
    rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK" || exit 0

    # help / usage and the argument-less path.
    "$SRM" -h 2>&1 | head -1 || true
    "$SRM"    2>&1 | head -1 || true

    # error path + the '-s' secure-raising branch, without wiping anything real.
    "$SRM" -s /this/does/not/exist 2>&1 | head -1 || true

    # default secure mode (38 passes) on a tiny file.
    printf 'topsecret-data' > f_secure
    "$SRM" -v f_secure 2>&1 | tail -1 || true

    # secure mode + zero last pass (-z): covers sdel_overwrite's mode-2 "last pass
    # writes zeros" branch, distinct from the -ll one-pass+zero case below.
    printf 'zz' > f_seczero; "$SRM" -vz f_seczero 2>&1 | tail -1 || true

    # two passes (-l : 0xff + random), one pass + zero (-llz), one pass random (-ll).
    printf 'aa' > f_two;  "$SRM" -lf  f_two  2>&1 | tail -1 || true
    printf 'bb' > f_zero; "$SRM" -llfz f_zero 2>&1 | tail -1 || true
    printf 'cc' > f_one;  "$SRM" -llf  f_one  2>&1 | tail -1 || true

    # ALT -p: secure wipe of a tiny file drawing "randomness" from a short pattern
    # file — covers case 'p' plus the pattern read + rewind path in __sdel_random_buf
    # (no -f, so the pattern source is actually opened).
    printf 'dd' > f_pat;  "$SRM" -vp "$PAT_SMALL" f_pat 2>&1 | tail -1 || true

    # recursive directory removal (nested).
    mkdir -p d/sub; printf 1 > d/a; printf 2 > d/sub/b
    "$SRM" -rfv d 2>&1 | tail -1 || true

    # hardlinked regular file must be refused (st_nlink > 1).
    printf hl > h1; ln h1 h2 2>/dev/null
    "$SRM" -f h1 2>&1 | head -1 || true
    rm -f h1 h2

    # non-regular file: rename/unlink only (no overwrite).
    mkfifo fifo1 2>/dev/null && { "$SRM" -f fifo1 2>&1 | head -1 || true; }
    rm -f fifo1

    # directory without -r: warn, do not remove.
    mkdir -p d_norec; printf x > d_norec/f
    "$SRM" -f d_norec 2>&1 | head -1 || true
    rm -rf d_norec

    # signal path: start a wipe of a larger file and interrupt it so cleanup()
    # runs (and flushes the .gcda). Bounded by the small file size.
    dd if=/dev/zero of=big bs=1M count=12 2>/dev/null
    "$SRM" -v big >/dev/null 2>&1 &
    _p=$!; sleep 1; kill -INT "$_p" 2>/dev/null || true; wait "$_p" 2>/dev/null
    rm -f big

    # Functional assertion on a real device: write a marker through an ext4 loop
    # fs, srm it in secure mode (in-place overwrite), then search the raw device.
    IMG=/var/tmp/sd-srm.img
    dd if=/dev/zero of="$IMG" bs=1M count=32 2>/dev/null
    LOOP=$(losetup -f 2>/dev/null)
    if [ -n "$LOOP" ] && losetup "$LOOP" "$IMG" 2>/dev/null; then
        if mkfs.ext4 -q -F -O ^has_journal "$LOOP" 2>/dev/null; then
            mkdir -p m
            if mount -t ext4 "$LOOP" m 2>/dev/null; then
                MARKER="SRM_MARKER_0123456789_abcdefghij"
                printf '%s' "$MARKER" > m/secret
                sync
                "$SRM" m/secret 2>&1 | tail -1 || true
                sync
                umount m 2>/dev/null
                if grep -a -q "$MARKER" "$LOOP" 2>/dev/null; then
                    echo "RESULT srm: FAIL - marker still present after srm"
                    FAIL=$((FAIL + 1))
                else
                    echo "RESULT srm: PASS - marker gone after srm"
                fi
            fi
        fi
        losetup -d "$LOOP" 2>/dev/null || true
    fi
    rm -f "$IMG"
    cd /root || true
fi

# ==============================================================================
# sfill — wipe free disk space + free inodes (small loop ext4 only, insecure)
# ==============================================================================
if [ -n "$SFILL" ]; then
    # help, non-directory error, and the '-s' branch via a missing directory.
    "$SFILL" -h 2>&1 | head -1 || true
    "$SFILL" -f /etc/hostname 2>&1 | head -1 || true
    "$SFILL" -s /no/such/dir 2>&1 | head -1 || true

    IMG=/var/tmp/sd-sfill.img
    dd if=/dev/zero of="$IMG" bs=1M count=48 2>/dev/null
    LOOP=$(losetup -f 2>/dev/null)
    if [ -n "$LOOP" ] && losetup "$LOOP" "$IMG" 2>/dev/null; then
        # -N 256: few inodes, so sdel_wipe_inodes' fd leak stays well under the fd
        # limit and libgcov can still open the .gcda (see the header note).
        if mkfs.ext4 -q -F -N 256 "$LOOP" 2>/dev/null; then
            mkdir -p /mnt/sfill
            if mount -t ext4 "$LOOP" /mnt/sfill 2>/dev/null; then
                # free space + inodes, single pass (-ll), verbose.
                timeout 120 "$SFILL" -llfv /mnt/sfill 2>&1 | tail -2 || true
                # inode space only (-i).
                timeout 120 "$SFILL" -ifv  /mnt/sfill 2>&1 | tail -1 || true
                # disk space only, no inodes (-I), single pass.
                timeout 120 "$SFILL" -Illfv /mnt/sfill 2>&1 | tail -1 || true
                # ALT -p: single-pass space wipe drawing from a pattern file (no -f
                # so the file is opened); PAT_BIG >= bufsize -> the full-read branch.
                timeout 120 "$SFILL" -Illp "$PAT_BIG" /mnt/sfill 2>&1 | tail -1 || true
                # cleanup(): a secure (38-pass) space wipe is guaranteed to still
                # be running after a moment, so the SIGINT reliably lands mid-wipe
                # and runs the handler; the interrupt bounds the actual I/O.
                "$SFILL" -v /mnt/sfill >/dev/null 2>&1 &
                _p=$!; sleep 1; kill -INT "$_p" 2>/dev/null || true; wait "$_p" 2>/dev/null
                umount /mnt/sfill 2>/dev/null
                echo "RESULT sfill: free-space and inode wipes completed"
            fi
        fi
        losetup -d "$LOOP" 2>/dev/null || true
    fi
    rm -f "$IMG"
fi

# ==============================================================================
# sswap — wipe a swap block device (loop block device stand-in, insecure)
# ==============================================================================
if [ -n "$SSWAP" ]; then
    # help, "not a block device" error on a regular file, and the -j range error.
    "$SSWAP" -h 2>&1 | head -1 || true
    dd if=/dev/zero of=/var/tmp/sd-reg bs=1M count=1 2>/dev/null
    "$SSWAP" -f /var/tmp/sd-reg 2>&1 | head -1 || true
    rm -f /var/tmp/sd-reg

    IMG=/var/tmp/sd-swap.img
    dd if=/dev/zero of="$IMG" bs=1M count=16 2>/dev/null
    LOOP=$(losetup -f 2>/dev/null)
    if [ -n "$LOOP" ] && losetup "$LOOP" "$IMG" 2>/dev/null; then
        mkswap "$LOOP" >/dev/null 2>&1 || true     # realistic header; not swapon'd
        "$SSWAP" -f -j 99999 "$LOOP" 2>&1 | head -1 || true   # bad -j -> range error
        # default start offset (-j SWAP_PAGESIZE, i.e. non-zero): covers the
        # fseek(start) branch in sdel_overwrite, distinct from the -j 0 rewind path.
        timeout 90 "$SSWAP" -llfv "$LOOP" 2>&1 | tail -1 || true
        timeout 90 "$SSWAP" -llfv -j 0 "$LOOP" 2>&1 | tail -1 || true  # 1-pass, start 0
        # ALT -p: 1-pass wipe drawing from a pattern file (no -f so it is opened).
        timeout 90 "$SSWAP" -llp "$PAT_BIG" -j 0 "$LOOP" 2>&1 | tail -1 || true
        # cleanup(): a secure (38-pass) wipe is guaranteed to still be running
        # after a moment, so the SIGINT reliably lands mid-wipe and runs the
        # handler; the interrupt bounds the actual I/O.
        "$SSWAP" -v -j 0 "$LOOP" >/dev/null 2>&1 &
        _p=$!; sleep 1; kill -INT "$_p" 2>/dev/null || true; wait "$_p" 2>/dev/null
        losetup -d "$LOOP" 2>/dev/null || true
        echo "RESULT sswap: block-device wipe completed"
    fi
    rm -f "$IMG"
fi

# ==============================================================================
# smem — wipe free RAM (bounded by SECURE-mode slowness + a timeout; no ulimit -v,
# which would stop libgcov writing the .gcda — see the header note)
# ==============================================================================
if [ -n "$SMEM" ]; then
    "$SMEM" -h 2>&1 | head -1 || true
    # Secure mode is slow (urandom reads + 38 passes per block), so in a few
    # seconds it touches only a few MB before the timeout's SIGTERM triggers
    # cleanup() -> exit, which flushes the .gcda. Covers smash_it's multi-pass
    # buffer-init/overwrite path and cleanup().
    timeout -s TERM 4 "$SMEM" -v 2>&1 | tail -1 || true
    # Option branches (-l, -s, -v) and the ALT -p case, plus cleanup() again:
    # still secure mode (slow, bounded), interrupted after a moment.
    "$SMEM" -lsvp "$PAT_SMALL" >/dev/null 2>&1 &
    _p=$!; sleep 1; kill -INT "$_p" 2>/dev/null || true; wait "$_p" 2>/dev/null
    echo "RESULT smem: bounded memory wipes completed"
fi

rm -f "$PAT_SMALL" "$PAT_BIG" 2>/dev/null

# Make sure every .gcda is on disk before the orchestrator pulls $GCOV_PREFIX.
sync
GCDA_N=$(find "$GCOV_PREFIX" -name '*.gcda' 2>/dev/null | wc -l)

# --- summary ------------------------------------------------------------------
# Two independent health signals for a glance at the end of tests.log:
#   * functional: FAIL counts failed assertions (currently the srm marker check).
#   * coverage plumbing: every tool that ran should have left a .gcda; a missing
#     one (fewer than 5) means that tool crashed or libgcov could not write —
#     i.e. its coverage is lost even if the summary % still looks plausible.
echo "=============================================================="
echo "secure_delete summary: functional failures=$FAIL ; .gcda files=$GCDA_N (expect 5)"
if [ "$FAIL" -eq 0 ] && [ "$GCDA_N" -ge 5 ]; then
    echo "RESULT secure_delete: PASS"
else
    echo "RESULT secure_delete: FAIL (see the lines above)"
fi
echo "secure_delete in-guest tests complete"

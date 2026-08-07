#!/bin/sh
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# In-guest driver for the kselftests target (x86_64). Runs as root inside the
# QEMU VM.
#
# Workflow:
#   1) Get the full test list from run_kselftest.sh -l
#   2) Remove the blacklisted tests that hang or crash in QEMU
#   3) Run tests one by one with logging
#
set -x

KSELFTEST_DIR=/usr/lib/kselftests
RUNNER="$KSELFTEST_DIR/run_kselftest.sh"
RESULTS=/tmp/kselftest_results.log
LIST=/tmp/kselftest_list.txt

if [ ! -x "$RUNNER" ]; then
    echo "[SKIP] $RUNNER not found (kselftests RPM not installed)"
    exit 0
fi

# x86_64 blacklist:
# these tests hang or crash in QEMU and must be skipped.
BLACKLIST="
breakpoints:step_after_suspend_test
drivers/net/bonding:bond_ipsec_offload.sh
pidfd:pidfd_test
pidfd:pidfd_info_test
proc:proc-pid-vm
rseq:run_param_test.sh
rtc:rtctest
"

# Step 1: generate test list
"$RUNNER" -l 2>/dev/null > "$LIST" \
    || { echo "[WARN] could not generate test list; falling back to full run"; LIST=""; }

# Step 2: remove blacklisted tests
if [ -n "$LIST" ] && [ -s "$LIST" ]; then
    BLACKLIST_FILE=$(mktemp)
    for bl in $BLACKLIST; do
        printf '%s\n' "$bl"
    done > "$BLACKLIST_FILE"

    grep -Fxv -f "$BLACKLIST_FILE" "$LIST" > "$LIST.new" 2>/dev/null \
        && mv "$LIST.new" "$LIST" \
        || true
    rm -f "$BLACKLIST_FILE" "$LIST.new"

    TOTAL=$(wc -l < "$LIST")
    echo "[INFO] Running $TOTAL kselftests (blacklisted tests removed)"
fi

# Step 3: run tests
if [ -n "$LIST" ] && [ -s "$LIST" ]; then
    # Read the list on fd 3, not fd 0: some tests (e.g. nolibc-test) do raw
    # syscall exercises (read/lseek/...) directly on fd 0, and if it shared
    # the same open file description as $LIST, that rewinds our read
    # position and the whole list restarts from the top after such a test.
    while IFS= read -r TEST <&3; do
        echo "--- Running: $TEST ---" | tee -a "$RESULTS"
        "$RUNNER" --test "$TEST" </dev/null 2>&1 | tee -a "$RESULTS" || true
    done 3< "$LIST"
else
    echo "[INFO] Running all kselftests (no list)"
    "$RUNNER" </dev/null 2>&1 | tee "$RESULTS" || true
fi
echo "kselftests complete; results in $RESULTS"

# Coverage is collected on the host: the orchestrator tars the raw .gcda from
# /sys/kernel/debug/gcov and merges them with the container-side kernel .gcno.
# Running lcov here cannot work — the .gcno the kernel build produced are not
# present in the guest. Confirm the counters are visible for the host to pull.
if [ -d /sys/kernel/debug/gcov ]; then
    echo "[INFO] kernel gcov data present; host will pull and merge .gcda"
else
    echo "[WARN] /sys/kernel/debug/gcov not mounted — no kernel coverage to pull"
fi

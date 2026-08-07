#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# gcov-lib.sh — collect kernel gcov data from the guest and render an lcov
# report scoped to a target's sources.
#
# Kernel coverage comes from CONFIG_GCOV_KERNEL: the running kernel and any
# loaded module built against it expose their counters under debugfs at their
# build-time source path. We reset the counters, run the tests, tar the debugfs
# subtree from the guest, then on the host merge those .gcda with the .gcno left
# in the module build directory and hand the pair to lcov/genhtml.
# See Documentation/dev-tools/gcov.rst.

GCOV_DEBUGFS="${GCOV_DEBUGFS:-/sys/kernel/debug/gcov}"

# --- commands intended to run inside the guest (via vm_ssh) ---

# gcov_guest_reset_cmd — shell snippet that zeroes all kernel gcov counters.
gcov_guest_reset_cmd() {
    printf '[ -e %s/reset ] && echo 1 > %s/reset || true' \
        "$GCOV_DEBUGFS" "$GCOV_DEBUGFS"
}

# gcov_guest_tar_cmd BUILD_PREFIX OUT_TGZ — shell snippet (run in the guest)
# that collects the module's .gcda from debugfs into OUT_TGZ.
#
# IMPORTANT: debugfs gcov files report st_size == 0, so `tar`/`cp`, which trust
# the stat size, would archive EMPTY files. We must read their real content with
# `cat < file` (reads to EOF regardless of st_size), stage it as regular files,
# then tar the staging tree. This is the method from Documentation/dev-tools/
# gcov.rst. The .gcno in debugfs are symlinks to the build tree and are not
# needed here (the host side already has the build .gcno). On a miss an empty
# tar is written rather than the whole vmlinux gcov set.
gcov_guest_tar_cmd() {
    local prefix="$1" out="$2"
    local src="${GCOV_DEBUGFS}${prefix}"
    printf '%s' "ST=/tmp/gcov-stage; rm -rf \"\$ST\"; mkdir -p \"\$ST\"; \
find '$src' -name '*.gcda' 2>/dev/null | while IFS= read -r f; do \
r=\"\${f#/}\"; mkdir -p \"\$ST/\${r%/*}\"; cat < \"\$f\" > \"\$ST/\$r\"; done; \
if find \"\$ST\" -name '*.gcda' | grep -q .; then tar czf '$out' -C \"\$ST\" .; \
else tar czf '$out' --files-from /dev/null; fi"
}

# --- host side ---

# gcov_report GCNO_DIR PULLED_ROOT BUILD_PREFIX COV_PATTERN OUT_DIR
#   GCNO_DIR     — module build dir on the host (holds *.gcno)
#   PULLED_ROOT  — dir where the guest gcov tarball was extracted
#   BUILD_PREFIX — absolute module build path (its mirror under debugfs)
#   COV_PATTERN  — lcov --extract pattern to keep only the target's files
#   OUT_DIR      — output directory for the HTML report
#   TITLE        — (optional) label for the PDF/console, e.g. the target name
# Produces OUT_DIR/coverage.info, OUT_DIR/summary.txt, OUT_DIR/coverage-summary.txt,
# OUT_DIR/report.pdf and OUT_DIR/html/.
gcov_report() {
    local gcno_dir="$1" pulled="$2" prefix="$3" pattern="$4" outdir="$5"
    local title="${6:-coverage}"
    mkdir -p "$outdir/html"

    # Assemble a single tree with .gcno (build) and .gcda (guest) side by side.
    local merged; merged="$(mktemp -d)"
    ( cd "$gcno_dir" && find . -name '*.gcno' -print0 |
        while IFS= read -r -d '' f; do
            mkdir -p "$merged/$(dirname "$f")"; cp "$gcno_dir/$f" "$merged/$f"
        done )
    local gcda_root="$pulled/${GCOV_DEBUGFS#/}${prefix}"
    [ -d "$gcda_root" ] || gcda_root="$pulled"
    ( cd "$gcda_root" && find . -name '*.gcda' -print0 2>/dev/null |
        while IFS= read -r -d '' f; do
            mkdir -p "$merged/$(dirname "$f")"; cp "$gcda_root/$f" "$merged/$f"
        done )

    if ! find "$merged" -name '*.gcda' | grep -q .; then
        echo "⚠️  No .gcda captured for $prefix — did the module load and run?" >&2
        echo "    (A gcov kernel is required; see scripts/06-run-unit-tests.sh.)" >&2
        rm -rf "$merged"
        return 1
    fi

    # lcov 2.x accepts the richer --ignore-errors set; older lcov does not, so
    # retry with a smaller set and finally with none.
    lcov --capture --directory "$merged" --output-file "$outdir/coverage.info" \
         --rc geninfo_unexecuted_blocks=1 \
         --ignore-errors mismatch,negative,empty,unused,inconsistent,source,gcov 2>/dev/null \
      || lcov --capture --directory "$merged" --output-file "$outdir/coverage.info" \
             --ignore-errors gcov,source,graph 2>/dev/null \
      || lcov --capture --directory "$merged" --output-file "$outdir/coverage.info" 2>/dev/null \
      || true

    # Keep only the target's own sources in the report.
    if [ -s "$outdir/coverage.info" ] && [ -n "$pattern" ]; then
        lcov --extract "$outdir/coverage.info" "*${pattern}*" \
             --output-file "$outdir/coverage.info" \
             --ignore-errors unused 2>/dev/null || true
    fi

    if [ -s "$outdir/coverage.info" ]; then
        lcov --list "$outdir/coverage.info" > "$outdir/summary.txt" 2>/dev/null || true
        lcov --summary "$outdir/coverage.info" > "$outdir/coverage-summary.txt" 2>&1 || true
        genhtml "$outdir/coverage.info" --output-directory "$outdir/html" >/dev/null 2>&1 || true

        # report.pdf = the genhtml summary page (index.html) rendered as it looks
        # in a browser. The test log stays separate in tests.log (not embedded).
        local h2p; h2p="$(dirname "${BASH_SOURCE[0]}")/../tools/html-to-pdf.sh"
        if [ -f "$h2p" ] && [ -f "$outdir/html/index.html" ]; then
            bash "$h2p" "$outdir/html/index.html" "$outdir/report.pdf" \
                "$outdir/coverage.info" >/dev/null 2>&1 \
                || echo "⚠️  PDF generation failed for $title." >&2
        fi

        # Surface the line rate on the console.
        local rate
        rate="$(grep -Eo 'lines[^0-9]*[0-9.]+%' "$outdir/coverage-summary.txt" 2>/dev/null \
                 | grep -Eo '[0-9.]+%' | head -1)"
        echo "✅ $title: lines ${rate:-n/a}"
        echo "   text:  $outdir/summary.txt"
        echo "   HTML:  $outdir/html/index.html"
        [ -f "$outdir/report.pdf" ] && echo "   PDF:   $outdir/report.pdf"
    else
        echo "⚠️  lcov produced no data for $prefix." >&2
    fi
    rm -rf "$merged"
}

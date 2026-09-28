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

# gcov_guest_tar_all_cmd OUT_TGZ — shell snippet (run in the guest) that stages
# EVERY .gcda under the whole gcov debugfs root into OUT_TGZ, preserving the
# debugfs paths. Used for kernel-wide coverage (kselftests): the exact build
# path the kernel recorded under debugfs is not known to the host in advance, so
# instead of guessing a prefix we grab the entire tree and let the host pair each
# .gcda with the .gcno of the matching absolute build path. Same st_size==0
# `cat < file` workaround as gcov_guest_tar_cmd; prints the staged count to
# stderr so the run log shows how much was captured.
gcov_guest_tar_all_cmd() {
    local out="$1" src="$GCOV_DEBUGFS"
    printf '%s' "ST=/tmp/gcov-stage; rm -rf \"\$ST\"; mkdir -p \"\$ST\"; \
find '$src' -name '*.gcda' 2>/dev/null | while IFS= read -r f; do \
r=\"\${f#/}\"; mkdir -p \"\$ST/\${r%/*}\"; cat < \"\$f\" > \"\$ST/\$r\"; done; \
n=\$(find \"\$ST\" -name '*.gcda' 2>/dev/null | wc -l); \
echo \"[guest] staged \$n .gcda from '$src'\" 1>&2; \
if [ \"\$n\" -gt 0 ]; then tar czf '$out' -C \"\$ST\" .; \
else tar czf '$out' --files-from /dev/null; fi"
}

# --- host side ---

# _gcov_render_merged MERGED OUT_DIR COV_PATTERN TITLE — run lcov/genhtml over a
# prepared tree that already holds matching *.gcno and *.gcda side by side, and
# emit coverage.info, summary.txt, coverage-summary.txt, html/ and report.pdf.
# Shared by gcov_report() (per-module) and gcov_report_kernel() (kernel-wide).
_gcov_render_merged() {
    local merged="$1" outdir="$2" pattern="$3" title="${4:-coverage}"
    mkdir -p "$outdir/html"

    # lcov 2.x accepts the richer --ignore-errors set; older lcov does not, so
    # retry with a smaller set and finally with none.
    lcov --capture --directory "$merged" --output-file "$outdir/coverage.info" \
         --rc geninfo_unexecuted_blocks=1 \
         --ignore-errors mismatch,negative,empty,unused,inconsistent,source,gcov 2>/dev/null \
      || lcov --capture --directory "$merged" --output-file "$outdir/coverage.info" \
             --ignore-errors gcov,source,graph 2>/dev/null \
      || lcov --capture --directory "$merged" --output-file "$outdir/coverage.info" 2>/dev/null \
      || true

    # Keep only the target's own sources in the report (empty pattern = keep all,
    # used for the kernel-wide report).
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
        return 0
    fi

    echo "⚠️  lcov produced no data for $title." >&2
    return 1
}

# gcov_report_kernel PULLED_ROOT BUILD_PREFIX OUT_DIR [TITLE]
#   PULLED_ROOT  — dir where the guest gcov tarball was extracted
#   BUILD_PREFIX — kernel build dir on the host (holds *.gcno); the same path the
#                  guest debugfs mirrors
#   OUT_DIR      — output directory for the report
#   TITLE        — (optional) label for the PDF/console, e.g. the target name
#
# Kernel-wide counterpart of gcov_report(). The kernel is built in the container,
# so its *.gcno live only under BUILD_PREFIX there. The guest's debugfs exposes
# the matching *.gcda, but its *.gcno entries are symlinks into that build tree —
# which does not exist inside the guest — so running lcov in the guest fails with
# "cannot open notes file" / "stamp mismatch with notes file" and yields nothing.
# We therefore pull the raw *.gcda from the guest and pair each one with the
# container-side *.gcno of the same relative path, then run lcov on the host.
gcov_report_kernel() {
    local pulled="$1" prefix="$2" outdir="$3" title="${4:-coverage}"
    mkdir -p "$outdir/html"

    local total; total=$(find "$pulled" -name '*.gcda' 2>/dev/null | wc -l)
    if [ "$total" -eq 0 ]; then
        echo "⚠️  No kernel .gcda pulled from the guest for $title." >&2
        echo "    (Was the guest booted with a CONFIG_GCOV_KERNEL kernel and the" >&2
        echo "     counters reset before the tests ran? Is debugfs mounted?)" >&2
        return 1
    fi
    echo "  -> pulled $total kernel .gcda from the guest debugfs"

    # The guest tarball preserves the debugfs paths, e.g.
    #   <pulled>/sys/kernel/debug/gcov/<abs-build-path>/foo.gcda
    # where <abs-build-path> is exactly where the kernel was compiled — and where
    # its .gcno physically live on this host/container. So we do NOT assume the
    # debugfs prefix equals $prefix: for every pulled .gcda we strip the debugfs
    # root, reconstruct the .gcno's absolute path, and pair the two when that
    # .gcno exists. $prefix is only used to keep the report scoped to the kernel
    # tree when a scoped match is available.
    local gcov_root_rel="${GCOV_DEBUGFS#/}"        # e.g. sys/kernel/debug/gcov
    local merged; merged="$(mktemp -d)"
    local staged=0 staged_scoped=0

    while IFS= read -r -d '' gcda; do
        local rel="${gcda#"$pulled"/}"             # sys/kernel/debug/gcov/<abs>/foo.gcda
        case "$rel" in
            "$gcov_root_rel"/*) ;;
            *) continue ;;                         # not under the debugfs root
        esac
        local build_rel="${rel#"$gcov_root_rel"/}" # <abs-without-leading-slash>/foo.gcda
        local gcno="/${build_rel%.gcda}.gcno"      # /<abs>/foo.gcno  (physical .gcno)
        [ -f "$gcno" ] || continue
        mkdir -p "$merged/$(dirname "$build_rel")"
        cp "$gcda" "$merged/$build_rel"
        cp "$gcno" "$merged/${build_rel%.gcda}.gcno"
        staged=$((staged + 1))
        case "/$build_rel" in "$prefix"/*) staged_scoped=$((staged_scoped + 1)) ;; esac
    done < <(find "$pulled" -name '*.gcda' -print0 2>/dev/null)

    if [ "$staged" -eq 0 ]; then
        local host_gcno; host_gcno=$(find "$prefix" -name '*.gcno' 2>/dev/null | wc -l)
        echo "⚠️  Pulled $total .gcda but none could be paired with a host .gcno." >&2
        echo "    .gcno present under $prefix: $host_gcno." >&2
        echo "    The gcov kernel build tree must still hold the .gcno from the" >&2
        echo "    build that produced the running bzImage — rebuild the gcov" >&2
        echo "    kernel (env step) if it was cleaned, then retry the run." >&2
        rm -rf "$merged"
        return 1
    fi

    # If we matched anything inside the kernel build tree, drop out-of-tree
    # matches (e.g. the per-module targets' own objects) so the kselftests
    # report stays kernel-scoped. If nothing matched under $prefix (debugfs
    # prefix differs from $prefix), keep every pairing rather than lose the run.
    if [ "$staged_scoped" -gt 0 ]; then
        local pfx_rel="${prefix#/}"
        ( cd "$merged" && find . -name '*.gcno' -o -name '*.gcda' | while IFS= read -r p; do
            case "${p#./}" in "$pfx_rel"/*) ;; *) rm -f "$p" ;; esac
        done )
        echo "  -> merged $staged_scoped kernel objects (scoped to $prefix)"
    else
        echo "  ⚠️  no objects matched $prefix; using all $staged paired objects" >&2
        echo "      (debugfs build path differs from \$KERNEL_BUILD_DIR)." >&2
    fi

    _gcov_render_merged "$merged" "$outdir" "" "$title"
    local rc=$?
    rm -rf "$merged"
    return $rc
}

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

    _gcov_render_merged "$merged" "$outdir" "$pattern" "$title"
    local rc=$?
    rm -rf "$merged"
    return $rc
}

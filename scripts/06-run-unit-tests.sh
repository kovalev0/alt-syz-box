#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# 06-run-unit-tests.sh — build a gcov-instrumented kernel, build the out-of-tree
# target modules against it, run their tests inside the QEMU guest and collect
# per-module line coverage. This is the unit-tests counterpart of the fuzzing
# flow: it reuses the kernel/qemu/image build steps but never touches syzkaller.
#
# Targets are read from the catalog config/unit-tests/targets/*.conf (see the
# README there). Everything runs deterministically; the operator only watches.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Request a gcov kernel: 02-build-kernel.sh keys on the "gcov" substring. Set
# this before sourcing 01-setup-env.sh, which now honours a preset value.
case "${KERNEL_LOCALVERSION:-alt-syz-box}" in
    *gcov*) export KERNEL_LOCALVERSION="${KERNEL_LOCALVERSION:-alt-syz-box}" ;;
    *)      export KERNEL_LOCALVERSION="${KERNEL_LOCALVERSION:-alt-syz-box}-gcov" ;;
esac

source "$SCRIPT_DIR/../project.env"
source "$SCRIPT_DIR/01-setup-env.sh"
source "$SCRIPT_DIR/lib/vm-lib.sh"
source "$SCRIPT_DIR/lib/gcov-lib.sh"

die() { echo "❌ ERROR: $*" >&2; exit 1; }

# Packages the guest needs to run the drivers (best-effort names; the image
# build installs them one by one and tolerates any that are missing).
# libiptables-devel + gcc/make let the ipt-so driver build libxt_so.so in-guest so
# that "-m so" rules can be parsed and actually exercise the kernel match.
GUEST_PACKAGES="iptables libiptables-devel iproute2 iputils e2fsprogs util-linux device-mapper netcat gcc make pkgconfig"

# Aggregate TARGET_EXTRA_PACKAGES from all selected targets.
aggregate_extra_packages() {
    for conf in $(select_targets); do
        ( TARGET_EXTRA_PACKAGES=""
          # shellcheck disable=SC1090
          source "$conf"
          echo "${TARGET_EXTRA_PACKAGES:-}" )
    done | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | xargs echo
}

help() {
    echo "Usage: $(basename "$0") [command]"
    echo ""
    echo "Build a gcov kernel, build the catalog's target modules against it,"
    echo "run their tests in a VM and collect per-module coverage."
    echo ""
    echo "Commands:"
    echo "  all      Prepare the environment and run every target (default)."
    echo "  env      Only prepare the environment (gcov kernel, qemu, image)."
    echo "  run      Only build/test/collect the targets (env must be ready)."
    echo "  list     List the enabled targets and exit."
    echo ""
    echo "Environment:"
    echo "  TARGETS=\"name1 name2\"   Restrict to a subset of the catalog."
    echo ""
    echo "Flags (can appear anywhere):"
    echo "  --keep-vm       Leave the guest running at the end (for debugging)."
    echo "  --sanitizers    Enable KASAN/UBSAN/LOCKDEP kernel sanitizers."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message."
}

# --- target catalog ---------------------------------------------------------

# Print the .conf paths for the enabled targets (filtered by \$TARGETS if set).
select_targets() {
    local conf name
    if [ -n "${TARGETS:-}" ]; then
        # Explicit TARGETS= list: emit confs IN THE ORDER given by the user.
        for name in $TARGETS; do
            conf="$UNIT_TESTS_TARGETS_DIR/${name}.conf"
            [ -e "$conf" ] && echo "$conf"
        done
    else
        # Default run: all confs in directory order; skip TARGET_DEFAULT=0.
        for conf in "$UNIT_TESTS_TARGETS_DIR"/*.conf; do
            [ -e "$conf" ] || continue
            name="$(basename "$conf" .conf)"
            _def=$(bash -c "TARGET_DEFAULT=1; source \"$conf\" 2>/dev/null; echo \$TARGET_DEFAULT")
            [ "${_def:-1}" = "0" ] && continue
            echo "$conf"
        done
    fi
}

# Aggregate TARGET_KCONFIG across all enabled targets into a unique list. If any
# enabled target sets TARGET_NETFILTER=1, prepend the shared netfilter symbol
# list (config/unit-tests/netfilter-kconfig.list) so network modules build and
# run against a realistic netfilter kernel.
aggregate_kconfig() {
    local conf want_netfilter=0
    {
        for conf in $(select_targets); do
            (
                TARGET_KCONFIG=""; TARGET_NETFILTER=""
                # shellcheck disable=SC1090
                source "$conf"
                echo "$TARGET_KCONFIG"
                [ "${TARGET_NETFILTER:-0}" = "1" ] && echo "__NETFILTER__"
            )
        done
    } | {
        local list; list="$(cat)"
        case "$list" in
            *__NETFILTER__*)
                grep -vE '^#|^$' "$UNIT_TESTS_NETFILTER_KCONFIG" 2>/dev/null ;;
        esac
        echo "$list" | grep -v '__NETFILTER__'
    } | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' '
}

# --- environment preparation ------------------------------------------------

prepare_env() {
    echo "▶ (unit-tests) Preparing environment (gcov kernel, qemu, image)..."
    local kconfig; kconfig="$(aggregate_kconfig)"
    echo "ℹ️  Extra kernel config for targets: ${kconfig:-<none>}"

    EXTRA_KCONFIG_ENABLE="$kconfig" EXTRA_KCONFIG_DISABLE="WERROR" \
        ENABLE_SANITIZERS="${ENABLE_SANITIZERS:-0}" "$SCRIPT_DIR/02-build-kernel.sh" \
        || die "kernel build failed"
    "$SCRIPT_DIR/03-build-qemu.sh" \
        || die "qemu build failed"
    local _extra_pkgs; _extra_pkgs="$(aggregate_extra_packages 2>/dev/null)"
    [ -n "$_extra_pkgs" ] && echo "ℹ️  Extra guest packages: $_extra_pkgs"
    EXTRA_IMAGE_PACKAGES="$GUEST_PACKAGES ${_extra_pkgs}" "$SCRIPT_DIR/05-build-image.sh" \
        || die "image build failed"

    echo "✅ Environment ready: gcov kernel + qemu + guest image."
}

# --- per-target build and test ----------------------------------------------

# fetch_target — clone (or refresh) the target's sources into $TARGET_SRC.
# Apply patches/unit-tests/<target>/*.patch to the checked-out source. Mirrors
# how the kernel/qemu/syzkaller are patched. Idempotent: skips patches that are
# already applied.
apply_target_patches() {
    local pdir="$UNIT_TESTS_PATCHES_DIR/$TARGET_NAME" p
    [ -d "$pdir" ] || return 0
    for p in "$pdir"/*.patch; do
        [ -e "$p" ] || continue
        if git -C "$TARGET_SRC" apply --check "$p" 2>/dev/null; then
            git -C "$TARGET_SRC" apply "$p" && echo "  ✅ applied $(basename "$p")"
        elif git -C "$TARGET_SRC" apply --reverse --check "$p" 2>/dev/null; then
            echo "  ℹ️  already applied: $(basename "$p")"
        else
            echo "  ⚠️  could not apply $(basename "$p")" >&2
        fi
    done
}

fetch_target() {
    # Targets with no external source (e.g. kselftests: tests come from an
    # installed guest RPM) set TARGET_GIT_URL="". Skip all git operations.
    if [ -z "${TARGET_GIT_URL:-}" ]; then
        mkdir -p "$TARGET_SRC"
        return 0
    fi
    if [ -d "$TARGET_SRC/.git" ]; then
        git -C "$TARGET_SRC" fetch --depth=1 origin "$TARGET_GIT_REF" >/dev/null 2>&1 || true
        git -C "$TARGET_SRC" checkout -q FETCH_HEAD 2>/dev/null \
            || git -C "$TARGET_SRC" pull --ff-only >/dev/null 2>&1 || true
        git -C "$TARGET_SRC" reset --hard -q 2>/dev/null || true
        git -C "$TARGET_SRC" clean -fdq 2>/dev/null || true
    else
        rm -rf "$TARGET_SRC"; mkdir -p "$(dirname "$TARGET_SRC")"
        git clone --depth=1 --branch "$TARGET_GIT_REF" "$TARGET_GIT_URL" "$TARGET_SRC" \
            2>/dev/null \
        || git clone --depth=1 --branch "$TARGET_GIT_REF" \
            "$(echo "$TARGET_GIT_URL" | sed 's|^git://|https://|')" "$TARGET_SRC" \
        || return 1
    fi
    apply_target_patches
}

# test_target — run the driver in the guest and collect coverage (VM must be up).
test_target() {
    local gdir="/root/ut/$TARGET_NAME"
    local work="$UNIT_TESTS_DIR/$TARGET_NAME"
    local reports="$work/reports"
    mkdir -p "$reports"

    echo "  -> shipping sources to the guest"
    vm_ssh "mount -t debugfs none /sys/kernel/debug 2>/dev/null || true"
    vm_ssh "rm -rf $gdir && mkdir -p $gdir" || return 1
    vm_scp_to "$TARGET_SRC" "$gdir/src" || return 1
    vm_scp_to "$UNIT_TESTS_TESTS_DIR/$TARGET_GUEST_TEST" "$gdir/test.sh" || return 1

    echo "  -> running $TARGET_GUEST_TEST in the guest (log: $reports/tests.log)"
    vm_ssh "cd $gdir && sh test.sh" 2>&1 | tee "$reports/tests.log" || true

    echo "  -> collecting coverage"
    if [ "${TARGET_COVERAGE_MODE:-module}" = "kernel" ]; then
        # kselftests mode: kernel-wide gcov. The kernel is built in the
        # container, so its .gcno live only under $KERNEL_BUILD_DIR there; the
        # guest's debugfs exposes the matching .gcda but its .gcno are symlinks
        # into that build tree, which is absent inside the guest. lcov therefore
        # cannot run in the guest ("cannot open notes file"). Pull the whole
        # gcov debugfs tree from the guest and pair each .gcda with the
        # container-side .gcno on the host, exactly as the per-module targets do.
        echo "  -> pulling kernel gcda from the guest debugfs"
        vm_ssh "$(gcov_guest_tar_all_cmd /root/gcov.tgz)" || true
        rm -rf "$work/pulled"; mkdir -p "$work/pulled"
        vm_scp_from /root/gcov.tgz "$work/gcov.tgz" || true
        [ -s "$work/gcov.tgz" ] && tar xzf "$work/gcov.tgz" -C "$work/pulled" 2>/dev/null

        gcov_report_kernel "$work/pulled" "$KERNEL_BUILD_DIR" "$reports" "$TARGET_NAME" \
            || echo "⚠️  No kernel coverage produced for $TARGET_NAME." >&2
    else
        vm_ssh "$(gcov_guest_tar_cmd "$TARGET_SRC" /root/gcov.tgz)" || true
        rm -rf "$work/pulled"; mkdir -p "$work/pulled"
        vm_scp_from /root/gcov.tgz "$work/gcov.tgz" || true
        [ -s "$work/gcov.tgz" ] && tar xzf "$work/gcov.tgz" -C "$work/pulled" 2>/dev/null

        gcov_report "$TARGET_SRC" "$work/pulled" "$TARGET_SRC" \
            "$TARGET_COV_PATTERN" "$reports" "$TARGET_NAME"
    fi
}

run_targets() {
    mkdir -p "$UNIT_TESTS_DIR"
    local confs; confs="$(select_targets)"
    [ -n "$confs" ] || die "no targets found in $UNIT_TESTS_TARGETS_DIR"
    [ -f "$KERNEL_BZIMAGE" ] || die "kernel not built — run: $(basename "$0") env"
    [ -f "$IMAGE_PATH" ]     || die "image not built — run: $(basename "$0") env"

    # Phase 1: fetch and build every target module on the host (container).
    local conf built=()
    for conf in $confs; do
        ( TARGET_NAME=""; TARGET_GIT_URL=""; TARGET_GIT_REF="p11"
          TARGET_COV_PATTERN=""; TARGET_GUEST_TEST=""; TARGET_KCONFIG=""
          unset -f target_build 2>/dev/null || true
          # shellcheck disable=SC1090
          source "$conf"
          export TARGET_SRC="$UNIT_TESTS_DIR/$TARGET_NAME/src"
          reports="$UNIT_TESTS_DIR/$TARGET_NAME/reports"; mkdir -p "$reports"
          echo "▶ (build) $TARGET_NAME: fetching sources"
          fetch_target || { echo "❌ fetch failed for $TARGET_NAME"; exit 1; }

          # Verify that every symbol in TARGET_KCONFIG is present in the built
          # kernel's .config. Missing symbols mean prepare_env was run without
          # this target in TARGETS (or before the target's conf was updated).
          # Warn early rather than letting the compiler abort with a cryptic
          # #error inside the module sources.
          if [ -n "${TARGET_KCONFIG:-}" ] && [ -f "$KERNEL_BUILD_DIR/.config" ]; then
              local missing=""
              for ksym in $TARGET_KCONFIG; do
                  grep -qE "^CONFIG_${ksym}=[ym]" "$KERNEL_BUILD_DIR/.config" \
                      || missing="$missing CONFIG_${ksym}"
              done
              if [ -n "$missing" ]; then
                  echo "⚠️  $TARGET_NAME: kernel .config is missing:$missing"
                  echo "   The kernel was built without this target's kconfig."
                  echo "   Re-run with: TARGETS=\"$TARGET_NAME\" $(basename "$0") env"
                  echo "   then retry:  TARGETS=\"$TARGET_NAME\" $(basename "$0") run"
              fi
          fi

          echo "▶ (build) $TARGET_NAME: building module(s) against the gcov kernel"
          target_build 2>&1 | tee "$reports/build.log"; _rc=${PIPESTATUS[0]:-0}
          [ "$_rc" -eq 0 ] || echo "⚠️  build reported errors for $TARGET_NAME (see build.log)"
        ) && built+=("$conf")
    done

    # Phase 2: boot the guest once and run each target's tests in turn.
    vm_boot "$UNIT_TESTS_DIR/vm_boot.log" || die "VM did not boot"
    [ "$KEEP_VM" = "0" ] && trap 'vm_poweroff' EXIT || true

    for conf in "${built[@]}"; do
        # Re-source per target to get its variables and driver in this shell.
        TARGET_NAME=""; TARGET_GIT_URL=""; TARGET_GIT_REF="p11"
        TARGET_COV_PATTERN=""; TARGET_GUEST_TEST=""; TARGET_KCONFIG=""
        TARGET_COVERAGE_MODE="module"; TARGET_DEFAULT=1
        # shellcheck disable=SC1090
        source "$conf"
        export TARGET_SRC="$UNIT_TESTS_DIR/$TARGET_NAME/src"
        echo "==================== $TARGET_NAME ===================="
        test_target || echo "⚠️  $TARGET_NAME: test/collect step had errors"
    done

    if [ "$KEEP_VM" = "0" ]; then
        vm_poweroff; trap - EXIT
    else
        echo "ℹ️  --keep-vm: guest left running (SSH port ${VM_SSH_PORT:-22010})"
    fi
    print_summary "$confs"
}

print_summary() {
    local confs="$1" conf
    local sumfile="$UNIT_TESTS_DIR/summary.txt"
    {
        echo "alt-syz-box unit-tests coverage summary"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
    } > "$sumfile"

    echo ""
    echo "======================= UNIT-TESTS SUMMARY ======================="
    for conf in $confs; do
        ( # shellcheck disable=SC1090
          source "$conf"
          r="$UNIT_TESTS_DIR/$TARGET_NAME/reports"
          rate="n/a"
          if [ -f "$r/coverage-summary.txt" ]; then
              rate="$(grep -Eo 'lines[^0-9]*[0-9.]+%' "$r/coverage-summary.txt" \
                       | grep -Eo '[0-9.]+%' | head -1)"
              [ -n "$rate" ] || rate="n/a"
          fi
          line="  $TARGET_NAME: lines=$rate"
          [ -f "$r/report.pdf" ]        && line="$line  pdf=$r/report.pdf"
          [ -f "$r/html/index.html" ]   && line="$line  html=$r/html/index.html"
          echo "$line"
          echo "$TARGET_NAME: lines=$rate | pdf=$r/report.pdf | html=$r/html/index.html | tests=$r/tests.log" >> "$sumfile"
        )
    done
    echo ""
    echo "Summary file:      $sumfile"
    echo "Per target:        $UNIT_TESTS_DIR/<target>/reports/{report.pdf,html/index.html,tests.log}"
    echo "To open a shell in the same VM manually: ./scripts/run-vm.sh"
    echo "=================================================================="
}

# --- entry point ------------------------------------------------------------

KEEP_VM=0
for _f in "$@"; do case "$_f" in
    --keep-vm)    KEEP_VM=1 ;;
    --sanitizers) export ENABLE_SANITIZERS=1 ;;
esac; done

case "${1:-all}" in
    -h|--help) help; exit 0 ;;
    --keep-vm|--sanitizers) : ;; # already parsed above
    list)
        echo "Targets enabled in the default run:"
        for c in $(select_targets); do echo "  - $(basename "$c" .conf)"; done
        echo "Opt-in targets (require TARGETS=\"name\"):"
        for c in "$UNIT_TESTS_TARGETS_DIR"/*.conf; do
            [ -e "$c" ] || continue
            _n="$(basename "$c" .conf)"
            _d=$(bash -c "TARGET_DEFAULT=1; source \"$c\" 2>/dev/null; echo \$TARGET_DEFAULT")
            [ "${_d:-1}" = "0" ] \
                && echo "  - $_n  (use: TARGETS=\"$_n\" ./run-all.sh unit-tests)"
        done ;;
    env)       prepare_env ;;
    run)       run_targets ;;
    all)       prepare_env; run_targets ;;
    *)         echo "Error: unknown command '$1'"; help; exit 1 ;;
esac

echo "✅ Unit-tests command '${1:-all}' finished."

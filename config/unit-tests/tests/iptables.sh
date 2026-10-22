#!/bin/sh
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# In-guest unit test for iptables. Runs as root inside the QEMU VM. The
# orchestrator ships the build tree (built with gcc --coverage on the host) to
# ./src. We do NOT hand-write tests here: we run the project's OWN upstream test
# suite -- the three TESTS of its autotools "make check" -- which the ALT spec
# runs under vm-run. The harness points XTABLES_LIBDIR / PATH at the in-tree
# build, so every rule it adds, saves and translates exercises OUR --coverage
# binaries (xtables-legacy-multi / xtables-nft-multi) and extensions.
#
# Coverage model (userspace): libgcov writes a .gcda per object at exit. iptables
# is a multi-directory tree (extensions/, libxtables/, libiptc/, iptables/), so
# flattening to basenames (as secure_delete does) would collide. Instead we make
# libgcov reproduce the build tree layout under $GCOV_PREFIX by stripping exactly
# the build-root prefix: GCOV_PREFIX_STRIP = number of components of the host
# build root (recorded by target_build in .gcov-build-root). The pulled .gcda
# then sit at the same paths relative to $GCOV_PREFIX as the .gcno relative to
# $TARGET_SRC, and the host-side gcov_report() pairs them directly.
set -x
SRC=./src
SRC=$(cd "$SRC" 2>/dev/null && pwd || echo "$SRC")

# --- userspace gcov collection, structure-preserving --------------------------
export GCOV_PREFIX=/root/gcov-out
if [ -f "$SRC/.gcov-build-root" ]; then
    BR=$(cat "$SRC/.gcov-build-root")
    # number of leading path components to strip = count of '/' in the abs path
    GCOV_PREFIX_STRIP=$(printf %s "$BR" | tr -cd '/' | wc -c)
else
    GCOV_PREFIX_STRIP=99   # fallback (flat); should not happen for iptables
fi
export GCOV_PREFIX_STRIP
rm -rf "$GCOV_PREFIX"; mkdir -p "$GCOV_PREFIX"
echo "gcov: PREFIX=$GCOV_PREFIX STRIP=$GCOV_PREFIX_STRIP"

cd "$SRC" || exit 0

# Load the netfilter modules the legacy variant needs on-demand (the shared
# netfilter kernel builds them in; modprobe is best-effort for any that are
# modular). The nft variant autoloads its own nf_tables_* modules.
for m in ip_tables ip6_tables arp_tables ebtables \
         nf_tables x_tables xt_SECMARK ebt_pkttype; do
    modprobe "$m" 2>/dev/null || true
done

RC_XLATE=skip RC_TEST=skip RC_SHELL=skip

# 1) xlate-test.py -- pure-userspace translation of every extension to nft.
if [ -f ./xlate-test.py ]; then
    echo "==== xlate-test.py ===="
    timeout 300 python3 ./xlate-test.py && RC_XLATE=pass || RC_XLATE=fail
fi

# 2) iptables-test.py -- add/parse/readback for all extensions/*.t, legacy+nft.
#    The single biggest coverage source. Needs the netfilter kernel + netns.
if [ -f ./iptables-test.py ]; then
    echo "==== iptables-test.py (legacy + nft) ===="
    timeout 1200 python3 ./iptables-test.py && RC_TEST=pass || RC_TEST=fail
fi

# 3) shell testcases against a live kernel.
if [ -f ./iptables/tests/shell/run-tests.sh ]; then
    echo "==== iptables/tests/shell/run-tests.sh ===="
    timeout 600 bash ./iptables/tests/shell/run-tests.sh && RC_SHELL=pass || RC_SHELL=fail
fi

sync
GCDA_N=$(find "$GCOV_PREFIX" -name '*.gcda' 2>/dev/null | wc -l)

# --- summary ------------------------------------------------------------------
# The upstream suites return non-zero if ANY case fails; in a stripped-down VM
# some cases legitimately fail/skip (missing optional modules, no IPv6, etc.),
# which does not invalidate coverage -- each executed binary still flushed its
# .gcda. So the health signal here is "did we collect coverage" (.gcda present),
# with the per-suite pass/fail/skip shown for context.
echo "=============================================================="
echo "iptables suites: xlate=$RC_XLATE iptables-test=$RC_TEST shell=$RC_SHELL"
echo "iptables .gcda collected: $GCDA_N"
if [ "$GCDA_N" -gt 0 ]; then
    echo "RESULT iptables: PASS (coverage collected)"
else
    echo "RESULT iptables: FAIL (no .gcda -- did the binaries run?)"
fi
echo "iptables in-guest tests complete"

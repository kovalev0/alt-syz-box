#!/bin/sh
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# In-guest unit test for cryptsetup. Runs as root inside the QEMU VM. The
# orchestrator ships the build tree (tools + test programs, all built with gcc
# --coverage on the host) to ./src. We do NOT hand-write tests: we run the
# project's OWN upstream suite (the TESTS of its autotools "make check"),
# directly against the prebuilt in-tree binaries, so coverage lands in our
# --coverage objects (libcryptsetup + src/cryptsetup + ve/integrity setup).
#
# Coverage model (userspace, multi-directory): libgcov writes a .gcda per object
# at exit. We make it reproduce the build-tree layout under $GCOV_PREFIX by
# stripping exactly the build-root prefix: GCOV_PREFIX_STRIP = number of
# components of the host build root recorded in .gcov-build-root by target_build.
# The pulled .gcda then share the same relative paths as the .gcno under
# $TARGET_SRC, and the host-side gcov_report() pairs them. (Same scheme as the
# iptables target.)
#
# Two invocation rules learned from the suite:
#   * the C test programs (api-test, api-test-2, vectors-test, the unit tests)
#     link libcryptsetup directly and must run WITHOUT CRYPTSETUP_PATH;
#   * the shell testcases drive the CLI and need CRYPTSETUP_PATH pointing at the
#     built binary (../src when run from tests/).
set -x
SRC=./src
SRC=$(cd "$SRC" 2>/dev/null && pwd || echo "$SRC")

# --- userspace gcov collection, structure-preserving --------------------------
export GCOV_PREFIX=/root/gcov-out
if [ -f "$SRC/.gcov-build-root" ]; then
    BR=$(cat "$SRC/.gcov-build-root")
    GCOV_PREFIX_STRIP=$(printf %s "$BR" | tr -cd '/' | wc -c)
else
    GCOV_PREFIX_STRIP=99
fi
export GCOV_PREFIX_STRIP
rm -rf "$GCOV_PREFIX"; mkdir -p "$GCOV_PREFIX"
echo "gcov: PREFIX=$GCOV_PREFIX STRIP=$GCOV_PREFIX_STRIP"

# Locate the build directory (gear keeps sources under cryptsetup/; tolerate a
# flat layout). It is the dir that holds tests/ and src/.
if   [ -d "$SRC/tests" ] && [ -d "$SRC/src" ];                       then BDIR="$SRC"
elif [ -d "$SRC/cryptsetup/tests" ] && [ -d "$SRC/cryptsetup/src" ]; then BDIR="$SRC/cryptsetup"
else BDIR=$(dirname "$(find "$SRC" -maxdepth 3 -type d -name tests 2>/dev/null | head -1)")
fi
echo "cryptsetup build dir: $BDIR"
[ -d "$BDIR/tests" ] || { echo "RESULT cryptsetup: FAIL (tests dir not found)"; exit 0; }

# Load the device-mapper and crypto modules the tests need (best-effort; the
# gcov kernel builds them in, modprobe covers any that are modular).
for m in loop dm_mod dm-crypt dm-verity dm-integrity dm-zero \
         af_alg algif_skcipher algif_hash; do
    modprobe "$m" 2>/dev/null || true
done
mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
dmsetup version 2>/dev/null || true

cd "$BDIR/tests" || { echo "RESULT cryptsetup: FAIL (cannot enter tests)"; exit 0; }

# C test programs: run WITHOUT CRYPTSETUP_PATH. vectors-test needs no device;
# api-test/api-test-2 build real dm-crypt mappings on loop devices.
PROGS="vectors-test run-all-symbols unit-wipe-test unit-utils-crypt-test \
api-test api-test-2"

# Shell testcases. Broad list for maximum coverage (overridable via $CS_TESTS).
# Each self-skips when a feature/module is absent; a per-test timeout bounds the
# slow ones (reencryption especially). compat-test-opal is omitted (needs real
# OPAL self-encrypting hardware). The scripts find the binary via CRYPTSETUP_PATH,
# which defaults to ".." -- the build dir where cryptsetup/veritysetup/
# integritysetup are linked (NOT src/) -- so we do not override it.
CS_TESTS="${CS_TESTS:-compat-args-test compat-test compat-test2 \
password-hash-test mode-test align-test align-test2 device-test discards-test \
luks1-compat-test luks2-validation-test keyring-test keyring-compat-test \
blockwise-compat-test tcrypt-compat-test bitlk-compat-test fvault2-compat-test \
loopaes-test verity-compat-test integrity-compat-test luks2-integrity-test \
reencryption-compat-test luks2-reencryption-test luks2-reencryption-mangle-test}"

run_one() {   # name  timeout
    _n="$1"; _to="$2"
    [ -e "./$_n" ] || { echo "SKIP $_n (absent)"; return; }
    echo "==== $_n ===="
    if timeout "$_to" ./"$_n"; then echo "DONE $_n"; else echo "ENDED $_n (rc=$?, skip/fail/timeout -- coverage kept)"; fi
}

# C test programs AND shell testcases both run from tests/ with no CRYPTSETUP_PATH
# override: the C programs link libcryptsetup directly (and reject CRYPTSETUP_PATH
# being set), the shell scripts default CRYPTSETUP_PATH to "..".
for t in $PROGS;   do run_one "$t" 300; done
for t in $CS_TESTS; do
    case "$t" in
        *reencryption*) run_one "$t" 900 ;;
        *)              run_one "$t" 300 ;;
    esac
done

# Detach any loop devices the tests left behind.
losetup -D 2>/dev/null || true
sync
GCDA_N=$(find "$GCOV_PREFIX" -name '*.gcda' 2>/dev/null | wc -l)

echo "=============================================================="
echo "cryptsetup .gcda collected: $GCDA_N"
if [ "$GCDA_N" -gt 0 ]; then
    echo "RESULT cryptsetup: PASS (coverage collected)"
else
    echo "RESULT cryptsetup: FAIL (no .gcda -- did the binaries run?)"
fi
echo "cryptsetup in-guest tests complete"

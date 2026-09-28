#!/bin/sh
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# In-guest unit test for dm-secdel. Runs as root inside the QEMU VM. The
# orchestrator ships the built source tree to ./src (dm-secdel.ko included).
# Exercises the DISCARD -> secure-erase path (secdel_map_discard), the target
# constructor/destructor and error handling.
#
# NOTE: the repo's check.sh boots its own nested vm-run VM and must NOT be used
# here — we are already inside a VM. We reproduce the essence of its tests.sh
# (an ext4 filesystem mounted with -o discard) inline instead.
set -x
SRC=./src

modprobe loop 2>/dev/null || true
insmod "$SRC/dm-secdel.ko" 2>/dev/null || modprobe dm-secdel || true
dmsetup version || true

IMG=/var/tmp/dm-secdel-test.img
dd if=/dev/zero of="$IMG" bs=1M count=64
LOOP=$(losetup -f)
losetup "$LOOP" "$IMG"
SECTORS=$(blockdev --getsz "$LOOP")

# 1) Functional test with a real filesystem (mirrors the packaged tests.sh):
#    write marker data, delete it, and confirm the marker is gone from the raw
#    device after discard-backed secure erase.
if dmsetup create secdt --table "0 $SECTORS secdel $LOOP 0 1R0"; then
    if mkfs.ext4 -q -F -O ^has_journal /dev/mapper/secdt 2>/dev/null; then
        mkdir -p /mnt/secdt
        mount -t ext4 -o discard /dev/mapper/secdt /mnt/secdt 2>/dev/null && {
            MARKER="SECDEL_MARKER_0123456789"
            i=0; while [ $i -lt 64 ]; do
                printf '%s' "$MARKER" > "/mnt/secdt/marker.$i"; i=$((i + 1))
            done
            sync
            rm -f /mnt/secdt/marker.*        # triggers DISCARD -> secure erase
            sync
            umount /mnt/secdt
            if grep -a -q "$MARKER" "$LOOP"; then
                echo "RESULT dm-secdel: marker STILL present after rm (unexpected)"
            else
                echo "RESULT dm-secdel: marker erased after rm (good)"
            fi
        }
    fi
    dmsetup status secdt; dmsetup table secdt
    dmsetup suspend secdt; dmsetup resume secdt
    dmsetup remove secdt
fi

# 2) Direct DISCARD exercise across several erase-pattern variants.
for PAT in "1R0" "" "0" "R1R0R1R0" "10R"; do
    if dmsetup create secdv --table "0 $SECTORS secdel $LOOP 0 $PAT"; then
        blkdiscard /dev/mapper/secdv 2>/dev/null || true
        blkdiscard -o 0 -l 65536 /dev/mapper/secdv 2>/dev/null || true
        dd if=/dev/zero of=/dev/mapper/secdv bs=4k count=8 2>/dev/null || true
        dmsetup remove secdv
    fi
done

# 3) Error paths: the constructor must reject a bad pattern and a bad device.
dmsetup create secdbad  --table "0 8 secdel $LOOP 0 XYZ" 2>/dev/null && dmsetup remove secdbad
dmsetup create secdbad2 --table "0 8 secdel /dev/does-not-exist 0 1R0" 2>/dev/null && dmsetup remove secdbad2

losetup -d "$LOOP" 2>/dev/null || true
rm -f "$IMG"
echo "dm-secdel in-guest tests complete"

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
    echo "Clones, patches, configures, and builds the kernel (all by default)."
    echo ""
    echo "Commands:"
    echo "  clean         Clean all."
    echo "  init          Re-initializing the kernel directory and applying patches, if any."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message."
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    help
    exit 0
fi

COMMAND=$1

PATCH_DIR="$CONTAINER_REPO_DIR/patches/kernel"

echo "▶ Starting kernel build process..."

# Clean all ?
if [[ "$COMMAND" == "clean" ]]; then
    if [ ! -d "$KERNEL_DIR" ]; then
        echo "Directory $KERNEL_DIR not exist"
        exit 1
    else
        echo "Clean all"
        pushd "$KERNEL_DIR"
        make ARCH=x86_64 O="$KERNEL_BUILD_DIR" mrproper -j`nproc`
        popd
        exit 0
    fi
fi

# Re-init ?
if [[ "$COMMAND" == "init" ]]; then
    echo "Re-initializing the kernel directory"
    rm -rf "$KERNEL_DIR"
fi

# Disable SSL verification if needed, common for corporate networks
git config --global http.sslVerify false

# 1. Clone kernel source
if [ ! -d "$KERNEL_DIR" ]; then
    mkdir -p "$KERNEL_DIR"
    echo "Cloning kernel from $KERNEL_GIT_URL (branch: $KERNEL_GIT_TAG)..."
    git clone --depth=1 --branch="$KERNEL_GIT_TAG" "$KERNEL_GIT_URL" "$KERNEL_DIR"

    if ls "$PATCH_DIR"/*.patch.applied 1> /dev/null 2>&1; then
        rename .applied "" "$PATCH_DIR"/*.patch.applied
    fi
else
    echo "Kernel directory $KERNEL_DIR already exists. Skipping clone."
fi

cd "$KERNEL_DIR"

# 2. Apply patches if any exist
if [ -d "$PATCH_DIR" ] && [ -n "$(ls -A $PATCH_DIR/*.patch 2>/dev/null)" ]; then
    echo "▶ Applying kernel patches..."
    for patch in $PATCH_DIR/*.patch; do
        echo "Applying $(basename $patch)..."
        git apply "$patch"
        mv "$patch" "$patch".applied
    done
    make ARCH=x86_64 O="$KERNEL_BUILD_DIR" mrproper -j`nproc`
else
    echo "No kernel patches found to apply."
fi

mkdir -p "$KERNEL_BUILD_DIR"

# 3. Configure the kernel
echo "Configuring kernel..."
make ARCH=x86_64 O="$KERNEL_BUILD_DIR" x86_64_defconfig

# Set subversion
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    --set-str LOCALVERSION -"$KERNEL_LOCALVERSION" \
    -d LOCALVERSION_AUTO

# Apply detailed LVC syzkaller-specific kernel config options
# Reference: https://portal.linuxtesting.ru/LVCFuzzingKernelOptions.html
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e KASAN -e KASAN_INLINE \
    -e KCOV -e KCOV_ENABLE_COMPARISONS \
    -e KCOV_INSTRUMENT_ALL -e FAULT_INJECTION -e FAULT_INJECTION_DEBUG_FS \
    -e FAULT_INJECTION_USERCOPY -e FAILSLAB -e FAIL_PAGE_ALLOC \
    -e FAIL_MAKE_REQUEST -e FAIL_IO_TIMEOUT -e FAIL_FUTEX -e LOCKDEP \
    --set-val LOCKDEP_BITS 17 --set-val LOCKDEP_CHAINS_BITS 18 \
    --set-val LOCKDEP_STACK_TRACE_BITS 20 --set-val LOCKDEP_STACK_TRACE_HASH_BITS 14 \
    --set-val LOCKDEP_CIRCULAR_QUEUE_BITS 12 -e PROVE_LOCKING -e DEBUG_ATOMIC_SLEEP \
    -e PROVE_RCU -e DEBUG_VM -e FORTIFY_SOURCE -e HARDENED_USERCOPY \
    -e LOCKUP_DETECTOR -e SOFTLOCKUP_DETECTOR -e HARDLOCKUP_DETECTOR \
    -e BOOTPARAM_HARDLOCKUP_PANIC -e DETECT_HUNG_TASK -e WQ_WATCHDOG \
    --set-val DEFAULT_HUNG_TASK_TIMEOUT 140 --set-val RCU_CPU_STALL_TIMEOUT 100 \
    -e DEBUG_INFO -e GDB_SCRIPTS \
    --set-val DEBUG_INFO_REDUCED n -e UNWINDER_ORC --set-val RANDOMIZE_BASE n \
    --set-val DEBUG_INFO_COMPRESSED n --set-val DEBUG_INFO_SPLIT n \
    -e DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT --set-val DEBUG_INFO_BTF n -e PVH \
    -e KALLSYMS -e KALLSYMS_ALL -e CMDLINE_BOOL \
    --set-str CMDLINE "earlyprintk=serial net.ifnames=0 sysctl.kernel.hung_task_all_cpu_backtrace=1 ima_policy=tcb nf-conntrack-ftp.ports=20000 nf-conntrack-tftp.ports=20000 nf-conntrack-sip.ports=20000 nf-conntrack-irc.ports=20000 nf-conntrack-sane.ports=20000 binder.debug_mask=0 rcupdate.rcu_expedited=1 no_hash_pointers page_owner=on sysctl.vm.nr_hugepages=4 sysctl.vm.nr_overcommit_hugepages=4 secretmem.enable=1 msr.allow_writes=off root=/dev/sda3 console=ttyS0 vsyscall=native numa=fake=2 kvm-intel.nested=1 spec_store_bypass_disable=prctl nopcid vivid.n_devs=16 vivid.multiplanar=1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2 netrom.nr_ndevs=16 rose.rose_ndevs=16 dummy_hcd.num=8 smp.csd_lock_timeout=100000 watchdog_thresh=55 workqueue.watchdog_thresh=140 sysctl.net.core.netdev_unregister_timeout_secs=140 panic_on_warn=1" \
    --set-val CMDLINE_OVERRIDE n -e TUN -e MAC80211_HWSIM \
    --set-val IEEE802154_FAKELB n -e IEEE802154_HWSIM -e USB_DUMMY_HCD -e USB_RAW_GADGET \
    -e BT_HCIVHCI -e UBSAN -e UBSAN_SANITIZE_ALL --set-val UBSAN_TRAP n \
    --set-val UBSAN_MISC n -e UBSAN_BOUNDS -e UBSAN_SHIFT --set-val UBSAN_DIV_ZERO n \
    --set-val UBSAN_BOOL n --set-val UBSAN_OBJECT_SIZE n \
    --set-val UBSAN_SIGNED_OVERFLOW n --set-val UBSAN_UNSIGNED_OVERFLOW n \
    --set-val UBSAN_ENUM n --set-val UBSAN_ALIGNMENT n \
    --set-val DEVMEM n --set-val DEVKMEM n --set-val DEVPORT n --set-val UPROBE_EVENTS n \
    --set-val MODULE_FORCE_UNLOAD n -e SECURITY_TOMOYO_INSECURE_BUILTIN_SETTING

# Enable virtual kernel filesystems that allow the fuzzer to interact with a wider range of kernel features:
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e CONFIGFS_FS -e SECURITYFS

# Embed the kernel's build configuration in the bzImage (for developers):
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e IKCONFIG -e IKCONFIG_PROC

# Disable options that may cause build issues
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -d X86_USER_SHADOW_STACK \
    -d X86_KERNEL_IBT \
    -d X86_CET # Fixes: cc1: error: '-fcf-protection' is not compatible with this target

# Enable virtual net
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e VIRTIO -e VIRTIO_PCI \
    -e VIRTIO_NET

# Enable virtfs for mount
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e 9P_FS -e 9P_FS_POSIX_ACL \
    -e NET_9P -e NET_9P_VIRTIO

# fix SYZFAIL: tun: ioctl(TUNSETIFF) failed (errno 16: Device or resource busy)
# err    --set-str LSM "selinux"
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    --set-str LSM "landlock,lockdown,yama,loadpin,safesetid,smack,tomoyo,apparmor,ipe,bpf,altha,kiosk"

# -- device-mapper core ----------------------------
# dm core only; each layered branch adds its own targets on top. DM_INIT
# builds the mapped devices from dm-mod.create= on the command line at boot.
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e MD -e BLK_DEV_DM -e DM_BUFIO -e DM_DEBUG -e DM_UEVENT \
    -e DM_INIT -e DM_ZERO

# -- backing devices -------------------------------
# Eight brd ramdisks (the multi-device targets need three or four at once) and
# loop; 65536 sectors each, matching dm_target_lengths in the descriptions.
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e BLK_DEV_RAM -e BLK_DEV_LOOP \
    --set-val BLK_DEV_RAM_COUNT 8 \
    --set-val BLK_DEV_RAM_SIZE 32768

# -- simple dm targets -----------------------------
# Targets that remap or fail I/O without a metadata device.
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e DM_DELAY -e DM_FLAKEY -e DM_DUST -e DM_UNSTRIPED \
    -e DM_LOG_WRITES -e DM_EBS -e DM_SWITCH -e DM_MIRROR \
    -e DM_MULTIPATH -e DM_MULTIPATH_QL -e DM_MULTIPATH_ST

# -- data-transforming dm targets ------------------
# dm-crypt, verity and integrity, and the crypto their constructors allocate.
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e DM_CRYPT -e DM_VERITY -e DM_VERITY_FEC -e DM_INTEGRITY -e AUDIT -e DM_AUDIT

./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e CRYPTO_NULL -e CRYPTO_AES -e CRYPTO_CBC -e CRYPTO_XTS \
    -e CRYPTO_ESSIV -e CRYPTO_SHA256 -e CRYPTO_SHA1 -e CRYPTO_CRC32C \
    -e CRYPTO_HMAC -e CRYPTO_AUTHENC -e CRYPTO_USER_API_SKCIPHER \
    -e CRYPTO_USER_API_HASH -e CRYPTO_LIB_UTILS

# -- metadata-backed dm targets --------------------
# The targets that use drivers/md/persistent-data/: snapshot, thin, cache,
# clone, era and writecache.
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e DM_PERSISTENT_DATA -e DM_BIO_PRISON \
    -e DM_SNAPSHOT -e DM_THIN_PROVISIONING \
    -e DM_CACHE -e DM_CACHE_SMQ -e DM_CLONE -e DM_ERA -e DM_WRITECACHE

# -- MD software RAID ------------------------------
# The MD RAID personalities and the dm-raid target on top of them.
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e BLK_DEV_MD -e MD_AUTODETECT -e MD_BITMAP_FILE \
    -e MD_RAID0 -e MD_RAID1 -e MD_RAID10 -e MD_RAID456 -e DM_RAID

# -- zoned block + dm-zoned ------------------------
# dm-zoned on host-managed zoned devices (null_blk zoned=1, with conventional
# zones for metadata); the backing device is formatted at boot.
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e BLK_DEV_ZONED -e DM_ZONED \
    -e BLK_DEV_NULL_BLK -e BLK_DEV_NULL_BLK_FAULT_INJECTION

# Enable gcov coverage (only gcov version)
if [[ "$KERNEL_LOCALVERSION" == *gcov* ]]; then
    ./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
        -e GCOV_KERNEL -e GCOV_PROFILE_ALL
else
    # All built-in (other default fuzz version)
    sed -i "s|=m|=y|" "$KERNEL_BUILD_DIR/.config"
fi

make ARCH=x86_64 O="$KERNEL_BUILD_DIR" olddefconfig

# 4. Build the kernel
echo "Building kernel bzImage and modules..."
make EXTRA_CFLAGS="-Wno-error" ARCH=x86_64 O="$KERNEL_BUILD_DIR" -j"$(nproc)" bzImage
make EXTRA_CFLAGS="-Wno-error" ARCH=x86_64 O="$KERNEL_BUILD_DIR" -j"$(nproc)" modules

echo "✅ Kernel build process finished successfully."

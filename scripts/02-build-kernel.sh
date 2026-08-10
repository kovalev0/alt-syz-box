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

#----------------------------------------------------
# Apply ALT config
# https://packages.altlinux.org/ru/c10f2/srpms/kernel-image-6.12/
# curl -s https://git.altlinux.org/tasks/428682/build/100/x86_64/rpms/kernel-image-6.12-6.12.102-alt0.c10f.2.x86_64.rpm | rpm2cpio | cpio -imdv "./boot/config-6.12.102-6.12-alt0.c10f.2"
cat "$CONTAINER_REPO_DIR/config/kernel/config-6.12.102-6.12-alt0.c10f.2" >> "$KERNEL_BUILD_DIR/.config"

# Sets the necessary baseline configuration options (including those required to
# boot without an initrd) before the final configuration or manual overrides are applied.
cat "$KERNEL_DIR"/arch/x86/configs/x86_64_defconfig >> "$KERNEL_BUILD_DIR/.config"

#----------------------------------------------------

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

# Enable gcov coverage (only gcov version)
if [[ "$KERNEL_LOCALVERSION" == *gcov* ]]; then
    ./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
        -e GCOV_KERNEL -e GCOV_PROFILE_ALL
else
    # All built-in (other default fuzz version)
    # sed -i "s|=m|=y|" "$KERNEL_BUILD_DIR/.config"
    echo "Skip \"All built-in\", use ALT release config"
fi

make ARCH=x86_64 O="$KERNEL_BUILD_DIR" olddefconfig

# 4. Build the kernel
echo "Building kernel bzImage and modules..."
make EXTRA_CFLAGS="-Wno-error" ARCH=x86_64 O="$KERNEL_BUILD_DIR" -j"$(nproc)" bzImage
make EXTRA_CFLAGS="-Wno-error" ARCH=x86_64 O="$KERNEL_BUILD_DIR" -j"$(nproc)" modules

echo "✅ Kernel build process finished successfully."

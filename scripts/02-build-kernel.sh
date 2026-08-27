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


# 2b. Graft out-of-tree modules into the kernel source tree before defconfig
echo "Grafting out-of-tree modules into kernel source tree..."
"$CONTAINER_REPO_DIR/scripts/graft-oot-xtables-addons.sh"
"$CONTAINER_REPO_DIR/scripts/graft-oot-ipt-so.sh"

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

# -- netfilter -------------------------------------
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e NF_TABLES -e NF_TABLES_INET \
    -e IP_NF_IPTABLES -e IP_NF_FILTER -e IP_NF_MANGLE \
    -e IP_NF_NAT -e IP_NF_SECURITY -e IP_NF_RAW \
    -e IP6_NF_IPTABLES -e IP6_NF_FILTER -e IP6_NF_MANGLE \
    -e IP6_NF_NAT -e IP6_NF_SECURITY -e IP6_NF_RAW \
    -e NETFILTER_XTABLES -e NF_CONNTRACK -e NF_NAT \
    -e NF_CONNTRACK_MARK -e NETFILTER_ADVANCED

# xt_pknock_mt_init() bails out with -ENXIO unless crypto_alloc_shash() can
# produce its default "hmac(sha256)" transform. "hmac(...)" is a crypto
# *template*, so CRYPTO_MANAGER is required to instantiate it -- CRYPTO_HMAC and
# CRYPTO_SHA256 alone are not enough. Without this the module never registers:
# /proc/net/xt_pknock is absent and xt_pknock.c stays at 0% of 214 lines.
# Note that init also calls request_module(), which returns -ENOSYS when
# CONFIG_MODULES=n; if pknock still fails, check "dmesg | grep -i pknock" for
# which of the two messages it printed.
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e CRYPTO -e CRYPTO_ALGAPI -e CRYPTO_HASH \
    -e CRYPTO_MANAGER -e CRYPTO_MANAGER_DISABLE_TESTS \
    -e CRYPTO_HMAC -e CRYPTO_SHA256

# chaos_tg_init() looks up the REJECT target and the tcp match with
# xt_request_find_target()/xt_request_find_match(), which return ERR_PTR on
# failure -- but it tests them against NULL. When REJECT is not built the error
# pointer sails through the check and chaos_tg() dereferences it:
# "general protection fault in chaos_tg", 35 reboots in the last run. Building
# both makes the pointers valid and unblocks the rest of chaos_tg().
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e IP_NF_TARGET_REJECT -e IP6_NF_TARGET_REJECT \
    -e NETFILTER_XT_MATCH_TCPUDP

# -- xtables-addons (grafted into net/netfilter/xtables-addons/)
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e TEXTSEARCH -e TEXTSEARCH_KMP -e TEXTSEARCH_BM -e TEXTSEARCH_FSM \
    -e NETFILTER_XT_MATCH_CONDITION \
    -e NETFILTER_XT_MATCH_QUOTA2 \
    -e NETFILTER_XT_MATCH_FUZZY \
    -e NETFILTER_XT_MATCH_IFACE \
    -e NETFILTER_XT_MATCH_LENGTH2 \
    -e NETFILTER_XT_MATCH_IPP2P \
    -e NETFILTER_XT_MATCH_PSD \
    -e NETFILTER_XT_MATCH_GEOIP \
    -e NETFILTER_XT_MATCH_ASN \
    -e NETFILTER_XT_MATCH_IPV4OPTIONS \
    -e NETFILTER_XT_MATCH_LSCAN \
    -e NETFILTER_XT_MATCH_PKNOCK \
    -e NETFILTER_XT_TARGET_TARPIT \
    -e NETFILTER_XT_TARGET_CHAOS \
    -e NETFILTER_XT_TARGET_DELUDE \
    -e NETFILTER_XT_TARGET_ECHO \
    -e NETFILTER_XT_TARGET_IPMARK \
    -e NETFILTER_XT_TARGET_LOGMARK \
    -e NETFILTER_XT_TARGET_PROTO \
    -e NETFILTER_XT_TARGET_DHCPMAC \
    -e NETFILTER_XT_TARGET_DNETMAP \
    -e NETFILTER_XT_TARGET_ACCOUNT
# Note: NETFILTER_XT_TARGET_SYSRQ intentionally omitted

# -- ipt-so (grafted alongside xtables-addons) -----
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e NETLABEL \
    -e CIPSO_IPV4 \
    -e NETWORK_SECMARK \
    -e NETFILTER_XT_MATCH_SO

# Enable gcov coverage (only gcov version)
if [[ "$KERNEL_LOCALVERSION" == *gcov* ]]; then
    ./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
        -e GCOV_KERNEL -e GCOV_PROFILE_ALL
else
    # All built-in (other default fuzz version)
    sed -i "s|=m|=y|" "$KERNEL_BUILD_DIR/.config"
fi

make ARCH=x86_64 O="$KERNEL_BUILD_DIR" olddefconfig

# Verify that the options we depend on survived olddefconfig.
# KCOV_ENABLE_COMPARISONS in particular is silently dropped when its
# dependencies are not met, and syz-manager then reports
# "Comparisons: got no coverage" -- an expensive loss on x_tables, where
# nearly every decision is a strcmp() on a table or extension name.
echo "▶ Verifying key kernel options..."
_missing=0
for _opt in KCOV KCOV_ENABLE_COMPARISONS KCOV_INSTRUMENT_ALL KASAN DEBUG_INFO \
            NETFILTER_XTABLES IP_NF_IPTABLES IP_NF_SECURITY NETLABEL CIPSO_IPV4 \
            NETFILTER_XT_MATCH_SO NETFILTER_XT_TARGET_TARPIT \
            CRYPTO_HMAC CRYPTO_SHA256 CRYPTO_MANAGER \
            IP_NF_TARGET_REJECT NETFILTER_XT_MATCH_TCPUDP; do
    if ! grep -q "^CONFIG_${_opt}=y" "$KERNEL_BUILD_DIR/.config"; then
        echo "  ❌ CONFIG_${_opt} is not =y"
        _missing=1
    fi
done
[ "$_missing" = "0" ] && echo "  ✅ all checked options are enabled"

# 4. Build the kernel
echo "Building kernel bzImage and modules..."
make EXTRA_CFLAGS="-Wno-error" ARCH=x86_64 O="$KERNEL_BUILD_DIR" -j"$(nproc)" bzImage
make EXTRA_CFLAGS="-Wno-error" ARCH=x86_64 O="$KERNEL_BUILD_DIR" -j"$(nproc)" modules

echo "✅ Kernel build process finished successfully."

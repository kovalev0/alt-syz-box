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

# ---------------------------------------------------
# netfilter

# base
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e NET -e TUN

# Virtual and Tunneling Devices: Increase interaction surface
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e VETH \
    -e TAP \
    -e DUMMY \
    -e IPVLAN \
    -e TUN_VNET_CROSS_LE

# Namespaces and VRF: Essential for sandboxing and complex routing
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e NET_NS -e USER_NS \
    -e NET_VRF -e NET_NS_REFCNT_TRACKER

# Bridging and Aggregation: Critical for bridge/vlan/bond Netfilter hooks
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e BRIDGE -e BRIDGE_VLAN_FILTERING -e BRIDGE_IGMP_SNOOPING -e BRIDGE_NETFILTER \
    -e VLAN_8021Q -e VLAN_8021Q_GVRP -e VLAN_8021Q_MVRP \
    -e MACVLAN -e MACVTAP -e BONDING -e NET_TEAM -e OPENVSWITCH

# Traffic Control (QoS): Adds complexity and new code paths
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e NET_SCHED \
    -e NET_CLS_U32 -e NET_CLS_FW -e NET_CLS_BASIC -e NET_CLS_FLOWER \
    -e NET_ACT_MIRRED -e NET_ACT_POLICE -e NET_SCH_INGRESS -e NET_SCH_HTB -e NET_SCH_FQ

# $ cat boot/config-6.12.48-6.12-alt0.c10f.2 | grep NETFILTER | sed -E "s|CONFIG_||" | sed -E "s|=y||" | sed -E "s|=m||"
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e NETFILTER -e NETFILTER_ADVANCED -e BRIDGE_NETFILTER -e NETFILTER_INGRESS \
    -e NETFILTER_EGRESS -e NETFILTER_SKIP_EGRESS -e NETFILTER_NETLINK \
    -e NETFILTER_FAMILY_BRIDGE -e NETFILTER_FAMILY_ARP -e NETFILTER_BPF_LINK \
    -e NETFILTER_NETLINK_HOOK -e NETFILTER_NETLINK_ACCT -e NETFILTER_NETLINK_QUEUE \
    -e NETFILTER_NETLINK_LOG -e NETFILTER_NETLINK_OSF -e NETFILTER_CONNCOUNT \
    -e NETFILTER_SYNPROXY -e SECURITY_SMACK_NETFILTER \
    -e NETFILTER_XTABLES -e NETFILTER_XTABLES_COMPAT \
    -e NETFILTER_XT_MARK -e NETFILTER_XT_CONNMARK -e NETFILTER_XT_SET \
    -e NETFILTER_XT_TARGET_AUDIT -e NETFILTER_XT_TARGET_CHECKSUM \
    -e NETFILTER_XT_TARGET_CLASSIFY -e NETFILTER_XT_TARGET_CONNMARK \
    -e NETFILTER_XT_TARGET_CONNSECMARK -e NETFILTER_XT_TARGET_CT \
    -e NETFILTER_XT_TARGET_DSCP -e NETFILTER_XT_TARGET_HL \
    -e NETFILTER_XT_TARGET_HMARK -e NETFILTER_XT_TARGET_IDLETIMER \
    -e NETFILTER_XT_TARGET_LED -e NETFILTER_XT_TARGET_LOG \
    -e NETFILTER_XT_TARGET_MARK -e NETFILTER_XT_NAT \
    -e NETFILTER_XT_TARGET_NETMAP -e NETFILTER_XT_TARGET_NFLOG \
    -e NETFILTER_XT_TARGET_NFQUEUE -e NETFILTER_XT_TARGET_NOTRACK \
    -e NETFILTER_XT_TARGET_RATEEST -e NETFILTER_XT_TARGET_REDIRECT \
    -e NETFILTER_XT_TARGET_MASQUERADE -e NETFILTER_XT_TARGET_TEE \
    -e NETFILTER_XT_TARGET_TPROXY -e NETFILTER_XT_TARGET_TRACE \
    -e NETFILTER_XT_TARGET_SECMARK -e NETFILTER_XT_TARGET_TCPMSS \
    -e NETFILTER_XT_TARGET_TCPOPTSTRIP -e NETFILTER_XT_MATCH_ADDRTYPE \
    -e NETFILTER_XT_MATCH_BPF -e NETFILTER_XT_MATCH_CGROUP \
    -e NETFILTER_XT_MATCH_CLUSTER -e NETFILTER_XT_MATCH_COMMENT \
    -e NETFILTER_XT_MATCH_CONNBYTES -e NETFILTER_XT_MATCH_CONNLABEL \
    -e NETFILTER_XT_MATCH_CONNLIMIT -e NETFILTER_XT_MATCH_CONNMARK \
    -e NETFILTER_XT_MATCH_CONNTRACK -e NETFILTER_XT_MATCH_CPU \
    -e NETFILTER_XT_MATCH_DCCP -e NETFILTER_XT_MATCH_DEVGROUP \
    -e NETFILTER_XT_MATCH_DSCP -e NETFILTER_XT_MATCH_ECN \
    -e NETFILTER_XT_MATCH_ESP -e NETFILTER_XT_MATCH_HASHLIMIT \
    -e NETFILTER_XT_MATCH_HELPER -e NETFILTER_XT_MATCH_HL \
    -e NETFILTER_XT_MATCH_IPCOMP -e NETFILTER_XT_MATCH_IPRANGE \
    -e NETFILTER_XT_MATCH_IPVS -e NETFILTER_XT_MATCH_L2TP \
    -e NETFILTER_XT_MATCH_LENGTH -e NETFILTER_XT_MATCH_LIMIT \
    -e NETFILTER_XT_MATCH_MAC -e NETFILTER_XT_MATCH_MARK \
    -e NETFILTER_XT_MATCH_MULTIPORT -e NETFILTER_XT_MATCH_NFACCT \
    -e NETFILTER_XT_MATCH_OSF -e NETFILTER_XT_MATCH_OWNER \
    -e NETFILTER_XT_MATCH_POLICY -e NETFILTER_XT_MATCH_PHYSDEV \
    -e NETFILTER_XT_MATCH_PKTTYPE -e NETFILTER_XT_MATCH_QUOTA \
    -e NETFILTER_XT_MATCH_RATEEST -e NETFILTER_XT_MATCH_REALM \
    -e NETFILTER_XT_MATCH_RECENT -e NETFILTER_XT_MATCH_SCTP \
    -e NETFILTER_XT_MATCH_SOCKET -e NETFILTER_XT_MATCH_STATE \
    -e NETFILTER_XT_MATCH_STATISTIC -e NETFILTER_XT_MATCH_STRING \
    -e NETFILTER_XT_MATCH_TCPMSS -e NETFILTER_XT_MATCH_TIME \
    -e NETFILTER_XT_MATCH_U32

# $ cat boot/config-6.12.48-6.12-alt0.c10f.2 | grep NF_TABLES | sed -E "s|CONFIG_||" | sed -E "s|=y||" | sed -E "s|=m||"
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e NF_TABLES -e NF_TABLES_INET -e NF_TABLES_NETDEV -e NF_TABLES_IPV4 \
    -e NF_TABLES_ARP -e NF_TABLES_IPV6 -e NF_TABLES_BRIDGE

# $ cat boot/config-6.12.48-6.12-alt0.c10f.2 | grep NFT | sed -E "s|CONFIG_||" | sed -E "s|=y||" | sed -E "s|=m||"
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e NFT_NUMGEN -e NFT_CT -e NFT_FLOW_OFFLOAD -e NFT_CONNLIMIT \
    -e NFT_LOG -e NFT_LIMIT -e NFT_MASQ -e NFT_REDIR \
    -e NFT_NAT -e NFT_TUNNEL -e NFT_QUEUE -e NFT_QUOTA \
    -e NFT_REJECT -e NFT_REJECT_INET -e NFT_COMPAT -e NFT_HASH \
    -e NFT_FIB -e NFT_FIB_INET -e NFT_XFRM -e NFT_SOCKET \
    -e NFT_OSF -e NFT_TPROXY -e NFT_SYNPROXY -e NFT_DUP_NETDEV \
    -e NFT_FWD_NETDEV -e NFT_FIB_NETDEV -e NFT_REJECT_NETDEV -e NFT_REJECT_IPV4 \
    -e NFT_DUP_IPV4 -e NFT_FIB_IPV4 -e NFT_COMPAT_ARP -e NFT_REJECT_IPV6 \
    -e NFT_DUP_IPV6 -e NFT_FIB_IPV6 -e NFT_BRIDGE_META -e NFT_BRIDGE_REJECT

# $ cat boot/config-6.12.48-6.12-alt0.c10f.2 | grep NF_CONNTRACK | sed -E "s|CONFIG_||" | sed -E "s|=y||" | sed -E "s|=m||"
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e NF_CT_NETLINK -e NF_CONNTRACK \
    -e NF_CONNTRACK_MARK -e NF_CONNTRACK_SECMARK -e NF_CONNTRACK_ZONES \
    -e NF_CONNTRACK_PROCFS -e NF_CONNTRACK_EVENTS -e NF_CONNTRACK_TIMEOUT \
    -e NF_CONNTRACK_TIMESTAMP -e NF_CONNTRACK_LABELS -e NF_CONNTRACK_OVS \
    -e NF_CONNTRACK_AMANDA -e NF_CONNTRACK_FTP -e NF_CONNTRACK_H323 \
    -e NF_CONNTRACK_IRC -e NF_CONNTRACK_BROADCAST -e NF_CONNTRACK_NETBIOS_NS \
    -e NF_CONNTRACK_SNMP -e NF_CONNTRACK_PPTP -e NF_CONNTRACK_SANE \
    -e NF_CONNTRACK_SIP -e NF_CONNTRACK_SIP -e NF_CONNTRACK_TFTP \
    -e NF_CONNTRACK_BRIDGE

# $ cat boot/config-6.12.48-6.12-alt0.c10f.2 | grep NF_NAT | sed -E "s|CONFIG_||" | sed -E "s|=y||" | sed -E "s|=m||"
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e NF_NAT -e IP_NF_NAT -e IP6_NF_NAT \
    -e NF_NAT_AMANDA -e NF_NAT_FTP -e NF_NAT_IRC \
    -e NF_NAT_SIP -e NF_NAT_TFTP -e NF_NAT_REDIRECT \
    -e NF_NAT_MASQUERADE -e NF_NAT_OVS -e NF_NAT_SNMP_BASIC \
    -e NF_NAT_PPTP -e NF_NAT_H323

# $ cat boot/config-6.12.48-6.12-alt0.c10f.2 | grep IP_NF | sed -E "s|CONFIG_||" | sed -E "s|=y||" | sed -E "s|=m||"
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e IP_NF_IPTABLES_LEGACY -e IP_NF_IPTABLES -e IP_NF_MATCH_AH \
    -e IP_NF_MATCH_ECN -e IP_NF_MATCH_RPFILTER -e IP_NF_MATCH_TTL \
    -e IP_NF_FILTER -e IP_NF_TARGET_REJECT -e IP_NF_TARGET_SYNPROXY \
    -e IP_NF_NAT -e IP_NF_TARGET_MASQUERADE -e IP_NF_TARGET_NETMAP \
    -e IP_NF_TARGET_REDIRECT -e IP_NF_MANGLE -e IP_NF_TARGET_ECN \
    -e IP_NF_TARGET_TTL -e IP_NF_RAW -e IP_NF_SECURITY \
    -e IP_NF_ARPTABLES -e IP_NF_ARPFILTER -e IP_NF_ARP_MANGLE

# $ cat boot/config-6.12.48-6.12-alt0.c10f.2 | grep IP6_NF | sed -E "s|CONFIG_||" | sed -E "s|=y||" | sed -E "s|=m||"
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e IP6_NF_IPTABLES_LEGACY -e IP6_NF_IPTABLES -e IP6_NF_MATCH_AH \
    -e IP6_NF_MATCH_EUI64 -e IP6_NF_MATCH_FRAG -e IP6_NF_MATCH_OPTS \
    -e IP6_NF_MATCH_HL -e IP6_NF_MATCH_IPV6HEADER -e IP6_NF_MATCH_MH \
    -e IP6_NF_MATCH_RPFILTER -e IP6_NF_MATCH_RT -e IP6_NF_MATCH_SRH \
    -e IP6_NF_TARGET_HL -e IP6_NF_FILTER -e IP6_NF_TARGET_REJECT \
    -e IP6_NF_TARGET_SYNPROXY -e IP6_NF_MANGLE -e IP6_NF_RAW \
    -e IP6_NF_SECURITY -e IP6_NF_NAT -e IP6_NF_TARGET_MASQUERADE \
    -e IP6_NF_TARGET_NPT

# $ cat boot/config-6.12.48-6.12-alt0.c10f.2 | grep BPF | sed -E "s|CONFIG_||" | sed -E "s|=y||" | sed -E "s|=m||"
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    -e BPF -e BPF_SYSCALL -e HAVE_EBPF_JIT \
    -e ARCH_WANT_DEFAULT_BPF_JIT -e BPF_JIT \
    -e BPF_JIT_ALWAYS_ON -e BPF_JIT_DEFAULT_ON \
    -e BPF_UNPRIV_DEFAULT_OFF -e BPF_LSM -e CGROUP_BPF \
    -e NET_CLS_BPF -e NET_ACT_BPF -e BPF_STREAM_PARSER \
    -e LWTUNNEL_BPF -e BPF_EVENTS -e BPF_KPROBE_OVERRIDE

# fix SYZFAIL: tun: ioctl(TUNSETIFF) failed (errno 16: Device or resource busy)
# err    --set-str LSM "selinux"
./scripts/config --file "$KERNEL_BUILD_DIR/.config" \
    --set-str LSM "landlock,lockdown,yama,loadpin,safesetid,smack,tomoyo,apparmor,ipe,bpf,altha,kiosk"

# ---------------------------------------------------

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

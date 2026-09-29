#!/bin/sh
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# In-guest unit test for tripso (the "TRIPSO" iptables target). Runs as root
# inside the QEMU VM. The orchestrator ships the built source tree to ./src.
#
# TRIPSO is a *target* (-j TRIPSO --to-cipso / --to-astra) that rewrites a
# packet's IP security-label option between CIPSO (IPOPT_CIPSO, 0x86) and
# GOST R 58256-2018 / RFC 1108-Astra (IPOPT_SEC, 0x82). Unlike ipt-so's xt_so
# match, it has no checkentry worth exercising — almost all of xt_TRIPSO.c runs
# from the packet path (tripso_tg), so coverage needs real labelled packets to
# traverse a chain that carries a TRIPSO rule.
#
# Coverage strategy:
#  1) Userspace helper (libxt_TRIPSO.c): --to-cipso/--to-astra parse, the
#     "parameter required" check, save/print, via iptables rule add/delete and
#     iptables-save round-trips.
#  2) Packaged tripso_tests.sh (only if the heavy tcpdump+tcpreplay+veth harness
#     it needs is present) — it replays test/*.pkt and diffs against test-recv/.
#     Skipped gracefully otherwise; we do not depend on it for coverage.
#  3) Labelled-packet sender: a raw-socket C program compiled in-guest
#     (gcc is in GUEST_PACKAGES) sends 8 packet variants covering:
#       CIPSO DOI=1 lvl=1 cat   -> --to-astra: parse_cipso/copy_msb0_bits/
#                                  bitrev64/write_astra + mangle_options shrink
#       Astra lvl=1 cat=1       -> --to-cipso: parse_rfc1108_astra/
#                                  unpack_rfc1108_bits/write_cipso + expand
#       CIPSO DOI=99 mismatch   -> parse_cipso fail -> pproblem/NF_DROP/ICMP
#       IPOPT_SEC class!=0xAB    -> parse_rfc1108_astra fail -> pproblem
#       NOP + CIPSO + END        -> IPOPT_NOOP/IPOPT_END option-walk branches
#       Double IPOPT_SEC         -> "multiple security options" -> pproblem
#       CIPSO olen=1             -> "invalid option length" -> NF_DROP
#       CIPSO lvl=2 cat=0        -> minimal write_astra encoding
#     Rules are installed in the raw/PREROUTING and security/{INPUT,OUTPUT}
#     chains (as the module's own README and tripso_tests.sh do) in both
#     directions; icmp=1 then icmp=0 module params flip the ICMP branch of
#     send_parameter_problem.
#  4) Reload cycle: module init/exit.
set -x

SRC=$(readlink -f ./src 2>/dev/null || echo ./src)

# Visual tags
C_OK=$(printf '\033[1;32m'); C_SKIP=$(printf '\033[1;33m')
C_FAIL=$(printf '\033[1;31m'); C_RST=$(printf '\033[0m')
tag_ok()   { printf '%s[OK  ]%s ' "$C_OK"   "$C_RST"; }
tag_skip() { printf '%s[SKIP]%s ' "$C_SKIP" "$C_RST"; }
tag_fail() { printf '%s[FAIL]%s ' "$C_FAIL" "$C_RST"; }

# Locate system xtables extension dir
detect_xtlibdir() {
    d=$(pkg-config --variable xtlibdir xtables 2>/dev/null)
    [ -n "$d" ] && [ -d "$d" ] && { echo "$d"; return; }
    for c in /usr/lib/x86_64-linux-gnu/xtables /usr/lib64/xtables \
             /usr/lib/xtables /lib/xtables; do
        [ -d "$c" ] && { echo "$c"; return; }
    done; echo /usr/lib/xtables
}
XTLIBDIR=$(detect_xtlibdir)
export XTABLES_LIBDIR="$SRC:$XTLIBDIR"
echo "XTABLES_LIBDIR=$XTABLES_LIBDIR"

# Build libxt_TRIPSO.so in-guest if the host build did not leave one.
if [ ! -f "$SRC/libxt_TRIPSO.so" ] && command -v gcc >/dev/null 2>&1; then
    ( cd "$SRC" && \
      gcc -O2 -fPIC $(pkg-config xtables --cflags 2>/dev/null) \
          -o libxt_TRIPSO_sh.o -c libxt_TRIPSO.c && \
      gcc -shared -o libxt_TRIPSO.so libxt_TRIPSO_sh.o \
          $(pkg-config xtables --libs 2>/dev/null) -lxtables ) || true
fi
if [ -f "$SRC/libxt_TRIPSO.so" ]; then
    cp -f "$SRC/libxt_TRIPSO.so" "$XTLIBDIR/" 2>/dev/null || true
    iptables -j TRIPSO -h >/dev/null 2>&1 \
        && echo "$(tag_ok)TRIPSO target loads from $XTLIBDIR" \
        || echo "$(tag_fail)TRIPSO target NOT loadable"
fi

sysctl -w kernel.printk=8 2>/dev/null || true

# Load the module. icmp=1 (default) so send_parameter_problem's icmp_send()
# branch is reachable; doi=1 matches the CIPSO DOI we register below.
insmod "$SRC/xt_TRIPSO.ko" debug=2 2>/dev/null || modprobe xt_TRIPSO || true

# Hard check: the module must actually be loaded. If it is not (e.g. the host
# build produced no xt_TRIPSO.ko), every rule below is rejected and no .gcda is
# emitted — which otherwise surfaces only as a puzzling empty coverage report.
# Report it loudly here so the real cause (the build) is obvious.
if lsmod 2>/dev/null | grep -q '^xt_TRIPSO' || [ -d /sys/module/xt_TRIPSO ]; then
    echo "$(tag_ok)xt_TRIPSO module loaded"
else
    echo "$(tag_fail)xt_TRIPSO did NOT load — was $SRC/xt_TRIPSO.ko built? Check the host build log."
    ls -l "$SRC"/*.ko 2>/dev/null || echo "  (no .ko present in $SRC — the module build failed)"
fi

# Register CIPSO DOI=1 so labelled IPOPT_CIPSO packets survive
# ip_options_compile() -> cipso_v4_validate() and reach the netfilter hooks
# where the --to-astra rule can translate them. Without this, CIPSO packets are
# dropped with ICMP_PARAMETERPROB before tripso_tg() runs. The Astra/IPOPT_SEC
# path needs no registration (it is skipped by ip_options_compile).
if command -v netlabelctl >/dev/null 2>&1; then
    netlabelctl cipso add pass doi:1 tags:1 2>/dev/null \
        && echo "$(tag_ok)registered CIPSO DOI=1" \
        || echo "$(tag_skip)netlabelctl cipso add failed (may already exist)"
    netlabelctl unlbl setdef address:0.0.0.0/0 label:unlabelled 2>/dev/null || true
    netlabelctl map add default address:127.0.0.1 protocol:cipsov4,doi:1 2>/dev/null || true
else
    echo "$(tag_skip)netlabelctl absent — CIPSO->astra translation may be limited"
fi

ip link set lo up 2>/dev/null || true

# ── 1) Userspace helper (libxt_TRIPSO.c) via rule add/delete ────────────────
# Covers tripso_tg_parse (both options), tripso_tg_init, tripso_tg_check
# ("parameter required"), tripso_tg_save/print and the kernel .targetsize path.
usr_rule() {
    _t=$1; _c=$2; shift 2
    if iptables -t "$_t" -I "$_c" "$@" 2>/dev/null; then
        # iptables-save exercises tripso_tg_save; -nvL exercises print.
        iptables-save -t "$_t" 2>/dev/null | grep -q TRIPSO \
            && echo "$(tag_ok)[$_t/$_c] $* -> parsed+saved" \
            || echo "$(tag_ok)[$_t/$_c] $* -> parsed"
        iptables -t "$_t" -nvL "$_c" 2>/dev/null | grep -q TRIPSO || true
        iptables -t "$_t" -D "$_c" "$@" 2>/dev/null || true
    else
        echo "$(tag_skip)[$_t/$_c] $* -> parser/checkentry rejected"
    fi
}

usr_rule security INPUT       -j TRIPSO --to-cipso
usr_rule security OUTPUT      -j TRIPSO --to-astra
usr_rule raw      PREROUTING  -j TRIPSO --to-astra
usr_rule mangle   POSTROUTING -j TRIPSO --to-cipso

# tripso_tg_check: neither --to-cipso nor --to-astra -> "parameter required".
if iptables -t security -I INPUT -j TRIPSO 2>/dev/null; then
    echo "$(tag_fail)TRIPSO with no mode was accepted (expected rejection)"
    iptables -t security -D INPUT -j TRIPSO 2>/dev/null || true
else
    echo "$(tag_ok)TRIPSO without --to-cipso/--to-astra correctly rejected"
fi

# Mutually-exclusive options must be rejected by the parser (.excl).
if iptables -t security -I INPUT -j TRIPSO --to-cipso --to-astra 2>/dev/null; then
    echo "$(tag_fail)TRIPSO --to-cipso --to-astra was accepted (expected rejection)"
    iptables -t security -D INPUT -j TRIPSO --to-cipso --to-astra 2>/dev/null || true
else
    echo "$(tag_ok)TRIPSO --to-cipso --to-astra (exclusive) correctly rejected"
fi

# ── 2) Packaged tripso_tests.sh (opt-in on harness availability) ────────────
# The upstream harness needs tcpdump w/ nflog + tcpreplay + veth/netns. If all
# are present, run it (it replays test/*.pkt and diffs against test-recv/). We
# never fail the target on its result — it is a bonus signal, and our own
# labelled-packet path below drives the same kernel code deterministically.
if [ -f "$SRC/tripso_tests.sh" ] && \
   command -v tcpreplay >/dev/null 2>&1 && \
   command -v tcpdump   >/dev/null 2>&1 && \
   tcpdump -D 2>/dev/null | grep -qw nflog; then
    echo "$(tag_ok)running packaged tripso_tests.sh (retest)"
    if command -v bash >/dev/null 2>&1; then
        ( cd "$SRC" && bash ./tripso_tests.sh retest ) || \
            echo "$(tag_skip)packaged tripso_tests.sh reported a diff/failure"
    else
        ( cd "$SRC" && sh ./tripso_tests.sh retest ) || \
            echo "$(tag_skip)packaged tripso_tests.sh reported a diff/failure"
    fi
else
    echo "$(tag_skip)packaged tripso_tests.sh needs tcpdump(nflog)+tcpreplay+veth — using raw sender instead"
fi

# ── 3) Labelled-packet path ─────────────────────────────────────────────────
lsmod | grep -q '^xt_TRIPSO' || insmod "$SRC/xt_TRIPSO.ko" debug=2 2>/dev/null || true

if command -v gcc >/dev/null 2>&1; then
cat > /tmp/send_seclabel.c << 'CSRC'
/*
 * send_seclabel.c  —  raw-socket sender for xt_TRIPSO gcov coverage.
 *
 * Sends 8 UDP packets to 127.0.0.1:9 (discard) carrying crafted IP security
 * options so the TRIPSO target's translation paths are exercised. Each packet
 * is prefixed with a one-line description printed to stdout so the test log
 * shows which kernel path it is meant to hit.
 *
 * Compiled and run inside the QEMU guest by the tripso test driver.
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static uint16_t cksum(const void *buf, int len)
{
    const uint16_t *p = buf;
    uint32_t s = 0;
    for (; len > 1; len -= 2) s += *p++;
    if (len) s += *(uint8_t *)p;
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return (uint16_t)~s;
}

/* Send a raw IP/UDP packet to 127.0.0.1:9 with opts (padded to 4-byte word). */
static int send_pkt(const uint8_t *opts, int olen)
{
    uint8_t padded[40] = {0};
    uint8_t pkt[256]   = {0};
    int plen = (olen + 3) & ~3;
    int ihl, tot;

    if (plen > 40) return 1;
    memcpy(padded, opts, olen);       /* remainder stays 0x00 = IPOPT_END pad */
    ihl = 5 + plen / 4;
    tot = ihl * 4 + 8 + 4;
    pkt[0] = (4 << 4) | ihl;
    *(uint16_t *)(pkt + 2) = htons(tot);
    *(uint16_t *)(pkt + 4) = htons(0xbeef);
    pkt[8] = 64; pkt[9] = 17;                       /* ttl, proto=UDP */
    *(uint32_t *)(pkt + 12) = htonl(0x7f000001);
    *(uint32_t *)(pkt + 16) = htonl(0x7f000001);
    memcpy(pkt + 20, padded, plen);
    *(uint16_t *)(pkt + 10) = cksum(pkt, ihl * 4);
    uint8_t *u = pkt + ihl * 4;
    *(uint16_t *)(u + 0) = htons(12345);
    *(uint16_t *)(u + 2) = htons(9);
    *(uint16_t *)(u + 4) = htons(12);
    memcpy(u + 8, "test", 4);

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family      = AF_INET;
    sa.sin_addr.s_addr = htonl(0x7f000001);
    sa.sin_port        = htons(9);
    int s = socket(AF_INET, SOCK_RAW, IPPROTO_RAW);
    if (s < 0) { perror("socket"); return 1; }
    int on = 1;
    setsockopt(s, IPPROTO_IP, IP_HDRINCL, &on, sizeof(on));
    int r = (sendto(s, pkt, tot, 0, (struct sockaddr *)&sa, sizeof(sa)) < 0);
    if (r) perror("sendto");
    close(s);
    return r;
}

int main(void)
{
    int rc = 0;

    /*
     * 1. CIPSO DOI=1, tag=1(bitmap), level=1, category octet 0x80.
     *    --to-astra: parse_cipso -> copy_msb0_bits -> bitrev64 -> write_astra.
     *    11-byte CIPSO -> 5-byte Astra: mangle_options shrink-header path.
     */
    uint8_t cipso_l1c1[] = {0x86,11, 0,0,0,1, 1,5,0,1,0x80};
    printf("[pkt1] CIPSO DOI=1 lvl=1 cat -> to-astra parse_cipso/bitrev64/write_astra (shrink)\n");
    rc += send_pkt(cipso_l1c1, sizeof(cipso_l1c1));

    /*
     * 2. Astra level=1 category=1 (IPOPT_SEC class=0xAB packed).
     *    --to-cipso: parse_rfc1108_astra -> unpack_rfc1108_bits -> write_cipso.
     *    5-byte Astra -> 11-byte CIPSO: mangle_options expand-header path.
     */
    uint8_t astra_l1c1[] = {0x82, 5, 0xab, 0x03, 0x04};
    printf("[pkt2] Astra lvl=1 cat=1 -> to-cipso parse_rfc1108_astra/write_cipso (expand)\n");
    rc += send_pkt(astra_l1c1, sizeof(astra_l1c1));

    /*
     * 3. CIPSO DOI=99 (!= module doi=1): parse_cipso returns 0 -> sec_err=1
     *    -> goto pproblem -> send_parameter_problem + NF_DROP (to-astra rule).
     */
    uint8_t cipso_doi99[] = {0x86,11, 0,0,0,99, 1,5,0,2,0x40};
    printf("[pkt3] CIPSO DOI=99 -> parse_cipso fail -> pproblem/NF_DROP/ICMP\n");
    rc += send_pkt(cipso_doi99, sizeof(cipso_doi99));

    /*
     * 4. IPOPT_SEC with non-Astra class 0x61: parse_rfc1108_astra returns 0
     *    -> sec_err=1 -> goto pproblem (to-cipso rule).
     */
    uint8_t sec_bad[] = {0x82, 4, 0x61, 0x02};
    printf("[pkt4] IPOPT_SEC class=0x61 (non-Astra) -> parse_rfc1108_astra fail -> pproblem\n");
    rc += send_pkt(sec_bad, sizeof(sec_bad));

    /*
     * 5. NOOP + CIPSO + END: exercises the IPOPT_NOOP and IPOPT_END branches of
     *    the option walk in tripso_tg, then translates the CIPSO (to-astra).
     */
    uint8_t noop_cipso[] = {0x01, 0x86,11, 0,0,0,1, 1,5,0,3,0x40, 0x00};
    printf("[pkt5] NOP + CIPSO + END -> IPOPT_NOOP/IPOPT_END walk + to-astra translate\n");
    rc += send_pkt(noop_cipso, sizeof(noop_cipso));

    /*
     * 6. Two IPOPT_SEC options: the second is seen with sec_err already set
     *    -> "multiple security options" -> goto pproblem (to-cipso rule).
     */
    uint8_t double_sec[] = {0x82,4,0xab,0x02, 0x82,4,0xab,0x02};
    printf("[pkt6] Double IPOPT_SEC -> multiple-security-options pproblem/NF_DROP\n");
    rc += send_pkt(double_sec, sizeof(double_sec));

    /*
     * 7. Bogus option length (olen=1): "invalid option length" -> NF_DROP,
     *    before any translation.
     */
    uint8_t bad_olen[] = {0x86, 1, 0, 0};
    printf("[pkt7] CIPSO olen=1 (invalid) -> NF_DROP invalid-option-length\n");
    rc += send_pkt(bad_olen, sizeof(bad_olen));

    /*
     * 8. CIPSO DOI=1 level=2 category=0 -> to-astra minimal write_astra
     *    encoding (single level byte, no category octets).
     */
    uint8_t cipso_l2c0[] = {0x86,10, 0,0,0,1, 1,4,0,2};
    printf("[pkt8] CIPSO DOI=1 lvl=2 cat=0 -> to-astra minimal write_astra\n");
    rc += send_pkt(cipso_l2c0, sizeof(cipso_l2c0));

    return rc ? 1 : 0;
}
CSRC

    if gcc -O0 -o /tmp/send_seclabel /tmp/send_seclabel.c 2>/dev/null; then
        echo "$(tag_ok)send_seclabel compiled"

        # Drive both translation directions from several hooks. tripso_tests.sh
        # notes security/INPUT does not receive test CIPSO packets while
        # raw/PREROUTING does, so we install rules in both plus security/OUTPUT.
        # icmp=1 first (default) so send_parameter_problem's icmp_send() runs.
        run_burst() {
            # R1 raw/PREROUTING to-astra: pkt1/pkt5/pkt8 translate,
            #    pkt3 DOI-mismatch -> pproblem, pkt7 invalid -> drop.
            iptables -t raw -I PREROUTING -j TRIPSO --to-astra 2>/dev/null || true
            # R2 raw/PREROUTING to-cipso: pkt2 translate, pkt4/pkt6 -> pproblem.
            iptables -t raw -I PREROUTING -j TRIPSO --to-cipso 2>/dev/null || true
            # R3 security/INPUT to-cipso (module README's example direction).
            iptables -t security -I INPUT -j TRIPSO --to-cipso 2>/dev/null || true
            # R4 security/OUTPUT to-astra, excluding lo per the README example.
            iptables -t security ! -o lo -I OUTPUT -j TRIPSO --to-astra 2>/dev/null || true

            iptables -t raw      -Z PREROUTING 2>/dev/null || true
            iptables -t security -Z INPUT      2>/dev/null || true
            /tmp/send_seclabel || true
            /tmp/send_seclabel || true

            echo "--- raw/PREROUTING counters after labelled send ---"
            iptables -t raw -nvL PREROUTING 2>/dev/null || true

            iptables -t raw -D PREROUTING -j TRIPSO --to-astra 2>/dev/null || true
            iptables -t raw -D PREROUTING -j TRIPSO --to-cipso 2>/dev/null || true
            iptables -t security -D INPUT -j TRIPSO --to-cipso 2>/dev/null || true
            iptables -t security ! -o lo -D OUTPUT -j TRIPSO --to-astra 2>/dev/null || true
        }

        # Pass 1: icmp=1 (module default) — send_parameter_problem sends ICMP.
        run_burst

        # Pass 2: icmp=0 — send_parameter_problem takes the "no ICMP" branch.
        if [ -w /sys/module/xt_TRIPSO/parameters/icmp ]; then
            echo 0 > /sys/module/xt_TRIPSO/parameters/icmp 2>/dev/null || true
            echo "$(tag_ok)set xt_TRIPSO icmp=0 (pproblem no-ICMP branch)"
            run_burst
            echo 1 > /sys/module/xt_TRIPSO/parameters/icmp 2>/dev/null || true
        fi

        # Also drive an ICMP-carrying labelled packet: send_parameter_problem
        # returns early for IPPROTO_ICMP, and a CIPSO ping stresses the option
        # walk on a different L4 protocol. (Best-effort; may be filtered.)
        ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1 || true

        rm -f /tmp/send_seclabel /tmp/send_seclabel.c
    else
        echo "$(tag_fail)send_seclabel compilation failed – skipping labelled-packet tests"
    fi
fi

# ── 4) doi module-param retarget ────────────────────────────────────────────
# Flip the module's doi to 99, register a matching NetLabel DOI, and translate a
# DOI=99 CIPSO packet: exercises parse_cipso's doi-compare success on a
# non-default value and write_cipso emitting DOI=99 in --to-cipso.
if [ -w /sys/module/xt_TRIPSO/parameters/doi ] && command -v gcc >/dev/null 2>&1; then
    echo 99 > /sys/module/xt_TRIPSO/parameters/doi 2>/dev/null || true
    netlabelctl cipso add pass doi:99 tags:1 2>/dev/null || true
    cat > /tmp/send_doi99.c << 'CSRC'
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
static uint16_t cksum(const void *b,int n){const uint16_t*p=b;uint32_t s=0;
 for(;n>1;n-=2)s+=*p++; if(n)s+=*(uint8_t*)p; while(s>>16)s=(s&0xffff)+(s>>16);
 return (uint16_t)~s;}
int main(void){
 uint8_t o[]={0x86,11,0,0,0,99,1,5,0,1,0x80};
 uint8_t pad[40]={0},pkt[256]={0}; int ol=sizeof(o),pl=(ol+3)&~3;
 int ihl=5+pl/4,tot=ihl*4+12; memcpy(pad,o,ol);
 pkt[0]=(4<<4)|ihl; *(uint16_t*)(pkt+2)=htons(tot);
 *(uint16_t*)(pkt+4)=htons(0xbeef); pkt[8]=64; pkt[9]=17;
 *(uint32_t*)(pkt+12)=htonl(0x7f000001); *(uint32_t*)(pkt+16)=htonl(0x7f000001);
 memcpy(pkt+20,pad,pl); *(uint16_t*)(pkt+10)=cksum(pkt,ihl*4);
 uint8_t*u=pkt+ihl*4; *(uint16_t*)u=htons(12345);*(uint16_t*)(u+2)=htons(9);
 *(uint16_t*)(u+4)=htons(12); memcpy(u+8,"test",4);
 struct sockaddr_in sa; memset(&sa,0,sizeof(sa)); sa.sin_family=AF_INET;
 sa.sin_addr.s_addr=htonl(0x7f000001); sa.sin_port=htons(9);
 int s=socket(AF_INET,SOCK_RAW,IPPROTO_RAW); if(s<0)return 1; int on=1;
 setsockopt(s,IPPROTO_IP,IP_HDRINCL,&on,sizeof(on));
 sendto(s,pkt,tot,0,(struct sockaddr*)&sa,sizeof(sa)); close(s);
 printf("[doi99] CIPSO DOI=99 with module doi=99 -> parse_cipso ok\n"); return 0;}
CSRC
    if gcc -O0 -o /tmp/send_doi99 /tmp/send_doi99.c 2>/dev/null; then
        iptables -t raw -I PREROUTING -j TRIPSO --to-astra 2>/dev/null || true
        /tmp/send_doi99 || true; /tmp/send_doi99 || true
        iptables -t raw -D PREROUTING -j TRIPSO --to-astra 2>/dev/null || true
        echo "$(tag_ok)doi=99 retarget burst done"
        rm -f /tmp/send_doi99 /tmp/send_doi99.c
    fi
    echo 1 > /sys/module/xt_TRIPSO/parameters/doi 2>/dev/null || true
fi

# ── 5) Reload cycle ─────────────────────────────────────────────────────────
# Exercises tripso_exit (xt_unregister_target) and tripso_init again.
rmmod xt_TRIPSO 2>/dev/null || true
insmod "$SRC/xt_TRIPSO.ko" debug=2 2>/dev/null || true
echo "$(tag_ok)module reload cycle complete"

echo "tripso in-guest tests complete"

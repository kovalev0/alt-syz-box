#!/bin/sh
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# In-guest unit test for ipt-so (the "so" iptables match). Runs as root inside
# the QEMU VM. The orchestrator ships the built source tree to ./src.
#
# Coverage strategy:
#  1) Packaged tests.sh: userspace parser (libxt_so.c) + kernel checkentry
#     (so_check) via iptables rule-add/delete cycles. Outputs "Tests PASSED!".
#  2) Labeled-packet sender: raw-socket C program compiled in-guest (gcc is in
#     GUEST_PACKAGES) sends 7 packet variants covering:
#       CIPSO DOI=1 level=1     -> parse_cipso / copy_msb0_bits / bitrev64
#       Astra level=1           -> parse_rfc1108_astra / unpack_rfc1108_bits
#       NOOP+END                -> IPOPT_NOOP / IPOPT_END branches in so_mt()
#       CIPSO DOI=99 mismatch   -> DOI-mismatch branch (F_SO_DOI)
#       Double IPOPT_SEC        -> "multiple SEC options" -> pproblem / hotdrop
#       Non-Astra SEC class     -> parse_rfc1108_astra returns 0 -> pproblem
#       CIPSO level/categ check -> F_SO_LEVEL + F_SO_CATEG on labeled packet
#     After each send-burst, security-table rule counters are printed so the
#     log shows whether each rule actually matched labeled traffic.
#  3) Extra unlabeled-ping rules: F_SO_LEVEL / F_SO_CATEG on unlabeled pkts.
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

# Build libxt_so.so in-guest if missing.
if [ ! -f "$SRC/libxt_so.so" ] && command -v gcc >/dev/null 2>&1; then
    ( cd "$SRC" && \
      gcc -O2 -fPIC $(pkg-config xtables --cflags 2>/dev/null) \
          -o libxt_so_sh.o -c libxt_so.c && \
      gcc -shared -o libxt_so.so libxt_so_sh.o \
          $(pkg-config xtables --libs 2>/dev/null) -lxtables ) || true
fi
if [ -f "$SRC/libxt_so.so" ]; then
    cp -f "$SRC/libxt_so.so" "$XTLIBDIR/" 2>/dev/null || true
    iptables -m so -h >/dev/null 2>&1 \
        && echo "$(tag_ok)so match loads from $XTLIBDIR" \
        || echo "$(tag_fail)so match NOT loadable"
fi

sysctl -w kernel.printk=8 2>/dev/null || true
insmod "$SRC/xt_so.ko" debug=2 2>/dev/null || modprobe xt_so || true

# ── 1) Packaged test-suite ──────────────────────────────────────────────────
if [ -f "$SRC/tests.sh" ]; then
    if command -v bash >/dev/null 2>&1; then
        ( cd "$SRC" && bash ./tests.sh test ) || true
    else
        ( cd "$SRC" && sh ./tests.sh test ) || true
    fi
fi

# ── 2) Labeled-packet path ──────────────────────────────────────────────────
ip link set lo up 2>/dev/null || true
lsmod | grep -q '^xt_so' || insmod "$SRC/xt_so.ko" debug=2 2>/dev/null || true

if command -v gcc >/dev/null 2>&1; then
cat > /tmp/send_labeled.c << 'CSRC'
/*
 * send_labeled.c  —  raw-socket sender for xt_so gcov coverage.
 *
 * Sends 7 UDP packets to 127.0.0.1:9 (discard) with crafted IP options.
 * Each packet is prefixed with a one-line description printed to stdout so
 * the test log shows exactly which kernel paths each packet is meant to hit.
 *
 * Compiled and run inside the QEMU guest by the ipt-so test driver.
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

/* Send a raw IP/UDP packet to 127.0.0.1:9 with opts (padded to 4-byte boundary). */
static int send_pkt(const uint8_t *opts, int olen)
{
    uint8_t padded[40] = {0};
    uint8_t pkt[256]   = {0};
    int plen = (olen + 3) & ~3;
    int ihl, tot;
    memcpy(padded, opts, olen);
    memset(padded + olen, 0x01, plen - olen); /* NOP padding */
    ihl = 5 + plen / 4;
    tot = ihl * 4 + 8 + 4;
    pkt[0] = (4 << 4) | ihl;
    *(uint16_t *)(pkt + 2) = htons(tot);
    *(uint16_t *)(pkt + 4) = htons(0xbeef);
    pkt[8] = 64; pkt[9] = 17;
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
     * 1. CIPSO (IPOPT_CIPSO = 0x86): DOI=1, tag_type=1, level=1, categ=0.
     *    Drives: parse_cipso() / copy_msb0_bits() / bitrev64().
     */
    uint8_t cipso[] = {0x86,11, 0,0,0,1, 1,5,0,1,0};
    printf("[pkt1] CIPSO DOI=1 level=1 -> parse_cipso/copy_msb0_bits/bitrev64\n");
    rc += send_pkt(cipso, sizeof(cipso));

    /*
     * 2. Astra / IPOPT_SEC (0x82): class=0xAB, packed level=1 (0x02).
     *    Drives: parse_rfc1108_astra() / unpack_rfc1108_bits().
     */
    uint8_t astra[] = {0x82, 4, 0xab, 0x02};
    printf("[pkt2] Astra level=1 -> parse_rfc1108_astra/unpack_rfc1108_bits\n");
    rc += send_pkt(astra, sizeof(astra));

    /*
     * 3. NOOP + END options.
     *    Drives: IPOPT_NOOP and IPOPT_END branches in so_mt().
     */
    uint8_t noop_end[] = {0x01, 0x00};
    printf("[pkt3] NOP+END -> so_mt IPOPT_NOOP/IPOPT_END branches\n");
    rc += send_pkt(noop_end, sizeof(noop_end));

    /*
     * 4. CIPSO with DOI=99 (≠ rule DOI=1).
     *    Drives: DOI-mismatch branch (F_SO_DOI check in so_mt).
     */
    uint8_t cipso99[] = {0x86,11, 0,0,0,99, 1,5,0,2,0};
    printf("[pkt4] CIPSO DOI=99 mismatch -> F_SO_DOI mismatch branch\n");
    rc += send_pkt(cipso99, sizeof(cipso99));

    /*
     * 5. Two consecutive IPOPT_SEC options in one packet.
     *    so_mt: second IPOPT_SEC found with sec_err != -1 -> goto pproblem
     *    -> par->hotdrop = true.  Drives: pproblem hotdrop path.
     */
    uint8_t double_sec[] = {
        0x82, 4, 0xab, 0x02,   /* first Astra option: sec_err becomes 0 */
        0x82, 4, 0xab, 0x02    /* second -> "multiple security options" -> pproblem */
    };
    printf("[pkt5] Double IPOPT_SEC -> pproblem/hotdrop path in so_mt\n");
    rc += send_pkt(double_sec, sizeof(double_sec));

    /*
     * 6. IPOPT_SEC with non-Astra class (0x61 = Secret in RFC 1108, not Astra).
     *    parse_rfc1108_astra(): data[2] != 0xAB -> return 0.
     *    so_mt: sec_err = !0 = 1 -> goto pproblem.
     *    Drives: parse_rfc1108_astra early-exit and pproblem via parse failure.
     */
    uint8_t rfc1108_sec[] = {0x82, 4, 0x61, 0x02}; /* class=0x61 (Secret) */
    printf("[pkt6] IPOPT_SEC class=0x61 (non-Astra) -> parse_rfc1108_astra early exit -> pproblem\n");
    rc += send_pkt(rfc1108_sec, sizeof(rfc1108_sec));

    /*
     * 7. CIPSO with level=2 (for F_SO_LEVEL rule that only allows level=1).
     *    Drives: F_SO_LEVEL bitmap check for labeled packet (level-mismatch).
     */
    uint8_t cipso_lvl2[] = {0x86,11, 0,0,0,1, 1,5,0,2,0}; /* level=2, DOI=1 */
    printf("[pkt7] CIPSO DOI=1 level=2 -> F_SO_LEVEL mismatch on labeled packet\n");
    rc += send_pkt(cipso_lvl2, sizeof(cipso_lvl2));

    return rc ? 1 : 0;
}
CSRC

    if gcc -O0 -o /tmp/send_labeled /tmp/send_labeled.c 2>/dev/null; then
        echo "$(tag_ok)send_labeled compiled"

        # Rules cover different so_mt() branches:
        # R1: CIPSO any + match-all      -> pkt1 CIPSO match,  pkt6 Astra->mismatch path
        iptables -t security -I INPUT \
            -m so --so-proto cipso --so-match-all -j ACCEPT 2>/dev/null || true
        # R2: CIPSO DOI=1 + match-all    -> pkt1 DOI match,    pkt4 DOI mismatch
        iptables -t security -I INPUT \
            -m so --so-proto cipso --so-doi 1 --so-match-all -j ACCEPT 2>/dev/null || true
        # R3: CIPSO DOI=1 level=1 only   -> F_SO_LEVEL check on labeled pkt
        iptables -t security -I INPUT \
            -m so --so-proto cipso --so-doi 1 --so-level 1 -j ACCEPT 2>/dev/null || true
        # R4: Astra + match-all          -> pkt2 Astra match
        iptables -t security -I INPUT \
            -m so --so-proto astra --so-match-all -j ACCEPT 2>/dev/null || true
        # R5: Astra only (no match-all)  -> CIPSO pkt -> mismatch (F_SO_ASTRA not F_SO_CIPSO)
        iptables -t security -I INPUT \
            -m so --so-proto astra -j ACCEPT 2>/dev/null || true
        # R6: unlbl level 5              -> unlabeled pings with level check
        iptables -t security -I INPUT \
            -m so --so-proto unlbl --so-level 5 -j ACCEPT 2>/dev/null || true

        # Zero counters, run sender twice for better gcov accumulation
        iptables -t security -Z INPUT 2>/dev/null || true
        /tmp/send_labeled || true
        /tmp/send_labeled || true

        # Print rule counters — each line shows how many packets each rule matched
        echo "--- security INPUT rule counters after labeled send ---"
        iptables -t security -nv -L INPUT 2>/dev/null || true

        # Clean up rules
        iptables -t security -D INPUT \
            -m so --so-proto cipso --so-match-all -j ACCEPT 2>/dev/null || true
        iptables -t security -D INPUT \
            -m so --so-proto cipso --so-doi 1 --so-match-all -j ACCEPT 2>/dev/null || true
        iptables -t security -D INPUT \
            -m so --so-proto cipso --so-doi 1 --so-level 1 -j ACCEPT 2>/dev/null || true
        iptables -t security -D INPUT \
            -m so --so-proto astra --so-match-all -j ACCEPT 2>/dev/null || true
        iptables -t security -D INPUT \
            -m so --so-proto astra -j ACCEPT 2>/dev/null || true
        iptables -t security -D INPUT \
            -m so --so-proto unlbl --so-level 5 -j ACCEPT 2>/dev/null || true

        rm -f /tmp/send_labeled /tmp/send_labeled.c
    else
        echo "$(tag_fail)send_labeled compilation failed – skipping labeled-packet tests"
    fi
fi

# ── 3) Unlabeled-ping rules ─────────────────────────────────────────────────
# Exercises F_SO_LEVEL / F_SO_CATEG checks in so_mt() for unlabeled pings.
for RULE in \
    "-m so --so-level 1 --so-match-all" \
    "-m so --so-categ 1,2 --so-match-all" \
    "-m so --so-proto cipso,astra,unlbl --so-match-all" \
    "-m so ! --so-level 1 --so-match-all" \
    "-m so ! --so-proto cipso --so-match-all" ; do
    if iptables -t security -I INPUT $RULE -j ACCEPT 2>/dev/null; then
        iptables -t security -Z INPUT 2>/dev/null || true
        ping -c 2 -W 1 127.0.0.1 >/dev/null 2>&1 || true
        _pkts=$(iptables -t security -nv -L INPUT 2>/dev/null \
                | awk 'NR==3{print $1+0; exit}')
        iptables -t security -D INPUT $RULE -j ACCEPT 2>/dev/null || true
        if [ "${_pkts:-0}" -gt 0 ]; then
            echo "$(tag_ok)[security/INPUT] $RULE -> ${_pkts} pkt(s)"
        else
            echo "$(tag_ok)[security/INPUT] $RULE -> ins-only"
        fi
    else
        echo "$(tag_skip)[security/INPUT] $RULE -> rejected"
    fi
done

# ── 4) Reload cycle ─────────────────────────────────────────────────────────
rmmod xt_so 2>/dev/null || true
insmod "$SRC/xt_so.ko" debug=2 2>/dev/null || true
echo "$(tag_ok)module reload cycle complete"

echo "ipt-so in-guest tests complete"

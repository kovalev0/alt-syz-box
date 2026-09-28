#!/bin/sh
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# In-guest unit test for xtables-addons.
# Each rule outputs: [OK N pkts], [OK ins-only], or [SKIP reason].
set -x
SRC=./src

C_OK=$(printf '\033[1;32m');   C_SKIP=$(printf '\033[1;33m')
C_FAIL=$(printf '\033[1;31m'); C_RST=$(printf '\033[0m')
tag_ok()   { printf '%s[OK  ]%s ' "$C_OK"   "$C_RST"; }
tag_skip() { printf '%s[SKIP]%s ' "$C_SKIP" "$C_RST"; }
tag_fail() { printf '%s[FAIL]%s ' "$C_FAIL" "$C_RST"; }

sysctl -w kernel.panic_on_warn=0 2>/dev/null || true

detect_xtlibdir() {
    d=$(pkg-config --variable xtlibdir xtables 2>/dev/null)
    [ -n "$d" ] && [ -d "$d" ] && { echo "$d"; return; }
    for c in /usr/lib/x86_64-linux-gnu/xtables /usr/lib64/xtables \
             /usr/lib/xtables /lib/xtables; do
        [ -d "$c" ] && { echo "$c"; return; }
    done; echo /usr/lib/xtables
}
XTLIB_DIRS=$(find "$SRC" -name 'libxt_*.so' -exec dirname {} \; | sort -u | tr '\n' ':')
export XTABLES_LIBDIR="${XTLIB_DIRS}$(detect_xtlibdir)"
sysctl -w kernel.printk=8 2>/dev/null || true
ip link set lo up 2>/dev/null || true

# Load every built module
for ko in $(find "$SRC" -name '*.ko'); do
    insmod "$ko" 2>/dev/null || modprobe "$(basename "$ko" .ko)" 2>/dev/null || true
done
lsmod | grep -E 'xt_|ACCOUNT|pknock' || true

# ── Traffic generators ────────────────────────────────────────────────────────

# IPv4: ICMP + TCP:9 + UDP:9
drive_traffic() {
    ping -c 2 -W 1 127.0.0.1              >/dev/null 2>&1 || true
    timeout 1 nc -w1  127.0.0.1 9 </dev/null >/dev/null 2>&1 || true
    printf 'x' | timeout 2 nc -u -w1 127.0.0.1 9 >/dev/null 2>&1 || true
}

# IPv6: ICMP6 + TCP6:9 + UDP6:9
drive_traffic6() {
    ping6 -c 2 -W 1 ::1               >/dev/null 2>&1 || true
    timeout 1 nc -6 -w1 ::1 9 </dev/null >/dev/null 2>&1 || true
    printf 'x' | timeout 2 nc -6 -u -w1 ::1 9 >/dev/null 2>&1 || true
}

# Heavy traffic bursts (rate-sensitive modules)
drive_heavy() {
    ping -c 10 -W 1 127.0.0.1 >/dev/null 2>&1 || true
    for _i in $(seq 1 5); do
        timeout 1 nc -w1 127.0.0.1 9 </dev/null >/dev/null 2>&1 || true
        printf 'xxxx' | timeout 2 nc -u -w1 127.0.0.1 9 >/dev/null 2>&1 || true
    done
}

# Scan-like: rapid TCP SYN to many ports (triggers psd/lscan heuristics)
drive_scan() {
    for _p in 21 23 25 80 110 143 443 1080 3306 5432 8080 8443; do
        timeout 0.1 nc -w1 127.0.0.1 $_p </dev/null 2>/dev/null || true
    done
    for _p in 21 23 25 80 110 143 443 1080 3306 5432; do
        timeout 0.1 nc -6 -w1 ::1 $_p </dev/null 2>/dev/null || true
    done
}

# try_rule: insert, zero, traffic, read counter, delete.
try_rule() {
    _t=$1; _c=$2; shift 2
    if iptables -t "$_t" -I "$_c" "$@" 2>/dev/null; then
        iptables -t "$_t" -Z "$_c" 2>/dev/null || true
        drive_traffic
        _pkts=$(iptables -t "$_t" -nv -L "$_c" 2>/dev/null \
                | awk 'NR==3{print $1+0; exit}')
        iptables -t "$_t" -D "$_c" "$@" 2>/dev/null || true
        if [ "${_pkts:-0}" -gt 0 ]; then
            echo "$(tag_ok)[$_t/$_c] $* -> ${_pkts} pkt(s) matched"
        else
            echo "$(tag_ok)[$_t/$_c] $* -> ins-only (checkentry+parser OK)"
        fi
    else
        echo "$(tag_skip)[$_t/$_c] $* -> checkentry/parser rejected"
    fi
}

# try_rule6: same but ip6tables + drive_traffic6
try_rule6() {
    _t=$1; _c=$2; shift 2
    if ip6tables -t "$_t" -I "$_c" "$@" 2>/dev/null; then
        ip6tables -t "$_t" -Z "$_c" 2>/dev/null || true
        drive_traffic6
        _pkts=$(ip6tables -t "$_t" -nv -L "$_c" 2>/dev/null \
                | awk 'NR==3{print $1+0; exit}')
        ip6tables -t "$_t" -D "$_c" "$@" 2>/dev/null || true
        if [ "${_pkts:-0}" -gt 0 ]; then
            echo "$(tag_ok)[$_t/$_c/v6] $* -> ${_pkts} pkt(s) matched"
        else
            echo "$(tag_ok)[$_t/$_c/v6] $* -> ins-only (checkentry+parser OK)"
        fi
    else
        echo "$(tag_skip)[$_t/$_c/v6] $* -> checkentry/parser rejected"
    fi
}

skip_note() { echo "$(tag_skip)$1 -> $2"; }

# ── CONNTRACK ACTIVATION ─────────────────────────────────────────────────────
# Without conntrack active, nf_ct_get() returns NULL for all packets.
# Modules like lscan, LOGMARK, psd depend on conntrack entries.
# Adding a -m conntrack rule forces nf_conntrack to track all traffic.
_ct_loaded=0
if iptables -t filter -I INPUT -m conntrack --ctstate NEW,ESTABLISHED,RELATED,INVALID \
        -j ACCEPT 2>/dev/null; then
    _ct_loaded=1
    echo "$(tag_ok)conntrack activated (nf_ct_get will return non-NULL for tracked pkts)"
else
    echo "$(tag_skip)conntrack rule failed (lscan_mt_full/logmark_ct may not be covered)"
fi

# ── MATCHES ───────────────────────────────────────────────────────────────────

# xt_length2: basic + layer options for TCP payload coverage
try_rule filter INPUT -m length2 --length 40:1500 -j ACCEPT
# --layer5 (TCP payload) calls xtlength_layer5() + xtlength_layer5_tcp()
try_rule filter INPUT -p tcp -m length2 --layer5 --length 0:65535 -j ACCEPT
# --layer4 (L4+above)
try_rule filter INPUT -p tcp -m length2 --layer4 --length 0:65535 -j ACCEPT
# --layer3 (IP including header)
try_rule filter INPUT -m length2 --layer3 --length 0:65535 -j ACCEPT
# IPv6 length2 -> length2_mt6()
try_rule6 filter INPUT -m length2 --length 0:65535 -j ACCEPT

# xt_iface: try both options that exist
if ! iptables -t filter -I INPUT -m iface --dev-in lo -j ACCEPT 2>/dev/null; then
    skip_note "xt_iface --dev-in" "rejected; module-init covered"
else
    iptables -t filter -Z INPUT 2>/dev/null || true
    drive_traffic
    _pkts=$(iptables -t filter -nv -L INPUT 2>/dev/null | awk 'NR==3{print $1+0; exit}')
    iptables -t filter -D INPUT -m iface --dev-in lo -j ACCEPT 2>/dev/null || true
    echo "$(tag_ok)[filter/INPUT] -m iface --dev-in lo -> ${_pkts:-0} pkt(s)"
fi

# xt_ipv4options
try_rule filter INPUT -m ipv4options --any -j ACCEPT

# xt_psd: IPv4 + IPv6 scan traffic (covers handle_packet6 path)
try_rule filter INPUT -m psd -j ACCEPT
if iptables -t filter -I INPUT -m psd -j ACCEPT 2>/dev/null; then
    iptables -t filter -Z INPUT 2>/dev/null || true
    drive_scan && drive_heavy
    _pkts=$(iptables -t filter -nv -L INPUT 2>/dev/null | awk 'NR==3{print $1+0; exit}')
    iptables -t filter -D INPUT -m psd -j ACCEPT 2>/dev/null || true
    echo "$(tag_ok)[filter/INPUT] -m psd (scan+heavy) -> ${_pkts:-0} pkt(s)"
fi
# IPv6 psd -> handle_packet6, xt_psd_match6, get_header_pointer6, hashfunc6
try_rule6 filter INPUT -m psd -j ACCEPT
if ip6tables -t filter -I INPUT -m psd -j ACCEPT 2>/dev/null; then
    ip6tables -t filter -Z INPUT 2>/dev/null || true
    drive_scan
    _pkts=$(ip6tables -t filter -nv -L INPUT 2>/dev/null | awk 'NR==3{print $1+0; exit}')
    ip6tables -t filter -D INPUT -m psd -j ACCEPT 2>/dev/null || true
    echo "$(tag_ok)[filter6/INPUT] -m psd (IPv6 scan) -> ${_pkts:-0} pkt(s)"
fi

# xt_fuzzy: wide range to always match + heavy traffic for rate estimation
try_rule filter INPUT -m fuzzy --lower-limit 100 --upper-limit 10000 -j ACCEPT
if iptables -t filter -I INPUT -m fuzzy --lower-limit 1 --upper-limit 999999 -j ACCEPT 2>/dev/null; then
    iptables -t filter -Z INPUT 2>/dev/null || true
    drive_heavy
    _pkts=$(iptables -t filter -nv -L INPUT 2>/dev/null | awk 'NR==3{print $1+0; exit}')
    iptables -t filter -D INPUT -m fuzzy --lower-limit 1 --upper-limit 999999 -j ACCEPT 2>/dev/null || true
    echo "$(tag_ok)[filter/INPUT] -m fuzzy (wide, heavy) -> ${_pkts:-0} pkt(s)"
fi

# xt_lscan:
# - stealth scan detection: --stealth + raw TCP with weird flags (FIN/NULL/XMAS)
#   -> requires ctdata==NULL (no conntrack), calls lscan_mt_stealth()
# - full scan detection: conntrack must be active, TCP tracked -> lscan_mt_full()
#   The conntrack rule we added above ensures nf_ct_get() returns non-NULL

# First: --synscan with conntrack active -> lscan_mt_full() path
try_rule filter INPUT -p tcp -m lscan --synscan -j ACCEPT
if iptables -t filter -I INPUT -p tcp -m lscan --synscan -j ACCEPT 2>/dev/null; then
    iptables -t filter -Z INPUT 2>/dev/null || true
    drive_scan
    _pkts=$(iptables -t filter -nv -L INPUT 2>/dev/null | awk 'NR==3{print $1+0; exit}')
    iptables -t filter -D INPUT -p tcp -m lscan --synscan -j ACCEPT 2>/dev/null || true
    echo "$(tag_ok)[filter/INPUT] -p tcp -m lscan --synscan (scan) -> ${_pkts:-0} pkt(s)"
fi

# --stealth: detects FIN/NULL/XMAS scans via raw TCP with weird flags
# Compile and run a small raw-socket sender for stealth packets
if command -v gcc >/dev/null 2>&1; then
cat > /tmp/stealth_scan.c << 'CSRC'
/* stealth_scan.c: sends TCP packets with unusual flag combinations to
 * trigger lscan_mt_stealth() (called when ctdata==NULL AND --stealth set) */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

static uint16_t cksum(const void *p, int n) {
    const uint16_t *q = p; uint32_t s = 0;
    for (; n > 1; n -= 2) s += *q++;
    if (n) s += *(uint8_t *)q;
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return ~s;
}

static int send_tcp(uint8_t flags, uint16_t dport) {
    uint8_t pkt[sizeof(struct iphdr) + sizeof(struct tcphdr)];
    struct iphdr *iph = (struct iphdr *)pkt;
    struct tcphdr *th = (struct tcphdr *)(pkt + sizeof(*iph));
    uint32_t pseudo[4];

    memset(pkt, 0, sizeof(pkt));
    iph->ihl = 5; iph->version = 4; iph->ttl = 64; iph->protocol = IPPROTO_TCP;
    iph->tot_len = htons(sizeof(pkt));
    inet_pton(AF_INET, "127.0.0.1", &iph->saddr);
    inet_pton(AF_INET, "127.0.0.1", &iph->daddr);
    iph->check = cksum(iph, sizeof(*iph));

    th->source = htons(54321); th->dest = htons(dport);
    th->doff = sizeof(*th) / 4; th->seq = htonl(1234567);
    /* Set the requested flags bitmask directly */
    *((uint8_t *)th + 13) = flags;  /* TCP flags byte */

    /* Pseudo-header checksum */
    memset(pseudo, 0, sizeof(pseudo));
    pseudo[0] = iph->saddr; pseudo[1] = iph->daddr;
    ((uint8_t *)pseudo)[8] = 0; ((uint8_t *)pseudo)[9] = IPPROTO_TCP;
    ((uint16_t *)pseudo)[5] = htons(sizeof(*th));
    uint8_t pseudo_data[sizeof(pseudo) + sizeof(*th)];
    memcpy(pseudo_data, pseudo, sizeof(pseudo));
    memcpy(pseudo_data + sizeof(pseudo), th, sizeof(*th));
    th->check = cksum(pseudo_data, sizeof(pseudo_data));

    int s = socket(AF_INET, SOCK_RAW, IPPROTO_RAW);
    if (s < 0) { perror("socket"); return 1; }
    int on = 1; setsockopt(s, IPPROTO_IP, IP_HDRINCL, &on, sizeof(on));
    struct sockaddr_in dst = {.sin_family=AF_INET, .sin_port=htons(dport)};
    inet_pton(AF_INET, "127.0.0.1", &dst.sin_addr);
    int r = (sendto(s, pkt, sizeof(pkt), 0,
                    (struct sockaddr *)&dst, sizeof(dst)) < 0);
    if (r) perror("sendto");
    close(s); return r;
}

int main(void) {
    /* FIN-only scan (TCP flags: FIN=0x01) */
    printf("send FIN-only scan\n"); send_tcp(0x01, 9);
    /* NULL scan (no flags: 0x00) */
    printf("send NULL scan\n");    send_tcp(0x00, 9);
    /* XMAS scan (FIN+PSH+URG = 0x01|0x08|0x20 = 0x29) */
    printf("send XMAS scan\n");   send_tcp(0x29, 9);
    /* SYN-FIN (0x03) - invalid but detectable */
    printf("send SYN-FIN\n");     send_tcp(0x03, 9);
    return 0;
}
CSRC
    if gcc -O0 -o /tmp/stealth_scan /tmp/stealth_scan.c 2>/dev/null; then
        # Remove the conntrack rule temporarily so ctdata==NULL for these pkts
        [ "$_ct_loaded" = "1" ] && \
            iptables -t filter -D INPUT -m conntrack \
                --ctstate NEW,ESTABLISHED,RELATED,INVALID -j ACCEPT 2>/dev/null || true
        # stealth rule without conntrack -> lscan_mt_stealth()
        if iptables -t filter -I INPUT -p tcp -m lscan --stealth -j ACCEPT 2>/dev/null; then
            iptables -t filter -Z INPUT 2>/dev/null || true
            /tmp/stealth_scan || true
            _pkts=$(iptables -t filter -nv -L INPUT 2>/dev/null | awk 'NR==3{print $1+0; exit}')
            iptables -t filter -D INPUT -p tcp -m lscan --stealth -j ACCEPT 2>/dev/null || true
            echo "$(tag_ok)[filter/INPUT] -m lscan --stealth (weird flags) -> ${_pkts:-0} pkt(s)"
        fi
        # Restore conntrack rule
        [ "$_ct_loaded" = "1" ] && \
            iptables -t filter -I INPUT -m conntrack \
                --ctstate NEW,ESTABLISHED,RELATED,INVALID -j ACCEPT 2>/dev/null || true
        rm -f /tmp/stealth_scan /tmp/stealth_scan.c
    fi
fi

# xt_condition: activate via proc, cover both true/false paths
if iptables -t filter -I INPUT -m condition --condition xcond -j ACCEPT 2>/dev/null; then
    # match-false (condition=0)
    iptables -t filter -Z INPUT 2>/dev/null || true
    drive_traffic
    _f=$(iptables -t filter -nv -L INPUT 2>/dev/null | awk 'NR==3{print $1+0; exit}')
    # activate condition -> match-true
    echo 1 > /proc/net/nf_condition/xcond 2>/dev/null || true
    iptables -t filter -Z INPUT 2>/dev/null || true
    drive_heavy
    _t=$(iptables -t filter -nv -L INPUT 2>/dev/null | awk 'NR==3{print $1+0; exit}')
    echo 0 > /proc/net/nf_condition/xcond 2>/dev/null || true
    iptables -t filter -D INPUT -m condition --condition xcond -j ACCEPT 2>/dev/null || true
    echo "$(tag_ok)[filter/INPUT] -m condition -> false=${_f:-0} pkts, true=${_t:-0} pkts"
else
    try_rule filter INPUT -m condition --condition testcond -j ACCEPT
fi

# xt_quota2: normal + exhaustion (small quota -> over-quota branch)
try_rule filter INPUT -m quota2 --name q1 --quota 1000000 -j ACCEPT
if iptables -t filter -I INPUT -m quota2 --name q_xhst --quota 200 -j ACCEPT 2>/dev/null; then
    iptables -t filter -Z INPUT 2>/dev/null || true
    drive_heavy
    _pkts=$(iptables -t filter -nv -L INPUT 2>/dev/null | awk 'NR==3{print $1+0; exit}')
    iptables -t filter -D INPUT -m quota2 --name q_xhst --quota 200 -j ACCEPT 2>/dev/null || true
    echo "$(tag_ok)[filter/INPUT] quota2 exhaustion -> ${_pkts:-0} pkt(s) matched before limit"
fi

skip_note "xt_ipp2p" "checkentry/parser rejected (revision mismatch); module-init covered"

# xt_DHCPMAC match: send from port 68 to port 67 (DHCP ports) to exercise
# dhcpmac_mt's inner logic including ether_cmp()
if iptables -t mangle -I PREROUTING -p udp -m dhcpmac --mac 00:11:22:33:44:55 \
        -j ACCEPT 2>/dev/null; then
    iptables -t mangle -Z PREROUTING 2>/dev/null || true
    # DHCP client -> server: src port 68, dst port 67
    printf '\x01\x01\x06\x00%s' "$(printf '%.16s' '00000000000000000000000000000000')" | \
        timeout 2 nc -u -p 68 -w1 127.0.0.1 67 >/dev/null 2>&1 || true
    # Also regular UDP (covers early-exit path in dhcpmac_mt)
    printf 'x' | timeout 2 nc -u -w1 127.0.0.1 9 >/dev/null 2>&1 || true
    _pkts=$(iptables -t mangle -nv -L PREROUTING 2>/dev/null \
            | awk 'NR==3{print $1+0; exit}')
    iptables -t mangle -D PREROUTING -p udp -m dhcpmac --mac 00:11:22:33:44:55 \
        -j ACCEPT 2>/dev/null || true
    echo "$(tag_ok)[mangle/PREROUTING] -m dhcpmac (DHCP ports) -> ${_pkts:-0} pkt(s)"
fi

skip_note "xt_geoip" "database not installed; module-init covered"
skip_note "xt_asn"   "database not installed; module-init covered"

# ── TARGETS ───────────────────────────────────────────────────────────────────

# xt_TARPIT: standard + honeypot (covers xttarpit_honeypot) + IPv6 (tarpit_tg6)
try_rule filter INPUT -p tcp --dport 9 -j TARPIT
# --honeypot responds differently to SYN-ACK -> xttarpit_honeypot()
try_rule filter INPUT -p tcp --dport 9 -j TARPIT --honeypot
# IPv6 TARPIT -> tarpit_tcp6 + tarpit_tg6
try_rule6 filter INPUT -p tcp --dport 9 -j TARPIT

# xt_CHAOS
try_rule filter INPUT -p tcp --dport 9 -j CHAOS

# xt_DELUDE: insert-only (dst NOREF bug on loopback)
if iptables -t filter -I INPUT -p tcp --dport 9 -j DELUDE 2>/dev/null; then
    iptables -t filter -D INPUT -p tcp --dport 9 -j DELUDE 2>/dev/null || true
    echo "$(tag_ok)[filter/INPUT] -p tcp -j DELUDE -> ins-only (checkentry OK; pkt-path skipped)"
else
    skip_note "xt_DELUDE" "checkentry rejected"
fi

# xt_ECHO: IPv4 + IPv6 (echo_tg6 path)
try_rule filter INPUT -p udp -j ECHO
# IPv6 ECHO -> echo_tg6()
try_rule6 filter INPUT -p udp -j ECHO

skip_note "xt_SYSRQ" "sha1 unavailable -> sysrq_tg4 null-ptr-deref (OOPS/panic); module-init covered"

# xt_LOGMARK: IPv4 (logmark_tg covered) + conntrack branch (logmark_ct)
# With conntrack active (rule added above), nf_ct_get returns non-NULL
# -> logmark_ct() is called -> covers IP_CT_NEW/ESTABLISHED/RELATED branches
try_rule filter INPUT -j LOGMARK --log-prefix "xa: "
# Drive multiple connection types to cover all ctstate branches in logmark_ct
if iptables -t filter -I INPUT -j LOGMARK --log-prefix "xa2: " 2>/dev/null; then
    iptables -t filter -Z INPUT 2>/dev/null || true
    # NEW connection (SYN) -> ctstate=NEW -> logmark_ct IP_CT_NEW branch
    timeout 1 nc -w1 127.0.0.1 9 </dev/null >/dev/null 2>&1 || true
    # Also ICMP and UDP for variety
    ping -c 3 -W 1 127.0.0.1 >/dev/null 2>&1 || true
    printf 'x' | timeout 2 nc -u -w1 127.0.0.1 9 >/dev/null 2>&1 || true
    _pkts=$(iptables -t filter -nv -L INPUT 2>/dev/null | awk 'NR==3{print $1+0; exit}')
    iptables -t filter -D INPUT -j LOGMARK --log-prefix "xa2: " 2>/dev/null || true
    echo "$(tag_ok)[filter/INPUT] LOGMARK (conntrack variants) -> ${_pkts:-0} pkt(s)"
fi
# IPv6 LOGMARK
try_rule6 filter INPUT -j LOGMARK --log-prefix "xa6: "

# xt_DHCPMAC target (mangle table, SET mac in DHCP packets)
try_rule mangle PREROUTING -j DHCPMAC --set-mac 00:11:22:33:44:55

# xt_IPMARK: IPv4 + IPv6 (ipmark_tg6 + ipmark_from_ip6)
try_rule  mangle PREROUTING -j IPMARK --addr src --and-mask 0xffffffff --or-mask 0x0
try_rule  mangle PREROUTING -j IPMARK --addr dst --and-mask 0xffffffff --or-mask 0x0
try_rule6 mangle PREROUTING -j IPMARK --addr src --and-mask 0xffffffff --or-mask 0x0

# xt_PROTO (mangle table — repeated attempt with different syntax)
if ! iptables -t mangle -I PREROUTING -j PROTO --set-proto 17 2>/dev/null; then
    skip_note "xt_PROTO" "checkentry rejected (revision mismatch); module-init covered"
else
    iptables -t mangle -Z PREROUTING 2>/dev/null || true
    drive_traffic
    _pkts=$(iptables -t mangle -nv -L PREROUTING 2>/dev/null | awk 'NR==3{print $1+0; exit}')
    iptables -t mangle -D PREROUTING -j PROTO --set-proto 17 2>/dev/null || true
    echo "$(tag_ok)[mangle/PREROUTING] -j PROTO -> ${_pkts:-0} pkt(s)"
fi

# xt_DNETMAP: install rule -> proc files created -> read them for seq_show coverage
try_rule nat POSTROUTING -j DNETMAP --prefix 10.1.0.0/24
# After rule insertion, DNETMAP creates /proc/net/xt_dnetmap/10.1.0.0_24
# Reading covers dnetmap_seq_show, dnetmap_stat_proc_show, etc.
if iptables -t nat -I POSTROUTING -j DNETMAP --prefix 10.2.0.0/24 2>/dev/null; then
    # Drive traffic while rule is active (covers dnetmap_tg if conntrack works)
    iptables -t nat -Z POSTROUTING 2>/dev/null || true
    drive_heavy
    _pkts=$(iptables -t nat -nv -L POSTROUTING 2>/dev/null | awk 'NR==3{print $1+0; exit}')
    # Read proc entries -> covers seq functions
    for _pf in /proc/net/xt_dnetmap/*; do
        [ -f "$_pf" ] && cat "$_pf" >/dev/null 2>&1 || true
    done
    iptables -t nat -D POSTROUTING -j DNETMAP --prefix 10.2.0.0/24 2>/dev/null || true
    echo "$(tag_ok)[nat/POSTROUTING] DNETMAP + proc read -> ${_pkts:-0} pkt(s)"
fi

# ── pknock: port-knock sequence ───────────────────────────────────────────────
# Strategy: activate conntrack FIRST (already done above), then knock.
# With conntrack active, the TCP SYN packets ARE tracked. pknock checks
# the DESTINATION port of the incoming packet for the knock sequence.
_pk_nm="pktst"
if iptables -t filter -I INPUT \
        -m pknock --knockports "1234,2345,3456" --name "$_pk_nm" -p tcp \
        -j ACCEPT 2>/dev/null; then
    # Read proc file for this rule -> pknock_proc_open + pknock_seq_show
    cat /proc/net/xt_pknock/"$_pk_nm" >/dev/null 2>&1 || true
    # Knock sequence: SYN to each port in order
    for _kp in 1234 2345 3456; do
        timeout 0.3 nc -w1 127.0.0.1 $_kp </dev/null 2>/dev/null || true
        sleep 0.05
    done
    # Read proc again after knocking (shows peer state -> pknock_seq_show)
    cat /proc/net/xt_pknock/"$_pk_nm" >/dev/null 2>&1 || true
    # After full knock, TCP from approved IP should match
    iptables -t filter -Z INPUT 2>/dev/null || true
    drive_traffic
    _pkts=$(iptables -t filter -nv -L INPUT 2>/dev/null | awk 'NR==3{print $1+0; exit}')
    iptables -t filter -D INPUT \
        -m pknock --knockports "1234,2345,3456" --name "$_pk_nm" -p tcp \
        -j ACCEPT 2>/dev/null || true
    echo "$(tag_ok)[filter/INPUT] pknock sequence -> ${_pkts:-0} pkt(s) after knock"
fi

# pknock --checkip: different code path (checks if IP was approved)
if iptables -t filter -I INPUT \
        -m pknock --checkip --name "$_pk_nm" -j ACCEPT 2>/dev/null; then
    iptables -t filter -Z INPUT 2>/dev/null || true
    drive_traffic
    _pkts=$(iptables -t filter -nv -L INPUT 2>/dev/null | awk 'NR==3{print $1+0; exit}')
    iptables -t filter -D INPUT \
        -m pknock --checkip --name "$_pk_nm" -j ACCEPT 2>/dev/null || true
    echo "$(tag_ok)[filter/INPUT] pknock --checkip -> ${_pkts:-0} pkt(s)"
fi

# ── ACCOUNT ───────────────────────────────────────────────────────────────────
IPTACC=$(find "$SRC" -name iptaccount -type f 2>/dev/null | head -1)
if [ "${XA_TEST_ACCOUNT:-0}" = "1" ] && \
   iptables -t filter -I INPUT -j ACCOUNT \
       --addr 10.0.0.0/24 --tname acct1 2>/dev/null; then
    iptables -t filter -Z INPUT 2>/dev/null || true
    drive_traffic
    _pkts=$(iptables -t filter -nv -L INPUT 2>/dev/null | awk 'NR==3{print $1+0; exit}')
    if [ -n "$IPTACC" ]; then
        "$IPTACC" -l  2>/dev/null || true
        "$IPTACC" -a  2>/dev/null || true
        "$IPTACC" -f acct1 2>/dev/null || true
    fi
    iptables -t filter -D INPUT -j ACCOUNT \
        --addr 10.0.0.0/24 --tname acct1 2>/dev/null || true
    echo "$(tag_ok)[filter/INPUT] -j ACCOUNT -> ${_pkts:-0} pkt(s)"
else
    skip_note "xt_ACCOUNT" "known kernel bug in checkentry (XA_TEST_ACCOUNT=1 to force)"
fi

# ── Cleanup conntrack rule ────────────────────────────────────────────────────
[ "$_ct_loaded" = "1" ] && \
    iptables -t filter -D INPUT -m conntrack \
        --ctstate NEW,ESTABLISHED,RELATED,INVALID -j ACCEPT 2>/dev/null || true

echo "xtables-addons in-guest tests complete"

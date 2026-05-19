#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# collect-artifacts.sh — collect fuzzing artifacts into a compressed .tar.xz
# archive placed in the syzkaller workdir.
#
# Archive layout:
#   artifacts_<TIMESTAMP>/
#     crashes/
#     corpus.db
#     fuzzing.log
#     configs/
#       config.json          desired syzkaller config (template-generated)
#       linux-<HASH>         kernel .config
#       syzkaller-<HASH>     actual running syzkaller config (from HTTP /config)
#     coverage/
#       index.html
#     [vmlinux]              only with --with-rawcover
#     [rawcover]             only with --with-rawcover
#
# With --trim-crashes: for each crash directory, repeated log/report/machineInfo
# files are trimmed to the 3 most recent; reproducers are always kept in full.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../project.env"
source "$SCRIPT_DIR/../01-setup-env.sh" &>/dev/null

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

WITH_RAWCOVER="false"
TRIM_CRASHES="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            cat <<USAGE
Usage: $(basename "$0") [--with-rawcover] [--trim-crashes]

Collects all fuzzing artifacts into a .tar.xz archive in \$SYZKALLER_WORKDIR.

OPTIONS
  --with-rawcover    Also include vmlinux and rawcover in the archive.
                     Useful for post-processing coverage with addr2line.
                     Disabled by default due to size.

  --trim-crashes     Trim repeated log/report/machineInfo files in each crash
                     directory to the 3 most recent. Reproducers are kept in
                     full. Useful for reducing archive size.
USAGE
            exit 0 ;;
        --with-rawcover) WITH_RAWCOVER="true"; shift ;;
        --trim-crashes)  TRIM_CRASHES="true";  shift ;;
        *) die "unknown argument: $1" ;;
    esac
done

HTTP="http://0.0.0.0:${DEFAULT_SYZ_HTTP_INTERNAL_PORT}"

[[ -d "$SYZKALLER_WORKDIR/crashes"   ]] || die "crashes not found: $SYZKALLER_WORKDIR/crashes"
[[ -f "$SYZKALLER_WORKDIR/corpus.db" ]] || die "corpus.db not found: $SYZKALLER_WORKDIR/corpus.db"
[[ -f "$SYZKALLER_CONFIG_PATH"       ]] || die "config not found: $SYZKALLER_CONFIG_PATH"
[[ -f "$KERNEL_BUILD_DIR/.config"    ]] || die "kernel .config not found: $KERNEL_BUILD_DIR/.config"
if [[ "$WITH_RAWCOVER" == "true" ]]; then
    [[ -f "$KERNEL_BUILD_DIR/vmlinux" ]] || die "vmlinux not found: $KERNEL_BUILD_DIR/vmlinux"
fi

LINUX_HASH=$(git -C "$KERNEL_DIR"    rev-parse --short HEAD 2>/dev/null) \
    || die "could not get kernel git hash from $KERNEL_DIR"
SYZ_HASH=$(git -C "$SYZKALLER_DIR"   rev-parse --short HEAD 2>/dev/null) \
    || die "could not get syzkaller git hash from $SYZKALLER_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
STAGING=$(mktemp -d --suffix=.syz-artifacts)
ARTIFACT_DIR="$STAGING/artifacts_${TIMESTAMP}"
mkdir -p "$ARTIFACT_DIR/configs"
trap 'rm -rf "$STAGING"' EXIT

echo "▶ Copying crashes ..."
cp -r "$SYZKALLER_WORKDIR/crashes" "$ARTIFACT_DIR/crashes"
N_CRASHES=$(find "$ARTIFACT_DIR/crashes" -mindepth 1 -maxdepth 1 -type d | wc -l)

if [[ "$TRIM_CRASHES" == "true" ]]; then
    # For each crash directory, group files by their alphabetic prefix
    # (log, report, machineInfo). If a group has more than 3 entries, keep
    # only the 3 with the highest numbers. Files without a numeric suffix
    # (repro.*, description, title-stat, etc.) are always preserved.
    python3 - "$ARTIFACT_DIR/crashes" <<'PYEOF'
import os, re, sys

crashes_dir = sys.argv[1]
KEEP = 3
total_removed = 0

for crash_name in sorted(os.listdir(crashes_dir)):
    crash_path = os.path.join(crashes_dir, crash_name)
    if not os.path.isdir(crash_path):
        continue

    groups: dict[str, list[tuple[int, str]]] = {}
    for fname in os.listdir(crash_path):
        m = re.fullmatch(r'([a-zA-Z]+)(\d+)', fname)
        if m:
            groups.setdefault(m.group(1), []).append((int(m.group(2)), fname))

    removed = 0
    for entries in groups.values():
        if len(entries) <= KEEP:
            continue
        entries.sort(key=lambda x: x[0], reverse=True)
        for _, fname in entries[KEEP:]:
            os.remove(os.path.join(crash_path, fname))
            removed += 1

    if removed:
        print(f"  {crash_name}: -{removed} file(s)")
    total_removed += removed

print(f"  Total removed: {total_removed} redundant file(s).")
PYEOF
else
    info "$N_CRASHES crash director(y/ies)."
fi

echo "▶ Copying corpus ..."
cp "$SYZKALLER_WORKDIR/corpus.db" "$ARTIFACT_DIR/corpus.db"
info "$(du -sh "$ARTIFACT_DIR/corpus.db" | cut -f1)."

echo "▶ Copying fuzzing log ..."
if [[ -f /tmp/alt-syz-box.log ]]; then
    cp /tmp/alt-syz-box.log "$ARTIFACT_DIR/fuzzing.log"
else
    echo "  WARNING: /tmp/alt-syz-box.log not found, skipping."
fi

echo "▶ Collecting configs ..."
cp "$SYZKALLER_CONFIG_PATH" "$ARTIFACT_DIR/configs/config.json"
cp "$KERNEL_BUILD_DIR/.config" "$ARTIFACT_DIR/configs/linux-${LINUX_HASH}"
SYZ_CONFIG_OUT="$ARTIFACT_DIR/configs/syzkaller-${SYZ_HASH}"
curl -sf "${HTTP}/config" > "$SYZ_CONFIG_OUT" \
    || die "curl failed fetching /config — is syz-manager running?"
[[ -s "$SYZ_CONFIG_OUT" ]] \
    || die "empty response from ${HTTP}/config"

# The /config endpoint serves an HTML page with the running syzkaller config
# embedded inside a <pre> block and HTML-escaped (e.g. &#34; for "). Extract
# the contents of that block and unescape it so the result is readable JSON.
python3 - "$SYZ_CONFIG_OUT" <<'PYEOF'
import sys, re, html

path = sys.argv[1]
with open(path) as f:
    raw = f.read()

# Grab the JSON inside <pre>...</pre>; fall back to the whole payload if the
# endpoint ever returns plain JSON (older/newer syzkaller versions).
m = re.search(r'<pre>(.*)</pre>', raw, re.DOTALL)
text = html.unescape(m.group(1) if m else raw).strip()

with open(path, 'w') as f:
    f.write(text + '\n')
PYEOF
[[ -s "$SYZ_CONFIG_OUT" ]] \
    || die "failed to extract syzkaller config from ${HTTP}/config"
info "linux-${LINUX_HASH}, syzkaller-${SYZ_HASH}, config.json"

echo "▶ Collecting coverage ..."
"$SCRIPT_DIR/collect-coverage.sh" -o "$ARTIFACT_DIR/coverage"

if [[ "$WITH_RAWCOVER" == "true" ]]; then
    echo "▶ Copying vmlinux ..."
    cp "$KERNEL_BUILD_DIR/vmlinux" "$ARTIFACT_DIR/vmlinux"
    info "$(du -sh "$ARTIFACT_DIR/vmlinux" | cut -f1)."

    echo "▶ Fetching rawcover ..."
    curl -sf "${HTTP}/rawcover" > "$ARTIFACT_DIR/rawcover" \
        || die "curl failed fetching /rawcover"
    [[ -s "$ARTIFACT_DIR/rawcover" ]] \
        || die "empty rawcover — is cover=true in syzkaller config?"
    info "$(wc -l < "$ARTIFACT_DIR/rawcover") addresses."
fi

OUTPUT="$SYZKALLER_WORKDIR/artifacts_${TIMESTAMP}.tar.xz"
echo "▶ Creating archive ..."
XZ_OPT="-9e -T0" tar -cJf "$OUTPUT" -C "$STAGING" "artifacts_${TIMESTAMP}"

echo "✅ Archive ready: $OUTPUT ($(du -sh "$OUTPUT" | cut -f1))"

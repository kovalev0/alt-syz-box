#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# save-syzmanager-page.sh — save the syz-manager main page with
# "Expert mode" enabled into a single .html file, ready to be opened
# in a browser and screenshotted by hand.
#
# Expert mode is a per-session toggle (🧠 button in the title bar)
# that expands the stats with extra columns. It is flipped by POSTing
# toggle=expert + url=/ to /action; the server remembers the state
# via session cookie. To make the result deterministic we GET / with
# a cookie jar, POST the toggle only if needed, then GET / again
# and save the body.
#
# The default URL is built from DEFAULT_SYZ_HTTP_INTERNAL_PORT in
# project.env. Pass -u to override (use port 12085 when running on
# the host).

set -eo pipefail

PROJECT_ENV="$(dirname "$(readlink -f "$0")")/../../project.env"
if [[ -f "$PROJECT_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$PROJECT_ENV"
fi

URL_DEFAULT="http://localhost:${DEFAULT_SYZ_HTTP_INTERNAL_PORT:-56741}"
URL="$URL_DEFAULT"
OUT_FILE=""

usage() {
    cat <<USAGE
Usage: $(basename "$0") [-u URL] [-o OUT_FILE]

  -u URL       syz-manager URL (default: $URL_DEFAULT, taken from
               DEFAULT_SYZ_HTTP_INTERNAL_PORT in project.env).
               Use http://localhost:12085 when running on the host.
  -o OUT_FILE  output .html file
               (default: ./syzmanager_page_<TIMESTAMP>.html).
  -h, --help   this help.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u) URL="$2"; shift 2 ;;
        -o) OUT_FILE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

URL="${URL%/}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_FILE="${OUT_FILE:-./syzmanager_page_${TIMESTAMP}.html}"

command -v curl >/dev/null 2>&1 \
    || { echo "ERROR: curl is required." >&2; exit 1; }

if ! curl -fsS --max-time 5 -o /dev/null "$URL/"; then
    echo "ERROR: $URL/ is not responding. Is syz-manager running?" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"
echo "▶ Saving syz-manager main page from $URL/ → $OUT_FILE"

COOKIES=$(mktemp)
PROBE=$(mktemp)
trap 'rm -f "$COOKIES" "$PROBE"' EXIT

# 1) Inspect: is expert mode already on?
#    The Expert button carries class="action_button_selected" when active
#    and class="action_button" otherwise — the easiest reliable signal.
curl -fsS --max-time 30 -c "$COOKIES" -b "$COOKIES" -o "$PROBE" "$URL/"

if grep -qE 'value="expert"[^>]*class="action_button_selected"' "$PROBE"; then
    echo "  Expert mode already active — skipping toggle."
else
    echo "  Toggling Expert mode on ..."
    # Response is a 30x redirect back to / — follow it so the cookie
    # sticks to the right path.
    curl -fsS --max-time 30 -c "$COOKIES" -b "$COOKIES" \
        -o /dev/null \
        --data-urlencode "url=/" \
        --data-urlencode "toggle=expert" \
        -L "$URL/action"
fi

# 2) Fetch / now that expert mode is on (or was already on).
curl -fsS --max-time 30 -b "$COOKIES" -o "$OUT_FILE" "$URL/"

if ! grep -qE 'value="expert"[^>]*class="action_button_selected"' "$OUT_FILE"; then
    echo "  WARNING: saved file does not show Expert mode as active." >&2
    echo "           The server may not honor /action toggles on this build." >&2
fi

size=$(stat -c%s "$OUT_FILE" 2>/dev/null || stat -f%z "$OUT_FILE")
echo "✅ Done. Open: $OUT_FILE  (${size} bytes)"

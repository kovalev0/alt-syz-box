#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# html-to-pdf.sh INDEX_HTML OUT_PDF [COVERAGE_INFO]
#
# Render a genhtml coverage summary page (index.html, with its CSS and colour
# bars) to a single PDF — the same view you get by opening index.html in a
# browser and choosing "Save as PDF". Tries, in order: wkhtmltopdf, headless
# Chromium/Chrome. If neither is present it falls back to the dependency-free
# text renderer (gen-coverage-pdf.py) using COVERAGE_INFO, so a PDF is always
# produced.

set -u

INDEX="${1:?usage: html-to-pdf.sh INDEX_HTML OUT_PDF [COVERAGE_INFO]}"
OUT="${2:?usage: html-to-pdf.sh INDEX_HTML OUT_PDF [COVERAGE_INFO]}"
COVINFO="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

abs() { readlink -f "$1" 2>/dev/null || echo "$1"; }
INDEX_ABS="$(abs "$INDEX")"

# 1) Headless Chromium/Chrome.
for CH in chromium chromium-browser google-chrome google-chrome-stable chrome; do
    if command -v "$CH" >/dev/null 2>&1 && [ -f "$INDEX_ABS" ]; then
        if "$CH" --headless --no-sandbox --disable-gpu --no-pdf-header-footer \
                 --print-to-pdf="$OUT" "file://$INDEX_ABS" >/dev/null 2>&1 \
           && [ -s "$OUT" ]; then
            echo "PDF via $CH: $OUT"
            exit 0
        fi
    fi
done

# 2) wkhtmltopdf — best fidelity for genhtml pages.
if command -v wkhtmltopdf >/dev/null 2>&1 && [ -f "$INDEX_ABS" ]; then
    if wkhtmltopdf --enable-local-file-access --quiet "$INDEX_ABS" "$OUT" 2>/dev/null \
       && [ -s "$OUT" ]; then
        echo "PDF via wkhtmltopdf: $OUT"
        exit 0
    fi
fi

# 3) Fallback: dependency-free text renderer from the lcov tracefile.
if [ -n "$COVINFO" ] && [ -f "$COVINFO" ] && [ -f "$HERE/gen-coverage-pdf.py" ]; then
    title="$(basename "$(dirname "$(dirname "$INDEX_ABS")")")"
    if python3 "$HERE/gen-coverage-pdf.py" -i "$COVINFO" -o "$OUT" \
            -t "Coverage report: $title" >/dev/null 2>&1 && [ -s "$OUT" ]; then
        echo "PDF via text fallback (install wkhtmltopdf for the HTML view): $OUT"
        exit 0
    fi
fi

echo "html-to-pdf: could not produce $OUT (no wkhtmltopdf/chromium and no fallback data)" >&2
exit 1

#!/usr/bin/env python3
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# gen-coverage-pdf.py — render an lcov tracefile (coverage.info) as a compact,
# human-readable PDF: a per-file table of line/function/branch rates plus totals,
# and optionally the tail of a test-run log. Depends on the Python standard
# library only (no wkhtmltopdf/headless browser needed), so it always works in
# the build container. Prefer this for archiving; the genhtml HTML remains for
# interactive browsing.

import argparse
import datetime
import os
import sys


def parse_lcov(path):
    """Return (files, totals). Each file dict has sf and covered/total counts."""
    files = []
    totals = {"LF": 0, "LH": 0, "FNF": 0, "FNH": 0, "BRF": 0, "BRH": 0}
    cur = None
    da_t = da_h = 0
    fn_names = set()
    fn_hit = set()
    br_t = br_h = 0
    exp = {}

    def flush():
        nonlocal cur, da_t, da_h, fn_names, fn_hit, br_t, br_h, exp
        if cur is None:
            return
        cur["LF"] = exp.get("LF", da_t)
        cur["LH"] = exp.get("LH", da_h)
        cur["FNF"] = exp.get("FNF", len(fn_names))
        cur["FNH"] = exp.get("FNH", len(fn_hit))
        cur["BRF"] = exp.get("BRF", br_t)
        cur["BRH"] = exp.get("BRH", br_h)
        for k in totals:
            totals[k] += cur[k]
        files.append(cur)
        cur = None
        da_t = da_h = 0
        fn_names = set()
        fn_hit = set()
        br_t = br_h = 0
        exp = {}

    with open(path, "r", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if line.startswith("SF:"):
                flush()
                cur = {"sf": line[3:]}
            elif cur is None:
                continue
            elif line.startswith("DA:"):
                parts = line[3:].split(",")
                da_t += 1
                if len(parts) >= 2 and parts[1].strip() not in ("0", "-"):
                    da_h += 1
            elif line.startswith("FN:"):
                nm = line[3:].split(",", 1)[-1]
                fn_names.add(nm)
            elif line.startswith("FNDA:"):
                p = line[5:].split(",", 1)
                if len(p) == 2 and p[0].strip() not in ("0", "-"):
                    fn_hit.add(p[1])
            elif line.startswith("BRDA:"):
                br_t += 1
                taken = line.split(",")[-1].strip()
                if taken not in ("-", "0"):
                    br_h += 1
            elif line.startswith("LF:"):
                exp["LF"] = int(line[3:])
            elif line.startswith("LH:"):
                exp["LH"] = int(line[3:])
            elif line.startswith("FNF:"):
                exp["FNF"] = int(line[4:])
            elif line.startswith("FNH:"):
                exp["FNH"] = int(line[4:])
            elif line.startswith("BRF:"):
                exp["BRF"] = int(line[4:])
            elif line.startswith("BRH:"):
                exp["BRH"] = int(line[4:])
            elif line == "end_of_record":
                flush()
    flush()
    return files, totals


def pct(h, t):
    return "%.1f%%" % (100.0 * h / t) if t else "  -  "


def build_lines(files, totals, title, tracefile, testlog):
    out = []
    out.append(title)
    out.append("=" * min(len(title), 90))
    out.append("Generated: %s" % datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    out.append("Tracefile: %s" % tracefile)
    out.append("")
    hdr = "%7s %11s %7s %7s  %s" % ("Lines", "(cov/tot)", "Func", "Branch", "File")
    out.append(hdr)
    out.append("-" * 90)
    for f in sorted(files, key=lambda x: x["sf"]):
        name = f["sf"]
        if len(name) > 52:
            name = "..." + name[-49:]
        out.append("%7s %11s %7s %7s  %s" % (
            pct(f["LH"], f["LF"]),
            "(%d/%d)" % (f["LH"], f["LF"]),
            pct(f["FNH"], f["FNF"]),
            pct(f["BRH"], f["BRF"]),
            name,
        ))
    out.append("-" * 90)
    out.append("%7s %11s %7s %7s  %s" % (
        pct(totals["LH"], totals["LF"]),
        "(%d/%d)" % (totals["LH"], totals["LF"]),
        pct(totals["FNH"], totals["FNF"]),
        pct(totals["BRH"], totals["BRF"]),
        "TOTAL",
    ))
    if not files:
        out.append("")
        out.append("(no coverage data — the module produced no .gcda)")

    if testlog and os.path.isfile(testlog):
        try:
            with open(testlog, "r", errors="replace") as fh:
                content = fh.read().splitlines()
        except OSError:
            content = []
        tail = content[-400:]
        out.append("")
        out.append("")
        out.append("Test log (%s, last %d lines)" % (os.path.basename(testlog), len(tail)))
        out.append("=" * 60)
        for ln in tail:
            # wrap long lines so nothing is clipped off the page
            while len(ln) > 110:
                out.append(ln[:110])
                ln = ln[110:]
            out.append(ln)
    return out


def _esc(s):
    return s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def write_pdf(lines, out_path, font_size=8, leading=10, margin=40,
              page=(595, 842)):
    """Minimal text PDF writer (Courier base-14), multi-page. Stdlib only."""
    usable = page[1] - 2 * margin
    per_page = max(1, int(usable // leading))
    chunks = [lines[i:i + per_page] for i in range(0, len(lines), per_page)] or [[]]

    objects = []  # (body_bytes,)

    def add(body):
        objects.append(body)
        return len(objects)  # 1-based object number

    catalog_num = add(b"")  # 1 placeholder, patched below
    pages_num = add(b"")    # 2 placeholder
    font_num = add(
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Courier "
        b"/Encoding /WinAnsiEncoding >>"
    )

    page_nums = []
    for chunk in chunks:
        y0 = page[1] - margin
        stream = ["BT", "/F0 %d Tf" % font_size, "%d TL" % leading,
                  "%d %d Td" % (margin, y0)]
        first = True
        for ln in chunk:
            if first:
                stream.append("(%s) Tj" % _esc(ln))
                first = False
            else:
                stream.append("T* (%s) Tj" % _esc(ln))
        stream.append("ET")
        data = ("\n".join(stream)).encode("latin-1", "replace")
        content_num = add(b"<< /Length %d >>\nstream\n" % len(data) + data +
                          b"\nendstream")
        pnum = add(
            ("<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %d %d] "
             "/Resources << /Font << /F0 %d 0 R >> >> /Contents %d 0 R >>"
             % (pages_num, page[0], page[1], font_num, content_num)).encode()
        )
        page_nums.append(pnum)

    kids = " ".join("%d 0 R" % n for n in page_nums)
    objects[pages_num - 1] = (
        "<< /Type /Pages /Kids [%s] /Count %d >>" % (kids, len(page_nums))
    ).encode()
    objects[catalog_num - 1] = (
        "<< /Type /Catalog /Pages %d 0 R >>" % pages_num
    ).encode()

    buf = bytearray(b"%PDF-1.4\n")
    offsets = [0] * (len(objects) + 1)
    for i, body in enumerate(objects, start=1):
        offsets[i] = len(buf)
        buf += ("%d 0 obj\n" % i).encode() + body + b"\nendobj\n"
    xref_pos = len(buf)
    buf += ("xref\n0 %d\n" % (len(objects) + 1)).encode()
    buf += b"0000000000 65535 f \n"
    for i in range(1, len(objects) + 1):
        buf += ("%010d 00000 n \n" % offsets[i]).encode()
    buf += ("trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n"
            % (len(objects) + 1, catalog_num, xref_pos)).encode()

    with open(out_path, "wb") as fh:
        fh.write(buf)


def main():
    ap = argparse.ArgumentParser(description="Render an lcov tracefile as PDF.")
    ap.add_argument("-i", "--input", required=True, help="coverage.info path")
    ap.add_argument("-o", "--output", required=True, help="output PDF path")
    ap.add_argument("-t", "--title", default="Coverage report")
    ap.add_argument("--testlog", default="", help="optional test log to append")
    args = ap.parse_args()

    if not os.path.isfile(args.input):
        print("gen-coverage-pdf: input not found: %s" % args.input, file=sys.stderr)
        return 1
    files, totals = parse_lcov(args.input)
    lines = build_lines(files, totals, args.title, args.input, args.testlog)
    write_pdf(lines, args.output)
    print("COVERAGE_LINES_PCT=%s" % (pct(totals["LH"], totals["LF"]).strip()))
    print("Wrote %s (%d files, %d pages of text)" %
          (args.output, len(files), max(1, (len(lines) + 76) // 77)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

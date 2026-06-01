#!/usr/bin/env python3
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Vasiliy Kovalev <kovalev@altlinux.org>
#
# gen-crashes-table.py — generate "Table 2: Crash analysis" as a self
# contained ODS file from the running syz-manager main HTML page, ready
# to be embedded as an OLE object into the .odt fuzzing report.
#
# Columns:
#   1. Заголовок падения      — crash title (from syz-manager "Description"),
#                                 hard-wrapped every ~18 chars at separator
#                                 boundaries so the column stays narrow.
#   2. Repro                  — has C repro / has repro / non-reproducible /
#                                 reproducing (from "Report" with the trailing
#                                 " Strace" marker stripped).
#   3. Воспроизводится в VM   — analyst input: да / нет.
#   4. Статус                 — analyst input:
#                                 Подтверждено / Не подтверждено / В работе.
#   5. CVE / fix              — analyst input: CVE-YYYY-NNNNN, kernel version
#                                 ("v6.12.61"), commit hash, or any free-form
#                                 note describing the upstream fix. Cells
#                                 starting with "CVE-" are colored green;
#                                 any other non-empty value is colored blue.
#   6. Комментарий            — free-form analyst note.
#
# Coloring is implemented as native LibreOffice conditional formatting
# (calcext:conditional-formats) so cells repaint as the analyst types.
# Analyst-facing columns also get an ODF content-validation list, which
# Calc renders as a dropdown with autocomplete on the first letters typed.
#
# A summary block (live COUNTIF formulas) and a legend of allowed values
# are appended on the same sheet.
#
# Requirements:
#   pip install --user beautifulsoup4 odfpy
#
# Usage:
#   # From inside the alt-syz-box container, against a live syz-manager:
#   ./gen-crashes-table.py
#
#   # From a previously saved HTML page (no live syz-manager needed):
#   curl -s http://localhost:56741/ > /tmp/main.html      # inside container
#   curl -s http://localhost:12085/ > /tmp/main.html      # outside container
#   ./gen-crashes-table.py -i /tmp/main.html
#
#   # Custom URL / output path:
#   ./gen-crashes-table.py -u http://localhost:12085/ -o my.ods

import argparse
import sys
import urllib.request
import zipfile
from typing import Dict, List, Optional, Tuple

try:
    from bs4 import BeautifulSoup
except ImportError:
    sys.stderr.write("ERROR: beautifulsoup4 is required.\n"
                     "  pip install --user beautifulsoup4 odfpy\n")
    sys.exit(1)

try:
    from odf.opendocument import OpenDocumentSpreadsheet
    from odf.table import (Table, TableRow, TableCell, TableColumn,
                           CoveredTableCell, ContentValidations,
                           ContentValidation, ErrorMessage)
    from odf.text import P
    from odf.style import (
        Style, TableColumnProperties, TableCellProperties,
        TextProperties, ParagraphProperties,
    )
except ImportError:
    sys.stderr.write("ERROR: odfpy is required.\n"
                     "  pip install --user beautifulsoup4 odfpy\n")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

def _read_project_env_var(var_name: str) -> Optional[str]:
    """Read a shell-export variable from project.env. The file is
    searched for relative to this script (../../project.env, since the
    script lives in scripts/tools/). Returns None if anything goes wrong.
    """
    import os, re
    candidate = os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "..", "..", "project.env"))
    if not os.path.isfile(candidate):
        return None
    try:
        with open(candidate, encoding="utf-8") as f:
            for line in f:
                m = re.match(rf'^\s*(?:export\s+)?{re.escape(var_name)}=(.*)$',
                             line.strip())
                if not m:
                    continue
                v = m.group(1).strip()
                if (v.startswith('"') and v.endswith('"')) \
                        or (v.startswith("'") and v.endswith("'")):
                    v = v[1:-1]
                return v
    except OSError:
        pass
    return None


# DEFAULT_SYZ_HTTP_INTERNAL_PORT is the port syz-manager listens on
# inside the alt-syz-box container; sourced from project.env so the two
# stay in sync. Fall back to 56741 (the project default) if the file
# cannot be read.
_SYZ_PORT = _read_project_env_var("DEFAULT_SYZ_HTTP_INTERNAL_PORT") or "56741"
DEFAULT_URL = f"http://localhost:{_SYZ_PORT}/"
DEFAULT_OUT = "crash_analysis_table.ods"
SHEET_NAME = "Crashes"

HEADER = [
    "Заголовок падения",
    "Repro",
    "Воспроизводится в VM",
    "Статус",
    "CVE / fix",
    "Комментарий",
]

# Per-column widths. Picked by hand to balance compactness against
# readability in A4 landscape; the "Комментарий" column also serves
# as the duplicate-marker dropdown, so it stays wide.
#                       title  repro  vm    status cve/fix comment
COL_WIDTHS_CM        = [ 6.0,   1.6,   1.6,  1.8,   4.0,    14.0 ]

# Columns whose values are short tags and look better centered.
# 0-based indices.
CENTERED_COLS = {1, 2, 3, 4}

# Crash title hard-wrap target. Words break at separators (space, _, -, :, /)
# whenever the line has grown to this length; a hard break is forced past
# `WRAP_MAX`.
WRAP_TARGET = 26
WRAP_MAX = 36


# ---------------------------------------------------------------------------
# Color palette
# ---------------------------------------------------------------------------
# Each entry: (background, foreground, bold).
PALETTE: Dict[str, Tuple[str, str, bool]] = {
    "header":      ("#305496", "#FFFFFF", True),
    "zebra_light": ("#FFFFFF", "#000000", False),
    "zebra_dark":  ("#F2F2F2", "#000000", False),
    "green":       ("#C6EFCE", "#1F6E2D", True),
    "yellow":      ("#FFEB9C", "#7F6000", True),
    "red":         ("#FFC7CE", "#9C0006", True),
    "blue":        ("#DDEBF7", "#1F4E79", True),
    "gray":        ("#D9D9D9", "#595959", False),
    "summary_h":   ("#1F4E79", "#FFFFFF", True),
    "legend_h":    ("#1F4E79", "#FFFFFF", True),
}


# ---------------------------------------------------------------------------
# Coloring rules
# ---------------------------------------------------------------------------
# Rules per column index (0-based, matching HEADER).
#   ("eq", value, color)        — exact string match
#   ("prefix", prefix, color)   — value starts with `prefix`
#   ("nonempty", "", color)     — any non-empty value
#
# Within a column rules are evaluated top-down; the first match wins.
# That is why the CVE rule comes BEFORE the generic "nonempty" rule
# in the "CVE / fix" column: a value like "CVE-2025-12345" should be
# green, not blue.
TRIGGER_RULES: Dict[int, List[Tuple[str, str, str]]] = {
    # Repro (col 1) — from syz-manager. "нет данных" is the synthetic
    # value injected by _normalize_repro() when syz-manager hasn't (yet)
    # reported any repro state for the crash; treated as gray.
    1: [
        ("eq", "has C repro",       "green"),
        ("eq", "has repro",         "green"),
        ("eq", "non-reproducible",  "gray"),
        ("eq", "reproducing",       "yellow"),
        ("eq", "нет данных",        "gray"),
    ],
    # Воспроизводится в VM (col 2).
    2: [
        ("eq", "да",  "green"),
        ("eq", "нет", "red"),
    ],
    # Статус (col 3).
    3: [
        ("eq", "Подтверждено",     "green"),
        ("eq", "Не подтверждено",  "red"),
        ("eq", "В работе",         "yellow"),
    ],
    # CVE / fix (col 4) — CVE first, then generic "has any fix info".
    4: [
        ("prefix", "CVE-", "green"),
        ("nonempty", "", "blue"),
    ],
    # Комментарий (col 5) — only the duplicate marker is colored.
    # Free-form text stays in the default zebra style.
    5: [
        ("prefix", "Дубликат ", "gray"),
    ],
}


# Prefix used both by the duplicate-marker dropdown and by the COUNTIF
# wildcard in the summary block. Keep these in sync.
DUPLICATE_PREFIX = "Дубликат "


# Columns wired to a dropdown list with autocomplete.
DROPDOWN_COLS: Dict[int, List[str]] = {
    1: ["has C repro", "has repro", "non-reproducible", "reproducing",
        "нет данных"],
    2: ["да", "нет"],
    3: ["Подтверждено", "Не подтверждено", "В работе"],
}


def _resolve_static_color(col_idx: int, value: str) -> Optional[str]:
    """Pick the palette key that conditional formatting WILL assign to
    `value` — used to bake in a direct fill for values known at
    generation time, so the file looks right even before any GUI recalc.
    """
    if not value:
        return None
    v = value.strip()
    for kind, payload, color in TRIGGER_RULES.get(col_idx, []):
        if kind == "eq" and v == payload:
            return color
        if kind == "prefix" and v.upper().startswith(payload.upper()):
            return color
        if kind == "nonempty" and v:
            return color
    return None


def _normalize_repro(value: str) -> str:
    """syz-manager appends a trailing ' Strace' marker for crashes that
    also have a strace-traced reproducer. Strip it so the value matches
    our enum (we don't use strace traces in the analysis flow).

    Empty values (no repro info from syz-manager yet) are reported as
    "нет данных" so the cell is colored gray and the analyst sees at a
    glance that the crash hasn't been processed by syz-manager yet.
    """
    v = (value or "").strip()
    for suffix in (" Strace", " strace"):
        if v.endswith(suffix):
            v = v[:-len(suffix)].strip()
    if not v:
        return "нет данных"
    return v


def _wrap_title(s: str,
                target: int = WRAP_TARGET,
                max_w: int = WRAP_MAX) -> List[str]:
    """Break `s` into lines of roughly `target` characters, preferring
    breaks at separator characters (space, _, -, :, /). Forces a hard
    break past `max_w` if no separator was found in time.
    Returns the list of lines (always at least one element).
    """
    if not s:
        return [""]
    lines: List[str] = []
    cur = ""
    for ch in s:
        cur += ch
        if len(cur) >= target and ch in " _-:/":
            lines.append(cur)
            cur = ""
        elif len(cur) >= max_w:
            lines.append(cur)
            cur = ""
    if cur:
        lines.append(cur)
    return lines


# ---------------------------------------------------------------------------
# HTML scraping
# ---------------------------------------------------------------------------
def fetch_html(url: str) -> str:
    req = urllib.request.Request(url, headers={"Accept": "text/html"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", errors="replace")


def parse_crashes(html: str) -> List[Dict[str, str]]:
    """Return a list of {column_name: cell_text} dicts for the syz-manager
    crash table found in `html`. Column names are lowercased syz-manager
    headers ("description", "count", "report", ...).
    """
    soup = BeautifulSoup(html, "html.parser")
    best = None
    best_score = 0
    for tbl in soup.find_all("table"):
        headers = [th.get_text(strip=True).lower()
                   for th in tbl.find_all("th")]
        if not headers:
            first_row = tbl.find("tr")
            if first_row:
                headers = [td.get_text(strip=True).lower()
                           for td in first_row.find_all(["td", "th"])]
        joined = " ".join(headers)
        score = sum(1 for kw in ("description", "title", "crash",
                                 "count", "repro", "report") if kw in joined)
        if score > best_score:
            best, best_score = (tbl, headers), score

    if not best or best_score < 2:
        sys.stderr.write("WARNING: no crash table found on the page; "
                         "the output ODS will contain only the header row.\n")
        return []

    tbl, headers = best
    rows = tbl.find_all("tr")
    out: List[Dict[str, str]] = []
    for tr in rows[1:]:
        cells = tr.find_all(["td", "th"])
        if not cells:
            continue
        row: Dict[str, str] = {}
        for i, c in enumerate(cells):
            key = headers[i] if i < len(headers) and headers[i] else f"col{i}"
            row[key] = c.get_text(" ", strip=True)
        out.append(row)
    return out


def _pick(row: Dict[str, str], *candidates: str) -> str:
    for k in candidates:
        if k in row and row[k]:
            return row[k]
    return ""


# ---------------------------------------------------------------------------
# Style construction
# ---------------------------------------------------------------------------
def _add_cell_style(doc: OpenDocumentSpreadsheet,
                    name: str, palette_key: str,
                    centered: bool = False) -> Style:
    bg, fg, bold = PALETTE[palette_key]
    s = Style(name=name, family="table-cell")
    s.addElement(TableCellProperties(
        backgroundcolor=bg,
        border="0.5pt solid #808080",
        verticalalign="middle" if centered else "top",
        wrapoption="wrap",
        padding="0.05cm",
    ))
    s.addElement(TextProperties(
        color=fg,
        fontweight="bold" if bold else "normal",
    ))
    s.addElement(ParagraphProperties(
        textalign="center" if centered else "start",
    ))
    doc.styles.addElement(s)
    return s


def build_all_color_styles(doc: OpenDocumentSpreadsheet) -> None:
    for key in PALETTE:
        _add_cell_style(doc, f"COL_{key}",  key, centered=False)
        _add_cell_style(doc, f"COLC_{key}", key, centered=True)
    _add_cell_style(doc, "TITLE_summary", "summary_h", centered=False)
    _add_cell_style(doc, "TITLE_legend",  "legend_h",  centered=False)


# ---------------------------------------------------------------------------
# Content validation (dropdowns with autocomplete)
# ---------------------------------------------------------------------------
# Stock free-form comments offered at the top of the "Комментарий"
# dropdown. They go before the generated "Дубликат ..." entries and
# are intentionally capitalized (first letter uppercase) so they sort
# above any title-derived item.
TYPICAL_COMMENTS: List[str] = [
    "Полученный Repro не приводит к воспроизведению ошибки",
    "Срабатывание не связано с исходным кодом ядра",
    "Срабатывание при включенном механизме selinux",
    "Артефакт фаззинга, не баг ядра",
    "Артефакт окружения (KVM / VM не отдаёт console)",
    "Гонка, не каждый запуск воспроизводит",
    "Не пробовали запускать repro",
    "Требует дополнительной проверки",
    "Исправлено в upstream",
    "Воспроизводится в upstream",
]


def add_content_validations(doc: OpenDocumentSpreadsheet,
                            data_rows: List[Dict[str, str]]) -> Dict[int, str]:
    cv_container = ContentValidations()
    doc.spreadsheet.addElement(cv_container)

    # Static lists for the enumerated columns.
    static_lists: Dict[int, List[str]] = dict(DROPDOWN_COLS)

    # Dynamic list for the "Комментарий" column: TYPICAL_COMMENTS go
    # first (preserves their natural order), then one
    # "Дубликат <title>" entry per unique crash title currently present
    # in the data. The whole list stays unsorted so the typical
    # comments always come on top.
    titles_seen: List[str] = []
    for r in data_rows:
        t = _pick(r, "description", "title", "crash").strip()
        if t and t not in titles_seen:
            titles_seen.append(t)
    comment_options: List[str] = list(TYPICAL_COMMENTS)
    if titles_seen:
        comment_options += [f"{DUPLICATE_PREFIX}{t}" for t in titles_seen]
    static_lists[5] = comment_options

    mapping: Dict[int, str] = {}
    for col_idx, options in static_lists.items():
        name = f"vCol{col_idx}"
        # ODF formula strings are double-quoted; escape any embedded
        # double quotes by doubling them. Crash titles can contain ", ',
        # comma, etc. — only " is fatal for the syntax.
        values = ";".join(f'"{o.replace(chr(34), chr(34)*2)}"' for o in options)
        condition = f'of:cell-content-is-in-list({values})'
        cv = ContentValidation(
            name=name,
            condition=condition,
            allowemptycell="true",
            # "Комментарий" stays unsorted to keep the typical comments
            # at the top; the other lists are short and unsorted too.
            displaylist="unsorted",
            basecelladdress=f"{SHEET_NAME}.A1",
        )
        # Suppress the "invalid value" popup — the dropdown is a hint,
        # not a hard gate (the "Комментарий" column accepts free text).
        cv.addElement(ErrorMessage(display="false",
                                   messagetype="information"))
        cv_container.addElement(cv)
        mapping[col_idx] = name
    return mapping


# ---------------------------------------------------------------------------
# Cell helpers
# ---------------------------------------------------------------------------
def _txt_cell(style_name: str, text: str = "",
              validation_name: Optional[str] = None) -> TableCell:
    kwargs = {"stylename": style_name}
    if validation_name:
        kwargs["contentvalidationname"] = validation_name
    c = TableCell(**kwargs)
    c.addElement(P(text=text))
    return c


def _multiline_cell(style_name: str, lines: List[str]) -> TableCell:
    """A cell whose displayed text is split across several visual lines —
    one <text:p> per line. Used for the crash-title column."""
    c = TableCell(stylename=style_name)
    for line in lines:
        c.addElement(P(text=line))
    return c


def _formula_cell(style_name: str, formula: str,
                  precomputed: int = 0) -> TableCell:
    c = TableCell(stylename=style_name,
                  valuetype="float", formula=f"of:={formula}",
                  value=str(precomputed))
    c.addElement(P(text=str(precomputed)))
    return c


def _spanned_cell(style_name: str, text: str, span: int) -> TableCell:
    c = TableCell(stylename=style_name, numbercolumnsspanned=span)
    c.addElement(P(text=text))
    return c


def _col_letter(idx: int) -> str:
    return chr(ord("A") + idx)


# ---------------------------------------------------------------------------
# Main table builder
# ---------------------------------------------------------------------------
def build_ods(rows: List[Dict[str, str]], out_path: str) -> None:
    doc = OpenDocumentSpreadsheet()

    build_all_color_styles(doc)
    validation_names = add_content_validations(doc, rows or [])

    for i, w in enumerate(COL_WIDTHS_CM):
        s = Style(name=f"Col{i}", family="table-column")
        s.addElement(TableColumnProperties(columnwidth=f"{w}cm"))
        doc.automaticstyles.addElement(s)

    table = Table(name=SHEET_NAME)
    for i in range(len(COL_WIDTHS_CM)):
        table.addElement(TableColumn(stylename=f"Col{i}"))

    # --- Header row ---
    hr = TableRow()
    for title in HEADER:
        hr.addElement(_txt_cell("COLC_header", title))
    table.addElement(hr)

    # --- Data rows ---
    if not rows:
        rows = [{} for _ in range(10)]

    data_first_row = 2
    for idx, r in enumerate(rows, start=1):
        zebra = "dark" if (idx % 2 == 0) else "light"
        title = _pick(r, "description", "title", "crash")
        repro = _normalize_repro(_pick(r, "report", "repro", "status"))

        # If syz-manager hasn't reported any repro state yet, the crash
        # has not been triaged at all — pre-fill Status with "В работе"
        # so it shows up in the "В работе" summary tally instead of
        # leaving an empty (uncounted) cell.
        status = "В работе" if repro == "нет данных" else ""

        tr = TableRow()
        # Col 0: title — multiline, soft-wrapped.
        tr.addElement(_multiline_cell(f"COL_zebra_{zebra}",
                                      _wrap_title(title)))

        # Col 1..4: tags with conditional coloring.
        # Col 5: free-form comment.
        values = [repro, "", status, "", ""]
        for col_off, v in enumerate(values, start=1):
            static = _resolve_static_color(col_off, v)
            if static is not None:
                prefix = "COLC_" if col_off in CENTERED_COLS else "COL_"
                style_name = f"{prefix}{static}"
            else:
                prefix = "COLC_" if col_off in CENTERED_COLS else "COL_"
                style_name = f"{prefix}zebra_{zebra}"
            validation = validation_names.get(col_off)
            tr.addElement(_txt_cell(style_name, v, validation))
        table.addElement(tr)

    data_last_row = data_first_row + len(rows) - 1

    # --- Spacer ---
    sp = TableRow()
    for _ in range(len(HEADER)):
        sp.addElement(_txt_cell("COL_zebra_light", ""))
    table.addElement(sp)

    add_summary_block(table, rows, data_first_row, data_last_row)

    sp2 = TableRow()
    for _ in range(len(HEADER)):
        sp2.addElement(_txt_cell("COL_zebra_light", ""))
    table.addElement(sp2)

    add_legend_block(table)

    doc.spreadsheet.addElement(table)
    doc.save(out_path)

    inject_conditional_formats(out_path, data_first_row, data_last_row)


# ---------------------------------------------------------------------------
# Summary block (live COUNTIF formulas)
# ---------------------------------------------------------------------------
def add_summary_block(table: Table,
                      data_rows: List[Dict[str, str]],
                      first_row: int, last_row: int) -> None:
    a = _col_letter(0)   # Заголовок (for COUNTA "total")
    c = _col_letter(2)   # Воспроизводится в VM
    d = _col_letter(3)   # Статус
    e = _col_letter(4)   # CVE / fix
    f = _col_letter(5)   # Комментарий (used to count "Дубликат ..." rows)
    rng = lambda col: f"[.{col}{first_row}:.{col}{last_row}]"

    n_total = sum(1 for r in data_rows if (r.get("description") or
                                           r.get("title") or
                                           r.get("crash")))

    # COUNTIF with wildcards depends on the "Enable wildcards in formulas"
    # option (off by default on some installations); SUMPRODUCT + LEFT
    # always works regardless of that setting.
    dup_expr = (f'SUMPRODUCT((LEFT(TRIM({rng(f)});{len(DUPLICATE_PREFIX)})'
                f'="{DUPLICATE_PREFIX}")*1)')

    metrics: List[Tuple[str, str, int]] = [
        ("Всего падений",           f'COUNTA({rng(a)})',                       n_total),
        ("Дубликатов",              dup_expr,                                  0),
        ("Уникальных падений",      f'COUNTA({rng(a)})-{dup_expr}',            n_total),
        ("Воспроизводится в VM",    f'COUNTIF({rng(c)};"да")',                 0),
        ("Не воспроизводится в VM", f'COUNTIF({rng(c)};"нет")',                0),
        ("Подтверждено",            f'COUNTIF({rng(d)};"Подтверждено")',       0),
        ("Не подтверждено",         f'COUNTIF({rng(d)};"Не подтверждено")',    0),
        ("В работе",                f'COUNTIF({rng(d)};"В работе")',           0),
        ("С CVE",                   f'SUMPRODUCT((LEFT(TRIM({rng(e)});4)="CVE-")*1)', 0),
        ("С upstream-фиксом / CVE", f'SUMPRODUCT((LEN(TRIM({rng(e)}))>0)*1)',  0),
    ]

    n_cols = len(HEADER)

    title_row = TableRow()
    title_row.addElement(_spanned_cell("TITLE_summary", "Сводка", n_cols))
    for _ in range(n_cols - 1):
        title_row.addElement(CoveredTableCell())
    table.addElement(title_row)

    sub = TableRow()
    sub.addElement(_txt_cell("COLC_header", "Метрика"))
    sub.addElement(_txt_cell("COLC_header", "Знач."))
    for _ in range(n_cols - 2):
        sub.addElement(_txt_cell("COL_zebra_light", ""))
    table.addElement(sub)

    for k, (label, formula, precomp) in enumerate(metrics, start=1):
        zebra = "dark" if (k % 2 == 0) else "light"
        zname = f"zebra_{zebra}"
        tr = TableRow()
        tr.addElement(_txt_cell(f"COL_{zname}", label))
        tr.addElement(_formula_cell(f"COLC_{zname}", formula, precomp))
        for _ in range(n_cols - 2):
            tr.addElement(_txt_cell(f"COL_{zname}", ""))
        table.addElement(tr)


# ---------------------------------------------------------------------------
# Legend block
# ---------------------------------------------------------------------------
def add_legend_block(table: Table) -> None:
    n_cols = len(HEADER)

    title_row = TableRow()
    title_row.addElement(_spanned_cell(
        "TITLE_legend",
        "Допустимые значения и цветовая маркировка",
        n_cols))
    for _ in range(n_cols - 1):
        title_row.addElement(CoveredTableCell())
    table.addElement(title_row)

    sub = TableRow()
    sub.addElement(_txt_cell("COLC_header", "Допустимое значение"))
    sub.addElement(_txt_cell("COLC_header", "Цвет"))
    sub.addElement(_txt_cell("COLC_header", "Колонка"))
    sub.addElement(_spanned_cell("COLC_header", "Описание", n_cols - 3))
    for _ in range(n_cols - 4):
        sub.addElement(CoveredTableCell())
    table.addElement(sub)

    SHORT_LABEL = {
        1: "Repro",
        2: "VM repro",
        3: "Статус",
        4: "CVE / fix",
        5: "Comment",
    }

    LEGEND_NOTES = {
        ("Repro", "has C repro"):      "C-репродьюсер сгенерирован syzkaller'ом",
        ("Repro", "has repro"):        "только syz-prog без C-репродьюсера",
        ("Repro", "non-reproducible"): "syzkaller не смог сгенерировать репродьюсер",
        ("Repro", "reproducing"):      "идёт попытка воспроизведения",
        ("Repro", "нет данных"):       "syz-manager пока не показал статус репродьюсера",
        ("VM repro", "да"):  "воспроизводится на чистой ВМ",
        ("VM repro", "нет"): "на чистой ВМ не воспроизводится",
        ("Статус", "Подтверждено"):    "является дефектом в коде ядра",
        ("Статус", "Не подтверждено"): "ложноположительное / артефакт фаззинга",
        ("Статус", "В работе"):        "в очереди / на разборе",
        ("CVE / fix", "CVE-YYYY-NNNNN"):
            "присвоенный идентификатор CVE — приоритет над общим правилом",
        ("CVE / fix", "<любая непустая запись>"):
            "версия / коммит / описание upstream-фикса",
        ("Comment", f"{DUPLICATE_PREFIX}<название падения>"):
            "падение повторяет другое; выбирается из выпадающего списка "
            "и вычитается из «Уникальных падений» в сводке",
    }

    rows_stream: List[Tuple[str, str, str]] = []
    for col_idx in sorted(TRIGGER_RULES.keys()):
        short = SHORT_LABEL[col_idx]
        for kind, payload, color in TRIGGER_RULES[col_idx]:
            if kind == "eq":
                value = payload
            elif kind == "nonempty":
                value = "<любая непустая запись>"
            elif kind == "prefix" and payload == "CVE-":
                value = f"{payload}YYYY-NNNNN"
            elif kind == "prefix" and payload == DUPLICATE_PREFIX:
                value = f"{payload}<название падения>"
            elif kind == "prefix":
                value = f"{payload}..."
            else:
                value = "<условие>"
            rows_stream.append((short, value, color))

    for k, (short, value, color) in enumerate(rows_stream, start=1):
        zebra = "dark" if (k % 2 == 0) else "light"
        zname = f"zebra_{zebra}"
        note = LEGEND_NOTES.get((short, value), "")
        tr = TableRow()
        tr.addElement(_txt_cell(f"COL_{color}",  value))
        tr.addElement(_txt_cell(f"COLC_{color}", ""))
        tr.addElement(_txt_cell(f"COLC_{zname}", short))
        tr.addElement(_spanned_cell(f"COL_{zname}", note, n_cols - 3))
        for _ in range(n_cols - 4):
            tr.addElement(CoveredTableCell())
        table.addElement(tr)


# ---------------------------------------------------------------------------
# calcext:conditional-formats injection
# ---------------------------------------------------------------------------
# LibreOffice Calc does not honor the standardized style:map approach for
# cell-level conditional formatting — it silently drops style:map on save.
# The only mechanism it reliably reads back is its own extension element
# <calcext:conditional-formats>, which lives at the end of <table:table>.
# We let odfpy write the file, then patch content.xml in place.
def inject_conditional_formats(ods_path: str,
                               first_row: int, last_row: int) -> None:
    with zipfile.ZipFile(ods_path, "r") as z:
        content = z.read("content.xml").decode("utf-8")
        other = {name: z.read(name) for name in z.namelist()
                 if name != "content.xml"}

    if 'xmlns:calcext' not in content:
        content = content.replace(
            '<office:document-content',
            '<office:document-content '
            'xmlns:calcext="urn:org:documentfoundation:names:experimental:'
            'calc:xmlns:calcext:1.0"',
            1,
        )

    cf_xml = _build_calcext_xml(first_row, last_row)
    content = content.replace("</table:table>", cf_xml + "</table:table>", 1)

    with zipfile.ZipFile(ods_path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("content.xml", content.encode("utf-8"))
        for name, data in other.items():
            z.writestr(name, data)


def _build_calcext_xml(first_row: int, last_row: int) -> str:
    parts: List[str] = ["<calcext:conditional-formats>"]
    for col_idx in sorted(TRIGGER_RULES.keys()):
        col = _col_letter(col_idx)
        rng = f"{SHEET_NAME}.{col}{first_row}:{SHEET_NAME}.{col}{last_row}"
        base = f"{SHEET_NAME}.{col}{first_row}"
        parts.append(
            f'<calcext:conditional-format calcext:target-range-address="{rng}">'
        )
        prefix = "COLC_" if col_idx in CENTERED_COLS else "COL_"
        for kind, payload, color in TRIGGER_RULES[col_idx]:
            target = f"{prefix}{color}"
            if kind == "eq":
                cond = f'="{payload}"'
            elif kind == "nonempty":
                # ODF formulas use ';' as the argument separator.
                cond = f'formula-is(LEN(TRIM({col}{first_row}))&gt;0)'
            elif kind == "prefix":
                cond = (f'formula-is(LEFT(TRIM({col}{first_row});'
                        f'{len(payload)})="{payload}")')
            else:
                continue
            parts.append(
                f'<calcext:condition '
                f'calcext:apply-style-name="{target}" '
                f'calcext:value=\'{cond}\' '
                f'calcext:base-cell-address="{base}"/>'
            )
        parts.append('</calcext:conditional-format>')
    parts.append("</calcext:conditional-formats>")
    return "".join(parts)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(
        description="Generate an ODS draft of the crash analysis table "
                    "from the syz-manager main HTML page.")
    ap.add_argument("-u", "--url", default=DEFAULT_URL,
                    help=f"syz-manager URL (default: {DEFAULT_URL}). "
                         "Use port 12085 when running on the host outside "
                         "the alt-syz-box container.")
    ap.add_argument("-i", "--input", default=None,
                    help="parse a saved HTML file instead of fetching by URL")
    ap.add_argument("-o", "--output", default=DEFAULT_OUT,
                    help=f"output .ods path (default: {DEFAULT_OUT})")
    args = ap.parse_args()

    if args.input:
        with open(args.input, "r", encoding="utf-8", errors="replace") as f:
            html = f.read()
        src = args.input
    else:
        try:
            html = fetch_html(args.url)
        except Exception as e:
            sys.stderr.write(f"ERROR: failed to fetch {args.url}: {e}\n")
            return 1
        src = args.url

    rows = parse_crashes(html)
    build_ods(rows, args.output)
    print(f"OK: parsed {len(rows)} crash(es); saved to {args.output} "
          f"(source: {src}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())

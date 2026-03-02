#!/usr/bin/env python3
"""Convert kernel CSV Name values to name-only form without collapsing rows.

This is intended for CSVs generated from `cuda_gpu_kern_sum`, where rows are
already summarized and no extra merge-by-name step is needed.
"""

import argparse
import csv
import os
import re
import subprocess
from typing import Dict, List


MANGLED_RE = re.compile(r"^_Z[\w\d_]*$")


def _maybe_demangle_batch(names: List[str]) -> Dict[str, str]:
    """Demangle Itanium C++ symbols in batch via c++filt when available."""
    mangled = sorted({n for n in names if MANGLED_RE.match((n or "").strip())})
    if not mangled:
        return {}

    try:
        proc = subprocess.run(
            ["c++filt"],
            input="".join(n.rstrip("\n") + "\n" for n in mangled),
            text=True,
            capture_output=True,
            check=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return {}

    out_lines = proc.stdout.splitlines()
    if len(out_lines) != len(mangled):
        return {}

    return dict(zip(mangled, out_lines))


def _strip_outermost_template_suffix(s: str) -> str:
    s = s.rstrip()
    if not s.endswith(">"):
        return s

    depth = 0
    for i in range(len(s) - 1, -1, -1):
        c = s[i]
        if c == ">":
            depth += 1
        elif c == "<":
            depth -= 1
            if depth == 0:
                return s[:i].rstrip()
    return s


def _strip_outermost_arglist_suffix(s: str) -> str:
    s = s.rstrip()
    if not s.endswith(")"):
        return s

    depth = 0
    for i in range(len(s) - 1, -1, -1):
        c = s[i]
        if c == ")":
            depth += 1
        elif c == "(":
            depth -= 1
            if depth == 0:
                return s[:i].rstrip()
    return s


def name_only(raw: str) -> str:
    """Convert a demangled C++/CUDA kernel symbol to only the identifier."""
    s = (raw or "").strip()

    s = _strip_outermost_arglist_suffix(s)
    s = _strip_outermost_template_suffix(s)

    if "::" in s:
        s = s.split("::")[-1]

    s = s.strip()
    if " " in s:
        s = s.split()[-1]

    return s


def _idx(header: List[str], col: str) -> int:
    try:
        return header.index(col)
    except ValueError:
        stripped = [h.strip() for h in header]
        return stripped.index(col.strip())


def convert_names_only(in_path: str, out_path: str) -> str:
    with open(in_path, "r", newline="") as f:
        reader = csv.reader(f)
        rows = list(reader)

    if not rows:
        raise SystemExit("Input CSV is empty.")

    header = rows[0]
    if not header:
        raise SystemExit("CSV header row is empty.")

    name_i = _idx(header, "Name")

    all_names = [r[name_i] for r in rows[1:] if len(r) > name_i]
    demangled_map = _maybe_demangle_batch(all_names)

    out_rows: List[List[str]] = [header[:]]
    for r in rows[1:]:
        if len(r) <= name_i:
            out_rows.append(r)
            continue

        original_name = r[name_i]
        demangled = demangled_map.get(original_name, original_name)

        r2 = r[:]
        r2[name_i] = name_only(demangled)
        out_rows.append(r2)

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerows(out_rows)

    return out_path


def main() -> int:
    ap = argparse.ArgumentParser(
        description=(
            "Rewrite Name to demangled name-only form for cuda_gpu_kern_sum CSVs "
            "(no merge/collapse)."
        )
    )
    ap.add_argument("input_csv", help="Input CSV path")
    ap.add_argument(
        "-o",
        "--output",
        dest="output_csv",
        help="Output CSV path (default: <input>.name_only.csv)",
    )
    args = ap.parse_args()

    in_path = args.input_csv
    out_path = args.output_csv or (in_path + ".name_only.csv")

    out = convert_names_only(in_path, out_path)
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

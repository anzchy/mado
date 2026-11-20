# -*- coding: utf-8 -*-
"""#733: deterministic three-way merge of allowlisted Markdown table rows by row key (the first cell).

No union and no ours/theirs: each cell takes the side that changed it. It stops (Manual) when one cell changed on both
sides, a row was deleted, a key appears twice, the same new key was added with different text, both sides reordered
existing rows differently, or lines outside the allowlisted tables changed on both sides. Lines outside the tables
(the frame) changed on one side only take that side. Row order is main's unless only the branch reordered rows. `ours` is main's side, `theirs` the branch's side.

  doc_rows.py --paths    print the allowlisted paths, one per line
"""
import re
import sys
from pathlib import Path

ALLOWLIST = Path(__file__).with_name("rebase-docs-allowlist.txt")
# The allowlist's path in the repository; rebase-verify reads it from the new base (main), so a branch's own edit
# cannot govern its own verification. The copy next to this script is used only when the base has none.
ALLOWLIST_REPO_PATH = ".agents/skills/mado-delegator/scripts/rebase-docs-allowlist.txt"
_SLOT = "\x00table\x00"
_PIPE = re.compile(r"(?<!\\)\|")


class Manual(Exception):
    """The rows cannot be merged mechanically; a human resolves them."""


def load_allowlist(path=ALLOWLIST, text=None):
    entries = {}
    for line in (path.read_text(encoding="utf-8") if text is None else text).splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        name, tab, header = line.partition("\t")
        if not tab or not name.strip() or not header.strip():
            raise ValueError(f"bad allowlist line: {line!r}")
        entries.setdefault(name.strip(), []).append(header.strip())
    return entries


def _cells(line):
    """Raw cells between the outer pipes; escaped pipes (\\|) stay inside a cell."""
    return _PIPE.split(line)


def row_key(line):
    parts = _cells(line)
    return parts[1].strip() if len(parts) > 2 else line.strip()


def _separator(line):
    parts = [c.strip() for c in _cells(line)[1:-1]]
    return bool(parts) and all(re.fullmatch(r":?-{3,}:?", c) for c in parts)


def split(text, headers):
    """(frame, tables): the lines outside the allowlisted tables' rows, with one slot per table, and each table's rows."""
    lines, frame, tables, i = text.split("\n"), [], [], 0
    while i < len(lines):
        if lines[i].strip() in headers and i + 1 < len(lines) and _separator(lines[i + 1]):
            frame += [lines[i], lines[i + 1], _SLOT]
            j = i + 2
            while j < len(lines) and lines[j].startswith("|"):
                j += 1
            tables.append(lines[i + 2:j])
            i = j
        else:
            frame.append(lines[i])
            i += 1
    return frame, tables


def _keyed(rows, side):
    out = {}
    for line in rows:
        key = row_key(line)
        if key in out:
            raise Manual(f"duplicate key {key!r} on {side}")
        out[key] = line
    return out


def _merge_row(key, base, ours, theirs):
    if ours == theirs or theirs == base:
        return ours
    if ours == base:
        return theirs
    b, o, t = _cells(base), _cells(ours), _cells(theirs)
    if not len(b) == len(o) == len(t):
        raise Manual(f"row {key!r}: cell count differs")
    merged = []
    for i, (bc, oc, tc) in enumerate(zip(b, o, t)):
        if oc == tc or tc == bc:
            merged.append(oc)
        elif oc == bc:
            merged.append(tc)
        else:
            raise Manual(f"row {key!r}: same cell {i} changed on both sides")
    return "|".join(merged)


def merge_rows(base, ours, theirs):
    b, o, t = _keyed(base, "base"), _keyed(ours, "main"), _keyed(theirs, "the branch")
    for key in b:
        if key not in o or key not in t:
            raise Manual(f"row {key!r} deleted on {'main' if key not in o else 'the branch'}")
    merged = {}
    for key, line in o.items():
        if key in b:
            merged[key] = _merge_row(key, b[key], line, t[key])
        elif key in t and t[key] != line:
            raise Manual(f"row {key!r} added on both sides with different text")
        else:
            merged[key] = line
    for key, line in t.items():
        merged.setdefault(key, line)
    # Row order: main's, unless only the branch reordered the rows both sides share with base; both reordering
    # differently stops. The other side's new rows go right before their next row in that side's order, or at the end.
    base_order, main_order, branch_order = list(b), [k for k in o if k in b], [k for k in t if k in b]
    if branch_order == base_order or branch_order == main_order:
        primary, secondary = list(o), list(t)
    elif main_order == base_order:
        primary, secondary = list(t), list(o)
    else:
        raise Manual("row order changed differently on both sides")
    order = primary
    for index, key in enumerate(secondary):
        if key in order:
            continue
        following = next((k for k in secondary[index + 1:] if k in order), None)
        order.insert(order.index(following) if following else len(order), key)
    return [merged[key] for key in order]


def merge(base, ours, theirs, headers):
    (fb, tb), (fo, to), (ft, tt) = (split(x, headers) for x in (base, ours, theirs))
    if not len(tb) == len(to) == len(tt):
        raise Manual("the allowlisted table is missing on one side")
    if fo == ft or ft == fb:
        frame = fo
    elif fo == fb:
        frame = ft
    else:
        raise Manual("lines outside the table changed on both sides")
    tables = iter(merge_rows(*rows) for rows in zip(tb, to, tt))
    out = []
    for line in frame:
        out.extend(next(tables) if line == _SLOT else [line])
    return "\n".join(out)


if __name__ == "__main__":
    if sys.argv[1:] == ["--paths"]:
        print("\n".join(load_allowlist()))
        sys.exit(0)
    print("usage: doc_rows.py --paths", file=sys.stderr)
    sys.exit(2)

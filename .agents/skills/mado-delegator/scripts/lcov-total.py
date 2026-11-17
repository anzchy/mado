#!/usr/bin/env python3
"""lcov-total.py <lcov.info> — sum line and function coverage and enforce 100%.

Prints `lines LH/LF functions FNH/FNF` and, on a gap, each uncovered `<file>:<line>`.
Exit 0 at 100%, 1 below it, 2 when the report is missing or empty (no evidence).
"""
import sys


def main(path):
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as e:
        print(f"no report: {e}")
        return 2
    totals = {"LF": 0, "LH": 0, "FNF": 0, "FNH": 0}
    uncovered, source = [], None
    for line in text.splitlines():
        key, _, value = line.partition(":")
        if key == "SF":
            source = value
        elif key in totals:
            totals[key] += int(value)
        elif key == "DA" and value.split(",")[1] == "0":
            uncovered.append(f"{source}:{value.split(',')[0]}")
    if totals["LF"] == 0:
        print("empty report")
        return 2
    print(f"lines {totals['LH']}/{totals['LF']} functions {totals['FNH']}/{totals['FNF']}")
    for item in uncovered:
        print(f"uncovered {item}")
    return 0 if totals["LH"] == totals["LF"] and totals["FNH"] == totals["FNF"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]) if len(sys.argv) == 2 else 2)

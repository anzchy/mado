# -*- coding: utf-8 -*-
# Resolve ledger conflicts limited to Part 3 area-review rows against the merge base (stage 1):
# keep HEAD's (main's) row, and when the branch's 备注 is the base's 备注 plus a suffix, append that suffix verbatim
# (spaces and repeated stock sentences such as 「这次没有检查真机。」 included). The newer 最近审查 date wins, with its
# 审查人. A branch that edited base text, a row with no base, or rows whose cell counts differ stay UNRESOLVED:
# nothing is dropped silently. A row only one side has is kept as is. Line endings are preserved.
# Prints 'ok', or 'UNRESOLVED' and leaves those conflict blocks in place.
import subprocess
import sys

LEDGER = 'docs/feature-ledger.md'


def cells(line):
    return [c.strip() for c in line.strip().strip('|').split('|')]


def key(line):
    return cells(line)[0]


def merge_row(head, theirs, base):
    if head == theirs:
        return head
    if base is None:
        return None
    h, t, b = cells(head), cells(theirs), cells(base)
    if not len(h) == len(t) == len(b) or len(h) < 4 or not t[-1].startswith(b[-1]):
        return None
    suffix = t[-1][len(b[-1]):]
    note = h[-1]
    if suffix.strip() and not (note.startswith(b[-1]) and suffix in note[len(b[-1]):]):
        note += suffix
    date, reviewer = (t[1], t[2]) if t[1] > h[1] else (h[1], h[2])
    return '| ' + ' | '.join([h[0], date, reviewer] + h[3:-1] + [note]) + ' |'


def merge_block(head, theirs, base_rows):
    if any(not l.startswith('| ') for l in head + theirs if l.strip()):
        return None
    rows = lambda ls: [l for l in ls if l.startswith('| ')]
    tk = {key(l): l for l in rows(theirs)}
    hk = [key(l) for l in rows(head)]
    out = []
    for l in rows(head):
        merged = merge_row(l, tk[key(l)], base_rows.get(key(l))) if key(l) in tk else l
        if merged is None:
            return None
        out.append(merged)
    return out + [l for l in rows(theirs) if key(l) not in hk]


def resolve(text, base=None):
    nl = '\r\n' if '\r\n' in text else '\n'
    base_rows = {key(l): l for l in (base or '').splitlines() if l.startswith('| ')}
    s = text.split(nl)
    if s and s[-1] == '':
        s.pop()
    out = []; i = 0; ok = True
    while i < len(s):
        if s[i].startswith('<<<<<<<'):
            j = s.index('=======', i)
            k = next(n for n in range(j, len(s)) if s[n].startswith('>>>>>>>'))
            merged = merge_block(s[i + 1:j], s[j + 1:k], base_rows)
            if merged is None:
                ok = False; out += s[i:k + 1]
            else:
                out += merged
            i = k + 1; continue
        out.append(s[i]); i += 1
    return nl.join(out) + nl, ok


if __name__ == '__main__':
    p = sys.argv[1] if len(sys.argv) > 1 else LEDGER
    base = subprocess.run(['git', 'show', f':1:{LEDGER}'], capture_output=True, text=True).stdout or None
    with open(p, newline='') as f:
        text, ok = resolve(f.read(), base)
    with open(p, 'w', newline='') as f:
        f.write(text)
    print('ok' if ok else 'UNRESOLVED')

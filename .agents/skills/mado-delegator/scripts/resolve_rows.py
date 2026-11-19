# -*- coding: utf-8 -*-
# Three-way merge of docs/feature-ledger.md by table row key. ours = main side (stage 2), theirs = commit (stage 3).
import subprocess, sys, re
def stage(n): return subprocess.run(['git','show',f':{n}:docs/feature-ledger.md'],capture_output=True,text=True,check=True).stdout.split('\n')
base, ours, theirs = stage(1), stage(2), stage(3)
def key(l):
    m = re.match(r'\| ([A-Z0-9][A-Za-z0-9\-·]*(?: [^|]*)?) \|', l)
    return m.group(1) if l.startswith('| ') and m else None
def index(lines): return {key(l): l for l in lines if key(l)}
def clause_suffix(suffix): return suffix.startswith(('。', '；', '限制：'))
B, T = index(base), index(theirs)
# non-row lines must agree between base and theirs
nb = [l for l in base if not key(l)]; nt = [l for l in theirs if not key(l)]
if nb != nt: print('non-row change in commit; manual'); sys.exit(2)
if set(B) != set(T): print('row added/removed in commit; manual', set(T)^set(B)); sys.exit(2)
out = []
for l in ours:
    k = key(l)
    if k and k in T and T[k] != B.get(k):
        b, t = B[k], T[k]
        bc, oc, tc = b.split('|'), l.split('|'), t.split('|')
        if len(bc) != len(oc) or len(bc) != len(tc):
            print('manual row', k, 'cell count differs'); sys.exit(3)
        merged = []
        for i, (base_cell, ours_cell, theirs_cell) in enumerate(zip(bc, oc, tc)):
            if ours_cell == theirs_cell or theirs_cell == base_cell:
                merged.append(ours_cell)
            elif ours_cell == base_cell:
                merged.append(theirs_cell)
            else:
                base_prefix = base_cell.rstrip()
                theirs_suffix = theirs_cell[len(base_prefix):] if base_prefix and theirs_cell.startswith(base_prefix) else ''
                ours_suffix = ours_cell[len(base_prefix):] if base_prefix and ours_cell.startswith(base_prefix) else ''
                if clause_suffix(theirs_suffix):
                    merged.append(ours_cell.rstrip() + theirs_suffix)
                    continue
                if clause_suffix(ours_suffix):
                    merged.append(theirs_cell.rstrip() + ours_suffix)
                    continue
                print('manual row', k, 'cell', i)
                print(' base cell', repr(base_cell))
                print(' ours cell', repr(ours_cell))
                print(' theirs cell', repr(theirs_cell))
                sys.exit(3)
        l = '|'.join(merged)
    out.append(l)
open('docs/feature-ledger.md','w').write('\n'.join(out))
print('resolved')

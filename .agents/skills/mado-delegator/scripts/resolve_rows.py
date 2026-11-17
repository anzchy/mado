# -*- coding: utf-8 -*-
# Three-way merge of docs/feature-ledger.md by table row key. ours = main side (stage 2), theirs = commit (stage 3).
import subprocess, sys, re
def stage(n): return subprocess.run(['git','show',f':{n}:docs/feature-ledger.md'],capture_output=True,text=True,check=True).stdout.split('\n')
base, ours, theirs = stage(1), stage(2), stage(3)
def key(l):
    m = re.match(r'\| ([A-Z0-9][A-Za-z0-9\-·]*(?: [^|]*)?) \|', l)
    return m.group(1) if l.startswith('| ') and m else None
def index(lines): return {key(l): l for l in lines if key(l)}
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
        if l == b: l = t
        elif t.startswith(b.rstrip(' |')) and t.endswith(' |'):
            suffix = t[len(b.rstrip(' |')):-2]
            l = l.rstrip(' |') + suffix + ' |'
        else:
            print('manual row', k); print(' base ', b); print(' ours ', l); print(' theirs', t); sys.exit(3)
    out.append(l)
open('docs/feature-ledger.md','w').write('\n'.join(out))
print('resolved')

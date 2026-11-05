"""Tempos de rollback pelo medidor independente (arquivos rollback-<label>-<n>.versions + rollback.csv).

Para cada rodada, a partir de t0 (comando de rollback):
  primeira_nova_s:  1ª resposta com build diferente do build servido antes de t0
  toda_nova_s:      instante após o qual nenhuma resposta veio da versão antiga (nem com erro)
  erros:            consultas sem resposta válida entre t0 e o fim da medição
Uso (dentro de experiments/results): python3 ../c3_poller.py [dir] > c3_poller.csv
"""
import csv
import glob
import os
import re
import statistics
import sys
from collections import defaultdict

d = sys.argv[1] if len(sys.argv) > 1 else '.'
t0s = defaultdict(list)
with open(os.path.join(d, 'rollback.csv')) as fh:
    for label, t0, *_ in csv.reader(fh):
        t0s[label].append(float(t0))

rows = []
for path in sorted(glob.glob(os.path.join(d, 'rollback-*.versions'))):
    label, n = re.match(r'rollback-(.+)-(\d+)\.versions$', os.path.basename(path)).groups()
    n = int(n)
    if len(t0s[label]) < n:
        continue
    t0 = t0s[label][n - 1]
    samples = [(float(t), b) for t, b in (line.split() for line in open(path))]
    old = next(b for t, b in reversed(samples) if t < t0 and not b.startswith('ERRO'))
    after = [(t, b) for t, b in samples if t >= t0]
    first_new = next((t for t, b in after if b != old and not b.startswith('ERRO')), None)
    last_not_new = max((t for t, b in after if b == old or b.startswith('ERRO')), default=t0)
    rows.append((label, n, first_new - t0 if first_new else float('nan'), last_not_new - t0,
                 sum(1 for _, b in after if b.startswith('ERRO')), len(after)))

w = csv.writer(sys.stdout)
w.writerow(['metodo', 'rodada', 'primeira_nova_s', 'toda_nova_s', 'erros', 'consultas'])
for r in rows:
    w.writerow([r[0], r[1], f'{r[2]:.2f}', f'{r[3]:.2f}', r[4], r[5]])
by = defaultdict(list)
for r in rows:
    by[r[0]].append(r)
for label, rs in sorted(by.items()):
    for i, name in ((2, 'primeira_nova_s'), (3, 'toda_nova_s')):
        v = [r[i] for r in rs]
        sd = statistics.stdev(v) if len(v) > 1 else 0.0
        print(f'# {label} {name}: {statistics.mean(v):.2f} ± {sd:.2f} (n={len(v)})', file=sys.stderr)

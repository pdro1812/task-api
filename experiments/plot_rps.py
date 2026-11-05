"""Requisições por segundo por status ao longo do tempo para uma rodada do k6.

Faixas sombreadas marcam o intervalo em que o Redis ficou fora (arquivos .fail/.recover).
Uso: python3 experiments/plot_rps.py saida.png experiments/results/redis-<cfg>-<n>.csv [...]
"""
import csv
import os
import sys
from collections import Counter, defaultdict

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

COLORS = {200: '#2a9d8f', 503: '#e9c46a', 0: '#e76f51'}
LABELS = {200: '200', 503: '503', 0: 'sem resposta'}


def load(path):
    per_sec = defaultdict(Counter)
    with open(path, newline='') as fh:
        for row in csv.DictReader(fh):
            if row['metric_name'] != 'http_req_duration':
                continue
            per_sec[int(row['timestamp'])][int(row.get('status') or 0)] += 1
    return per_sec


def marker(path, ext):
    p = path[:-4] + ext
    return float(open(p).read()) if os.path.exists(p) else None


def main(out, paths):
    fig, axes = plt.subplots(len(paths), 1, figsize=(9, 2.4 * len(paths)), sharex=True, squeeze=False)
    for ax, path in zip(axes[:, 0], paths):
        per_sec = load(path)
        t0 = min(per_sec)
        xs = list(range(0, max(per_sec) - t0 + 1))
        statuses = sorted({s for c in per_sec.values() for s in c}, key=lambda s: (s != 200, s))
        for s in statuses:
            ax.plot(xs, [per_sec.get(t0 + x, {}).get(s, 0) for x in xs],
                    color=COLORS.get(s, '#888'), label=LABELS.get(s, str(s)), lw=1.4)
        fail, rec = marker(path, '.fail'), marker(path, '.recover')
        if fail and rec:
            ax.axvspan(fail - t0, rec - t0, color='#999', alpha=0.15, lw=0)
        ax.set_title(os.path.basename(path)[:-4], fontsize=9, loc='left')
        ax.set_ylabel('req/s')
        ax.grid(alpha=0.3)
        ax.legend(fontsize=7, loc='upper right', frameon=False)
    axes[-1, 0].set_xlabel('tempo (s) — faixa cinza: Redis fora')
    fig.tight_layout()
    fig.savefig(out, dpi=150)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2:])

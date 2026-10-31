"""Análise final: tabela média ± desvio por configuração, testes de Mann-Whitney U e gráficos (300 dpi).

Uso: python3 experiments/final_analysis.py experiments/results experiments/results/final
"""
import csv
import glob
import os
import re
import statistics
import sys
from collections import Counter, defaultdict

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from scipy.stats import mannwhitneyu

sys.path.insert(0, os.path.dirname(__file__))
from analyze import summarize  # noqa: E402

METRICS = ['total', 'ok_pct', '503_pct', 'sem_resposta_pct', 'p50_ms', 'p95_ms', 'p99_ms', 'janela_erro_s']
STATUS_COLORS = {200: '#2a9d8f', 503: '#e9c46a', 0: '#e76f51'}
STATUS_LABELS = {200: '200', 503: '503', 0: 'sem resposta'}


def scenario_of(path):
    return re.sub(r'-\d+\.csv$', '', os.path.basename(path))


def load_k6(results):
    runs = defaultdict(list)
    for path in sorted(glob.glob(f'{results}/redis-*.csv') + glob.glob(f'{results}/rolling-*.csv')):
        runs[scenario_of(path)].append((path, summarize(path)))
    return runs


def load_rollback(results):
    by = defaultdict(list)
    with open(f'{results}/rollback.csv') as fh:
        for label, t0, t_cmd, t_rollout, t_served in csv.reader(fh):
            t0 = float(t0)
            by[label].append({'comando_s': float(t_cmd) - t0, 'rollout_s': float(t_rollout) - t0,
                              'servindo_s': float(t_served) - t0})
    return by


def fmt(vals):
    sd = statistics.stdev(vals) if len(vals) > 1 else 0.0
    return f'{statistics.mean(vals):.2f} ± {sd:.2f}'


def mwu(a, b):
    if len(set(a) | set(b)) == 1:
        return float('nan')
    return mannwhitneyu(a, b, alternative='two-sided').pvalue


def per_second(path):
    per_sec = defaultdict(Counter)
    with open(path, newline='') as fh:
        for row in csv.DictReader(fh):
            if row['metric_name'] == 'http_req_duration':
                per_sec[int(row['timestamp'])][int(row.get('status') or 0)] += 1
    return per_sec


def representative(runs):
    """Rodada cuja % de 200 é a mais próxima da mediana da configuração."""
    med = statistics.median(s['ok_pct'] for _, s in runs)
    return min(runs, key=lambda r: abs(r[1]['ok_pct'] - med))[0]


def plot_timeline(out, panels):
    fig, axes = plt.subplots(len(panels), 1, figsize=(8, 2.1 * len(panels)), sharex=True, squeeze=False)
    for ax, (title, path) in zip(axes[:, 0], panels):
        per_sec = per_second(path)
        t0 = min(per_sec)
        xs = list(range(0, max(per_sec) - t0 + 1))
        for s in (200, 503, 0):
            ys = [per_sec.get(t0 + x, {}).get(s, 0) for x in xs]
            if any(ys):
                ax.plot(xs, ys, color=STATUS_COLORS[s], label=STATUS_LABELS[s], lw=1.3)
        fail, rec = (float(open(path[:-4] + ext).read()) - t0 for ext in ('.fail', '.recover'))
        ax.axvspan(fail, rec, color='#999', alpha=0.15, lw=0)
        ax.set_title(f'{title}  ({os.path.basename(path)[:-4]})', fontsize=8, loc='left')
        ax.set_ylabel('req/s', fontsize=8)
        ax.tick_params(labelsize=7)
        ax.grid(alpha=0.3)
        ax.legend(fontsize=7, loc='upper right', frameon=False)
    axes[-1, 0].set_xlabel('tempo desde o início da carga (s) — faixa cinza: Redis indisponível', fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=300)
    plt.close(fig)


def main(results, out):
    os.makedirs(out, exist_ok=True)
    k6 = load_k6(results)
    rb = load_rollback(results)
    vals = {sc: {m: [s[m] for _, s in runs] for m in METRICS} for sc, runs in k6.items()}

    # Tabela por configuração
    with open(f'{out}/tabela.csv', 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['configuracao', 'n'] + [f'{m}_media' for m in METRICS] + [f'{m}_dp' for m in METRICS])
        for sc in sorted(vals):
            v = vals[sc]
            w.writerow([sc, len(v['total'])] + [f'{statistics.mean(v[m]):.3f}' for m in METRICS]
                       + [f'{(statistics.stdev(v[m]) if len(v[m]) > 1 else 0):.3f}' for m in METRICS])
    lines = ['| Configuração | n | % 200 | % 503 | % sem resposta | p95 (ms) | p99 (ms) | janela de erro (s) |',
             '|---|---|---|---|---|---|---|---|']
    for sc in sorted(vals):
        v = vals[sc]
        lines.append(f'| {sc} | {len(v["total"])} | ' + ' | '.join(
            fmt(v[m]) for m in ['ok_pct', '503_pct', 'sem_resposta_pct', 'p95_ms', 'p99_ms', 'janela_erro_s']) + ' |')
    lines += ['', '| Rollback (C3) | n | comando (s) | rollout concluído (s) | versão anterior respondendo (s) |',
              '|---|---|---|---|---|']
    for label in sorted(rb):
        r = rb[label]
        lines.append(f'| {label} | {len(r)} | ' + ' | '.join(
            fmt([x[k] for x in r]) for k in ['comando_s', 'rollout_s', 'servindo_s']) + ' |')
    open(f'{out}/tabela.md', 'w').write('\n'.join(lines) + '\n')

    # Mann-Whitney U (bicaudal)
    pairs = [
        ('redis-baseline-rdfalse', 'redis-failfast-rdfalse'),
        ('redis-baseline-rdtrue', 'redis-failfast-rdtrue'),
        ('redis-failfast-rdfalse', 'redis-breaker-rdfalse'),
        ('redis-failfast-rdtrue', 'redis-breaker-rdtrue'),
        ('redis-baseline-rdfalse', 'redis-baseline-rdtrue'),
        ('redis-failfast-rdfalse', 'redis-failfast-rdtrue'),
        ('redis-breaker-rdfalse', 'redis-breaker-rdtrue'),
        ('redis-failfast-rdfalse-noreuse', 'redis-failfast-rdtrue-noreuse'),
        ('redis-breaker-rdfalse-noreuse', 'redis-breaker-rdtrue-noreuse'),
        ('redis-failfast-rdtrue', 'redis-failfast-rdtrue-noreuse'),
        ('redis-failfast-rdfalse', 'redis-failfast-rdfalse-noreuse'),
        ('rolling-prestop', 'rolling-noprestop'),
    ]
    with open(f'{out}/mann_whitney.csv', 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['a', 'b', 'metrica', 'media_a', 'media_b', 'p_valor'])
        for a, b in pairs:
            if a not in vals or b not in vals:
                continue
            for m in ['ok_pct', '503_pct', 'sem_resposta_pct', 'p99_ms', 'janela_erro_s']:
                w.writerow([a, b, m, f'{statistics.mean(vals[a][m]):.3f}', f'{statistics.mean(vals[b][m]):.3f}',
                            f'{mwu(vals[a][m], vals[b][m]):.2e}'])
        for label in sorted(rb):
            if label == 'imperativo':
                continue
            a = [x['servindo_s'] for x in rb['imperativo']]
            b = [x['servindo_s'] for x in rb[label]]
            w.writerow(['imperativo', label, 'servindo_s', f'{statistics.mean(a):.3f}',
                        f'{statistics.mean(b):.3f}', f'{mwu(a, b):.2e}'])

    # Gráficos
    rep = {sc: representative(runs) for sc, runs in k6.items()}
    plot_timeline(f'{out}/c1_modos_keepalive.png', [
        ('baseline', rep['redis-baseline-rdfalse']),
        ('fail-fast', rep['redis-failfast-rdfalse']),
        ('circuit breaker', rep['redis-breaker-rdfalse']),
    ])
    readiness = [(t, rep[k]) for t, k in [
        ('fail-fast, readiness independente, keep-alive', 'redis-failfast-rdfalse'),
        ('fail-fast, readiness dependente do Redis, keep-alive', 'redis-failfast-rdtrue'),
        ('fail-fast, readiness independente, conexão nova por requisição', 'redis-failfast-rdfalse-noreuse'),
        ('fail-fast, readiness dependente do Redis, conexão nova por requisição', 'redis-failfast-rdtrue-noreuse'),
    ] if k in rep]
    plot_timeline(f'{out}/c1_readiness.png', readiness)

    if 'rolling-prestop' in vals:
        labels = ['com preStop', 'sem preStop']
        keys = ['rolling-prestop', 'rolling-noprestop']
        fig, ax = plt.subplots(figsize=(4.5, 3.2))
        means = [statistics.mean(vals[k]['sem_resposta_pct']) for k in keys]
        sds = [statistics.stdev(vals[k]['sem_resposta_pct']) for k in keys]
        ax.bar(labels, means, yerr=sds, capsize=6, color=['#2a9d8f', '#e76f51'], width=0.55)
        top = max(m + s for m, s in zip(means, sds))
        ax.set_ylim(0, top * 1.25)
        for i, (m, s) in enumerate(zip(means, sds)):
            ax.text(i, m + s + top * 0.03, f'{m:.2f}%', ha='center', fontsize=8)
        ax.set_ylabel('% requisições sem resposta')
        ax.set_title('C2 — rolling update sob carga (média ± dp, n=10)', fontsize=9)
        ax.grid(axis='y', alpha=0.3)
        fig.tight_layout()
        fig.savefig(f'{out}/c2_rolling_update.png', dpi=300)
        plt.close(fig)

    order = [k for k in ['imperativo', 'gitops-refresh', 'gitops-webhook', 'gitops-polling'] if k in rb]
    fig, ax = plt.subplots(figsize=(5.5, 3.4))
    ax.boxplot([[x['servindo_s'] for x in rb[k]] for k in order], tick_labels=order)
    ax.set_ylabel('tempo até a versão anterior responder (s)')
    ax.set_title('C3 — tempo de rollback', fontsize=9)
    ax.grid(axis='y', alpha=0.3)
    fig.tight_layout()
    fig.savefig(f'{out}/c3_rollback.png', dpi=300)
    plt.close(fig)

    with open(f'{out}/rodadas_representativas.txt', 'w') as fh:
        for sc, path in sorted(rep.items()):
            fh.write(f'{sc}: {os.path.basename(path)}\n')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])

"""Análise final: tabela média ± desvio por configuração, testes estatísticos e gráficos (300 dpi).

Todas as medidas de tempo usam o INÍCIO de cada requisição (timestamp do k6 − duração); o k6 registra
o fim, o que atrasa em até o timeout do cliente (5 s) as requisições que expiram. Latências (p50/p95/p99)
usam a iteration_duration, que inclui a fase de conexão (ver requests()).

Estatística: Mann-Whitney U bicaudal, p ajustado por Holm sobre toda a família de testes,
Cliff's δ e IC 95 % por bootstrap (10 000 reamostragens) da diferença de médias (b − a).

Uso: python3 experiments/final_analysis.py experiments/results experiments/results/final-v2
"""
import csv
import glob
import os
import random
import re
import statistics
import sys
from collections import Counter, defaultdict

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from scipy.stats import mannwhitneyu

METRICS = ['total', 'ok_pct', '503_pct', 'sem_resposta_pct', 'p50_ms', 'p95_ms', 'p99_ms', 'janela_erro_s',
           'erro_apos_falha_s', 'recuperacao_s']
STATUS_COLORS = {200: '#2a9d8f', 503: '#e9c46a', 0: '#e76f51'}
STATUS_LABELS = {200: '200', 503: '503', 0: 'sem resposta'}


def percentile(values, p):
    values = sorted(values)
    k = (len(values) - 1) * p / 100
    f = int(k)
    c = min(f + 1, len(values) - 1)
    return values[f] + (values[c] - values[f]) * (k - f)


def requests(path):
    """[(início em s epoch, status, duração em ms)] ordenado pelo início.

    A duração é a iteration_duration (1 requisição por iteração): o http_req_duration do k6 exclui a fase
    de conexão, e uma conexão que nunca se completa (SYN sem resposta) aparece com duração ~0 embora o
    cliente tenha esperado até o timeout.
    """
    statuses, iterations = [], []
    with open(path, newline='') as fh:
        for row in csv.DictReader(fh):
            if row['metric_name'] == 'http_req_duration':
                statuses.append((int(row['timestamp']), int(row.get('status') or 0)))
            elif row['metric_name'] == 'iteration_duration':
                iterations.append((int(row['timestamp']), float(row['metric_value'])))
    assert len(statuses) == len(iterations), path
    out = []
    for (ts, s), (ti, d) in zip(statuses, iterations):
        assert abs(ts - ti) <= 1, (path, ts, ti)
        out.append((ti - d / 1000, s, d))
    return sorted(out)


def marker(path, ext):
    p = path[:-4] + ext
    return float(open(p).read()) if os.path.exists(p) else None


def summarize(path):
    reqs = requests(path)
    n = len(reqs)
    st = Counter(s for _, s, _ in reqs)
    bad = [t for t, s, _ in reqs if s != 200]
    durations = [d for _, _, d in reqs]
    # Evento que provoca a falha: queda do Redis (.fail) ou início do rollout (.deploy)
    event = marker(path, '.fail') or marker(path, '.deploy')
    restore = marker(path, '.recover') or marker(path, '.done')
    return {
        'total': n,
        'ok_pct': 100 * st[200] / n,
        '503_pct': 100 * st[503] / n,
        'sem_resposta_pct': 100 * st[0] / n,
        'p50_ms': percentile(durations, 50),
        'p95_ms': percentile(durations, 95),
        'p99_ms': percentile(durations, 99),
        'janela_erro_s': (max(bad) - min(bad)) if bad else 0.0,
        'erro_apos_falha_s': (min(bad) - event) if bad and event else float('nan'),
        'recuperacao_s': (max(bad) - restore) if bad and restore else float('nan'),
    }


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


def clean(vals):
    return [v for v in vals if v == v]


def fmt(vals):
    vals = clean(vals)
    if not vals:
        return '—'
    sd = statistics.stdev(vals) if len(vals) > 1 else 0.0
    return f'{statistics.mean(vals):.2f} ± {sd:.2f}'


def cliffs_delta(a, b):
    """P(b > a) − P(b < a): +1 quando todo b é maior que todo a."""
    gt = sum(1 for x in a for y in b if y > x)
    lt = sum(1 for x in a for y in b if y < x)
    return (gt - lt) / (len(a) * len(b))


def bootstrap_ci(a, b, reps=10000, seed=42):
    rng = random.Random(seed)
    diffs = sorted(statistics.mean(rng.choices(b, k=len(b))) - statistics.mean(rng.choices(a, k=len(a)))
                   for _ in range(reps))
    return diffs[int(0.025 * reps)], diffs[int(0.975 * reps) - 1]


def holm(pvalues):
    order = sorted(range(len(pvalues)), key=lambda i: pvalues[i])
    adj, running = [0.0] * len(pvalues), 0.0
    for rank, i in enumerate(order):
        running = max(running, min(1.0, (len(pvalues) - rank) * pvalues[i]))
        adj[i] = running
    return adj


def compare(a, b):
    a, b = clean(a), clean(b)
    if not a or not b or len(set(a) | set(b)) == 1:
        return None
    res = mannwhitneyu(a, b, alternative='two-sided')
    lo, hi = bootstrap_ci(a, b)
    return {'U': res.statistic, 'p': res.pvalue, 'delta': cliffs_delta(a, b), 'ic_lo': lo, 'ic_hi': hi}


def per_second(path):
    reqs = requests(path)
    t0 = reqs[0][0]
    per = defaultdict(Counter)
    for t, s, _ in reqs:
        per[int(t - t0)][s] += 1
    return t0, per


def representative(runs):
    """Rodada cuja % de 200 é a mais próxima da mediana da configuração."""
    med = statistics.median(s['ok_pct'] for _, s in runs)
    return min(runs, key=lambda r: abs(r[1]['ok_pct'] - med))[0]


def plot_timeline(out, panels):
    fig, axes = plt.subplots(len(panels), 1, figsize=(8, 2.1 * len(panels)), sharex=True, squeeze=False)
    for ax, (title, path) in zip(axes[:, 0], panels):
        t0, per = per_second(path)
        xs = list(range(0, max(per) + 1))
        for s in (200, 503, 0):
            ys = [per.get(x, {}).get(s, 0) for x in xs]
            if any(ys):
                ax.plot(xs, ys, color=STATUS_COLORS[s], label=STATUS_LABELS[s], lw=1.3)
        fail, rec = marker(path, '.fail') - t0, marker(path, '.recover') - t0
        ax.axvspan(fail, rec, color='#999', alpha=0.15, lw=0)
        ax.set_title(f'{title}  ({os.path.basename(path)[:-4]})', fontsize=8, loc='left')
        ax.set_ylabel('req/s', fontsize=8)
        ax.tick_params(labelsize=7)
        ax.grid(alpha=0.3)
        ax.legend(fontsize=7, loc='upper right', frameon=False)
    axes[-1, 0].set_xlabel('início da requisição desde o início da carga (s) — faixa cinza: Redis indisponível',
                           fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=300)
    plt.close(fig)


PAIRS = [
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
PAIR_METRICS = ['ok_pct', '503_pct', 'sem_resposta_pct', 'p99_ms', 'janela_erro_s', 'recuperacao_s']


def main(results, out):
    os.makedirs(out, exist_ok=True)
    k6 = load_k6(results)
    rb = load_rollback(results)
    vals = {sc: {m: [s[m] for _, s in runs] for m in METRICS} for sc, runs in k6.items()}

    with open(f'{out}/tabela.csv', 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['configuracao', 'n'] + [f'{m}_media' for m in METRICS] + [f'{m}_dp' for m in METRICS])
        for sc in sorted(vals):
            v = {m: clean(vals[sc][m]) for m in METRICS}
            w.writerow([sc, len(v['total'])]
                       + [f'{statistics.mean(v[m]):.3f}' if v[m] else '' for m in METRICS]
                       + [f'{statistics.stdev(v[m]):.3f}' if len(v[m]) > 1 else '' for m in METRICS])
    cols = ['ok_pct', '503_pct', 'sem_resposta_pct', 'p95_ms', 'p99_ms', 'erro_apos_falha_s', 'recuperacao_s',
            'janela_erro_s']
    lines = ['Tempos pelo início da requisição. erro após falha / recuperação: 1ª requisição com erro − queda '
             '(ou início do rollout); última requisição com erro − restauração (ou fim do rollout).', '',
             '| Configuração | n | % 200 | % 503 | % sem resposta | p95 (ms) | p99 (ms) | 1º erro após a falha (s) '
             '| recuperação (s) | janela de erro (s) |',
             '|---|---|---|---|---|---|---|---|---|---|']
    for sc in sorted(vals):
        lines.append(f'| {sc} | {len(vals[sc]["total"])} | ' + ' | '.join(fmt(vals[sc][m]) for m in cols) + ' |')
    lines += ['', '| Rollback (C3) | n | comando (s) | rollout concluído (s) | versão anterior respondendo (s) |',
              '|---|---|---|---|---|']
    for label in sorted(rb):
        r = rb[label]
        lines.append(f'| {label} | {len(r)} | ' + ' | '.join(
            fmt([x[k] for x in r]) for k in ['comando_s', 'rollout_s', 'servindo_s']) + ' |')
    open(f'{out}/tabela.md', 'w').write('\n'.join(lines) + '\n')

    tests = []
    for a, b in PAIRS:
        if a in vals and b in vals:
            for m in PAIR_METRICS:
                tests.append((a, b, m, vals[a][m], vals[b][m]))
    for label in sorted(rb):
        if label != 'imperativo':
            tests.append(('imperativo', label, 'servindo_s', [x['servindo_s'] for x in rb['imperativo']],
                          [x['servindo_s'] for x in rb[label]]))
    rows = [(a, b, m, va, vb, compare(va, vb)) for a, b, m, va, vb in tests]
    valid = [r for r in rows if r[5]]
    for r, p_adj in zip(valid, holm([r[5]['p'] for r in valid])):
        r[5]['p_holm'] = p_adj
    with open(f'{out}/estatistica.csv', 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['a', 'b', 'metrica', 'n_a', 'n_b', 'media_a', 'media_b', 'U', 'p', 'p_holm', 'cliffs_delta',
                    'dif_media_b_menos_a', 'ic95_inf', 'ic95_sup'])
        for a, b, m, va, vb, c in rows:
            va, vb = clean(va), clean(vb)
            if not va or not vb:
                continue
            base = [a, b, m, len(va), len(vb), f'{statistics.mean(va):.3f}', f'{statistics.mean(vb):.3f}']
            if c is None:
                w.writerow(base + ['', '', '', '', f'{statistics.mean(vb) - statistics.mean(va):.3f}', '', ''])
            else:
                w.writerow(base + [f'{c["U"]:.1f}', f'{c["p"]:.2e}', f'{c["p_holm"]:.2e}', f'{c["delta"]:.3f}',
                                   f'{statistics.mean(vb) - statistics.mean(va):.3f}', f'{c["ic_lo"]:.3f}',
                                   f'{c["ic_hi"]:.3f}'])

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
        top = max(m + s for m, s in zip(means, sds))
        ax.set_ylim(0, top * 1.25)
        ax.bar(labels, means, yerr=sds, capsize=6, color=['#2a9d8f', '#e76f51'], width=0.55)
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

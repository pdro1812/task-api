"""Análise da bateria v2 (results/v2): C1, C2, C3 (medidor independente), C4 e C5, mais observabilidade.

Reaproveita final_analysis.py: tempos pelo início da requisição, latência pela iteration_duration, Mann-Whitney U
bicaudal com Holm sobre toda a família, Cliff's δ e IC 95 % por bootstrap da diferença de médias (b − a).
Acrescenta por rodada: iterações descartadas pelo k6 e % de requisições que reutilizaram a conexão antes do evento.

Uso: python3 experiments/analysis_v2.py experiments/results/v2 experiments/results/v2/analise
"""
import csv
import glob
import os
import re
import statistics
import sys
from collections import defaultdict

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

sys.path.insert(0, os.path.dirname(__file__))
import final_analysis as fa  # noqa: E402

K6_METRICS = fa.METRICS + ['descartadas', 'reuso_pct']
ROW_METRICS = ['ok_pct', '503_pct', 'sem_resposta_pct', 'p95_ms', 'p99_ms', 'erro_apos_falha_s', 'recuperacao_s',
               'descartadas', 'reuso_pct']


def k6_extras(path):
    """Iterações descartadas e % de requisições sem conexão nova antes do evento (.fail ou .deploy)."""
    event = fa.marker(path, '.fail') or fa.marker(path, '.deploy') or float('inf')
    dropped, n, new = 0.0, 0, 0
    with open(path, newline='') as fh:
        for row in csv.DictReader(fh):
            m = row['metric_name']
            if m == 'dropped_iterations':
                dropped += float(row['metric_value'])
            elif m == 'http_req_connecting' and int(row['timestamp']) < event:
                n += 1
                new += float(row['metric_value']) > 0
    return {'descartadas': dropped, 'reuso_pct': 100 * (1 - new / n) if n else float('nan')}


def load(results):
    runs = defaultdict(list)
    for pattern in ('redis-*.csv', 'pausa-*.csv', 'rolling-*.csv', 'quebrada-*.csv'):
        for path in sorted(glob.glob(os.path.join(results, pattern))):
            if not os.path.exists(path[:-4] + '.pods'):
                continue  # rodada incompleta
            s = fa.summarize(path)
            s.update(k6_extras(path))
            if os.path.basename(path).startswith('quebrada-'):
                m = {k: fa.marker(path, '.' + k) for k in ('deploy', 'applied', 'detect', 'undo', 'reverted', 'done')}
                d = lambda a, b: m[b] - m[a] if m[a] and m[b] else float('nan')  # noqa: E731
                s.update(aplicada_s=d('deploy', 'applied'), rollback_aplicado_s=d('undo', 'reverted'),
                         estabiliza_s=d('undo', 'done'))
            runs[fa.scenario_of(path)].append((path, s))
    return runs


def load_poller(results):
    """C3 pelo medidor: 1ª resposta e 100 % das respostas na versão anterior, a partir do comando."""
    t0s = defaultdict(list)
    with open(os.path.join(results, 'rollback.csv')) as fh:
        for label, t0, t_cmd, *_ in csv.reader(fh):
            t0s[label].append((float(t0), float(t_cmd)))
    by = defaultdict(list)
    for path in sorted(glob.glob(os.path.join(results, 'rollback-*.versions'))):
        label, n = re.match(r'rollback-(.+)-(\d+)\.versions$', os.path.basename(path)).groups()
        n = int(n)
        if len(t0s[label]) < n:
            continue
        t0, t_cmd = t0s[label][n - 1]
        samples = [(float(t), b) for t, b in (line.split() for line in open(path))]
        old = next(b for t, b in reversed(samples) if t < t0 and not b.startswith('ERRO'))
        after = [(t, b) for t, b in samples if t >= t0]
        first = next(t for t, b in after if b != old and not b.startswith('ERRO'))
        last_not_new = max((t for t, b in after if b == old or b.startswith('ERRO')), default=t0)
        by[label].append({'comando_s': t_cmd - t0, 'primeira_nova_s': first - t0, 'toda_nova_s': last_not_new - t0,
                          'erros': sum(1 for _, b in after if b.startswith('ERRO'))})
    return by


PAIRS = [
    # C1
    ('redis-baseline-rdfalse', 'redis-failfast-rdfalse'), ('redis-failfast-rdfalse', 'redis-breaker-rdfalse'),
    ('redis-baseline-rdfalse', 'redis-baseline-rdtrue'), ('redis-failfast-rdfalse', 'redis-failfast-rdtrue'),
    ('redis-breaker-rdfalse', 'redis-breaker-rdtrue'),
    ('redis-failfast-rdfalse-noreuse', 'redis-failfast-rdtrue-noreuse'),
    ('redis-breaker-rdfalse-noreuse', 'redis-breaker-rdtrue-noreuse'),
    ('redis-failfast-rdtrue', 'redis-failfast-rdtrue-noreuse'),
    # C4
    ('pausa-baseline-rdfalse', 'pausa-breaker-rdfalse'), ('pausa-failfast-rdfalse', 'pausa-breaker-rdfalse'),
    ('pausa-baseline-rdfalse', 'pausa-failfast-rdfalse'),
    # C2
    ('rolling-prestop', 'rolling-noprestop'),
]
PAIR_METRICS = ['ok_pct', '503_pct', 'sem_resposta_pct', 'p99_ms', 'recuperacao_s']


def stats_rows(vals, poller, c5):
    tests = []
    for a, b in PAIRS:
        if a in vals and b in vals:
            for m in PAIR_METRICS:
                tests.append((a, b, m, vals[a][m], vals[b][m]))
    for label in sorted(poller):
        if label != 'imperativo' and 'imperativo' in poller:
            for m in ('primeira_nova_s', 'toda_nova_s'):
                tests.append(('C3 imperativo', f'C3 {label}', m, [x[m] for x in poller['imperativo']],
                              [x[m] for x in poller[label]]))
    if 'quebrada-imperativo' in c5 and 'quebrada-gitops' in c5:
        for m in ('estabiliza_s', 'ok_pct'):
            tests.append(('quebrada-imperativo', 'quebrada-gitops', m, c5['quebrada-imperativo'][m],
                          c5['quebrada-gitops'][m]))
    rows = [(a, b, m, va, vb, fa.compare(va, vb)) for a, b, m, va, vb in tests]
    valid = [r for r in rows if r[5]]
    for r, p_adj in zip(valid, fa.holm([r[5]['p'] for r in valid])):
        r[5]['p_holm'] = p_adj
    return rows


def plot_spans(out, panels, spans):
    """Linha do tempo req/s por status; spans = [(marca_inicio, marca_fim, cor, rótulo)]."""
    fig, axes = plt.subplots(len(panels), 1, figsize=(8, 2.1 * len(panels)), sharex=True, squeeze=False)
    for ax, (title, path) in zip(axes[:, 0], panels):
        t0, per = fa.per_second(path)
        xs = list(range(0, max(per) + 1))
        for s in (200, 503, 0):
            ys = [per.get(x, {}).get(s, 0) for x in xs]
            if any(ys):
                ax.plot(xs, ys, color=fa.STATUS_COLORS[s], label=fa.STATUS_LABELS[s], lw=1.3)
        for a, b, color, label in spans:
            ta, tb = fa.marker(path, a), fa.marker(path, b)
            if ta and tb:
                ax.axvspan(ta - t0, tb - t0, color=color, alpha=0.15, lw=0, label=label)
        ax.set_title(f'{title}  ({os.path.basename(path)[:-4]})', fontsize=8, loc='left')
        ax.set_ylabel('req/s', fontsize=8)
        ax.tick_params(labelsize=7)
        ax.grid(alpha=0.3)
        ax.legend(fontsize=7, loc='upper right', frameon=False)
    axes[-1, 0].set_xlabel('início da requisição desde o início da carga (s)', fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=300)
    plt.close(fig)


def plot_observability(out, path):
    """C4 breaker: redis_up e circuit_breaker_open por Pod (/metrics) e taxa de 503 por Pod (http_requests_total)."""
    t0, per = fa.per_second(path)
    fail, rec = fa.marker(path, '.fail') - t0, fa.marker(path, '.recover') - t0
    gauges = defaultdict(list)  # (métrica, ip) -> [(t, v)]
    counters = defaultdict(list)  # ip -> [(t, total 503 em /tasks)]
    acc = defaultdict(float)
    last_t = None
    for line in open(path[:-4] + '.metrics'):
        t, ip, name, value = line.split(' ', 3)
        t = float(t) - t0
        if name in ('redis_up', 'circuit_breaker_open'):
            gauges[(name, ip)].append((t, float(value)))
        elif name.startswith('http_requests_total') and 'route="/tasks"' in name and 'status="503"' in name:
            counters[ip].append((t, float(value)))
    fig, axes = plt.subplots(3, 1, figsize=(8, 5.6), sharex=True)
    ips = sorted({ip for _, ip in gauges})
    for k, ip in enumerate(ips):
        for ax, name in zip(axes[:2], ('redis_up', 'circuit_breaker_open')):
            pts = gauges[(name, ip)]
            ax.step([p[0] for p in pts], [p[1] + 0.04 * k for p in pts], where='post', lw=1.2, label=f'Pod {k + 1}')
    for k, ip in enumerate(sorted(counters)):
        pts = counters[ip]
        rate = [(b[0], (b[1] - a[1]) / (b[0] - a[0])) for a, b in zip(pts, pts[1:]) if b[0] > a[0]]
        axes[2].plot([r[0] for r in rate], [r[1] for r in rate], lw=1.2, label=f'Pod {k + 1}')
    titles = ['redis_up (visto pela API)', 'circuit_breaker_open', '503 em /tasks por segundo (http_requests_total)']
    for ax, title in zip(axes, titles):
        ax.axvspan(fail, rec, color='#999', alpha=0.15, lw=0)
        ax.set_title(title, fontsize=8, loc='left')
        ax.tick_params(labelsize=7)
        ax.grid(alpha=0.3)
        ax.legend(fontsize=7, loc='upper right', frameon=False)
    axes[0].set_ylim(-0.1, 1.2)
    axes[1].set_ylim(-0.1, 1.2)
    axes[2].set_xlabel(f'tempo desde o início da carga (s) — faixa cinza: Redis pendurado ({os.path.basename(path)[:-4]})',
                       fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=300)
    plt.close(fig)


def main(results, out):
    os.makedirs(out, exist_ok=True)
    runs = load(results)
    poller = load_poller(results)
    vals = {sc: {m: [s.get(m, float('nan')) for _, s in r] for m in K6_METRICS + ['aplicada_s', 'rollback_aplicado_s', 'estabiliza_s']}
            for sc, r in runs.items()}
    c5 = {sc: v for sc, v in vals.items() if sc.startswith('quebrada-')}

    lines = ['Tempos pelo início da requisição; latência pela iteration_duration. 1º erro / recuperação: em relação à '
             'falha e à restauração (C1, C4) ou ao início e fim do rollout (C2). reuso: % de requisições que '
             'reutilizaram a conexão antes do evento.', '',
             '| Configuração | n | % 200 | % 503 | % sem resposta | p95 (ms) | p99 (ms) | 1º erro (s) | recuperação (s) '
             '| descartadas | reuso (%) |', '|---|---|---|---|---|---|---|---|---|---|---|']
    for sc in sorted(vals):
        lines.append(f'| {sc} | {len(vals[sc]["total"])} | ' + ' | '.join(fa.fmt(vals[sc][m]) for m in ROW_METRICS) + ' |')
    lines += ['', '| C3 (medidor a 100 ms) | n | comando (s) | 1ª resposta da versão anterior (s) | 100 % na versão anterior (s) | erros |',
              '|---|---|---|---|---|---|']
    for label in sorted(poller):
        r = poller[label]
        lines.append(f'| {label} | {len(r)} | ' + ' | '.join(fa.fmt([x[k] for x in r]) for k in
                     ('comando_s', 'primeira_nova_s', 'toda_nova_s')) + f' | {sum(x["erros"] for x in r)} |')
    lines += ['', '| C5 (versão quebrada) | n | versão quebrada aplicada (s) | rollback aplicado (s) | rollback → estável (s) | % 200 | % sem resposta |',
              '|---|---|---|---|---|---|---|']
    for sc in sorted(c5):
        v = c5[sc]
        lines.append(f'| {sc} | {len(v["total"])} | ' + ' | '.join(fa.fmt(v[m]) for m in
                     ('aplicada_s', 'rollback_aplicado_s', 'estabiliza_s', 'ok_pct', 'sem_resposta_pct')) + ' |')
    open(os.path.join(out, 'tabela.md'), 'w').write('\n'.join(lines) + '\n')

    with open(os.path.join(out, 'estatistica.csv'), 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['a', 'b', 'metrica', 'n_a', 'n_b', 'media_a', 'media_b', 'U', 'p', 'p_holm', 'cliffs_delta',
                    'dif_media_b_menos_a', 'ic95_inf', 'ic95_sup'])
        for a, b, m, va, vb, c in stats_rows(vals, poller, c5):
            va, vb = fa.clean(va), fa.clean(vb)
            if not va or not vb:
                continue
            base = [a, b, m, len(va), len(vb), f'{statistics.mean(va):.3f}', f'{statistics.mean(vb):.3f}']
            diff = f'{statistics.mean(vb) - statistics.mean(va):.3f}'
            w.writerow(base + ([f'{c["U"]:.1f}', f'{c["p"]:.2e}', f'{c["p_holm"]:.2e}', f'{c["delta"]:.3f}', diff,
                                f'{c["ic_lo"]:.3f}', f'{c["ic_hi"]:.3f}'] if c else ['', '', '', '', diff, '', '']))

    rep = {sc: fa.representative(r) for sc, r in runs.items()}
    outage = [('.fail', '.recover', '#999', 'Redis fora')]
    pause = [('.fail', '.recover', '#999', 'Redis pendurado')]
    has = lambda *ks: all(k in rep for k in ks)  # noqa: E731
    if has('redis-baseline-rdfalse', 'redis-failfast-rdfalse', 'redis-breaker-rdfalse'):
        plot_spans(os.path.join(out, 'c1_modos.png'), [('baseline', rep['redis-baseline-rdfalse']),
                   ('fail-fast', rep['redis-failfast-rdfalse']), ('circuit breaker', rep['redis-breaker-rdfalse'])], outage)
    readiness = [(t, rep[k]) for t, k in [
        ('fail-fast, readiness independente, keep-alive', 'redis-failfast-rdfalse'),
        ('fail-fast, readiness dependente do Redis, keep-alive', 'redis-failfast-rdtrue'),
        ('fail-fast, readiness independente, conexão nova por requisição', 'redis-failfast-rdfalse-noreuse'),
        ('fail-fast, readiness dependente do Redis, conexão nova por requisição', 'redis-failfast-rdtrue-noreuse'),
    ] if k in rep]
    if readiness:
        plot_spans(os.path.join(out, 'c1_readiness.png'), readiness, outage)
    if has('pausa-baseline-rdfalse', 'pausa-failfast-rdfalse', 'pausa-breaker-rdfalse'):
        plot_spans(os.path.join(out, 'c4_redis_pendurado.png'), [('baseline', rep['pausa-baseline-rdfalse']),
                   ('fail-fast', rep['pausa-failfast-rdfalse']), ('circuit breaker', rep['pausa-breaker-rdfalse'])], pause)
        plot_observability(os.path.join(out, 'c4_observabilidade_breaker.png'), rep['pausa-breaker-rdfalse'])
    if has('rolling-prestop', 'rolling-noprestop'):
        keys, labels = ['rolling-prestop', 'rolling-noprestop'], ['com preStop', 'sem preStop']
        means = [statistics.mean(vals[k]['sem_resposta_pct']) for k in keys]
        sds = [statistics.stdev(vals[k]['sem_resposta_pct']) if len(vals[k]['sem_resposta_pct']) > 1 else 0.0
               for k in keys]
        top = max(m + s for m, s in zip(means, sds)) or 1
        fig, ax = plt.subplots(figsize=(4.5, 3.2))
        ax.bar(labels, means, yerr=sds, capsize=6, color=['#2a9d8f', '#e76f51'], width=0.55)
        ax.set_ylim(0, top * 1.25)
        for i, (m, s) in enumerate(zip(means, sds)):
            ax.text(i, m + s + top * 0.03, f'{m:.2f}%', ha='center', fontsize=8)
        ax.set_ylabel('% requisições sem resposta')
        ax.set_title(f'C2 — rolling update sob carga (média ± dp, n={len(vals[keys[0]]["total"])})', fontsize=9)
        ax.grid(axis='y', alpha=0.3)
        fig.tight_layout()
        fig.savefig(os.path.join(out, 'c2_rolling_update.png'), dpi=300)
        plt.close(fig)
    order = [k for k in ('imperativo', 'gitops-webhook', 'gitops-refresh', 'gitops-polling') if k in poller]
    if order:
        fig, axes = plt.subplots(1, 2, figsize=(8, 3.4), gridspec_kw={'width_ratios': [3, 1]})
        fast = [k for k in order if k != 'gitops-polling']
        for ax, keys in ((axes[0], fast), (axes[1], [k for k in order if k == 'gitops-polling'])):
            if not keys:
                ax.axis('off')
                continue
            data = [[x['toda_nova_s'] for x in poller[k]] for k in keys]
            ax.boxplot(data, tick_labels=keys)
            ax.set_ylabel('até 100 % das respostas na versão anterior (s)', fontsize=8)
            ax.tick_params(labelsize=7)
            ax.grid(axis='y', alpha=0.3)
        fig.suptitle('C3 — tempo de rollback (medidor independente, /version a cada 100 ms)', fontsize=9)
        fig.tight_layout()
        fig.savefig(os.path.join(out, 'c3_rollback.png'), dpi=300)
        plt.close(fig)
    if has('quebrada-imperativo', 'quebrada-gitops'):
        plot_spans(os.path.join(out, 'c5_versao_quebrada.png'),
                   [('rollback imperativo', rep['quebrada-imperativo']), ('rollback GitOps', rep['quebrada-gitops'])],
                   [('.applied', '.detect', '#e9c46a', 'versão quebrada aplicada'),
                    ('.undo', '.done', '#2a9d8f', 'rollback até estabilizar')])
    with open(os.path.join(out, 'rodadas_representativas.txt'), 'w') as fh:
        for sc, path in sorted(rep.items()):
            fh.write(f'{sc}: {os.path.basename(path)}\n')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])

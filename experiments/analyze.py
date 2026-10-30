"""Resume os CSVs do k6 gerados pelos scripts de experimento.

Para cada arquivo: total de requisições, % de 200, % de 503, % sem resposta (status 0),
latência p50/p95/p99 e a janela de indisponibilidade (do primeiro ao último não-200).
No fim, média e desvio-padrão por cenário (prefixo do arquivo antes do número da rodada).

Uso: python3 experiments/analyze.py experiments/results/*.csv
"""
import csv
import re
import statistics
import sys
from collections import defaultdict


def percentile(values, p):
    if not values:
        return float('nan')
    values = sorted(values)
    k = (len(values) - 1) * p / 100
    f = int(k)
    c = min(f + 1, len(values) - 1)
    return values[f] + (values[c] - values[f]) * (k - f)


def summarize(path):
    durations, statuses, times = [], [], []
    with open(path, newline='') as fh:
        for row in csv.DictReader(fh):
            if row['metric_name'] != 'http_req_duration':
                continue
            durations.append(float(row['metric_value']))
            statuses.append(int(row.get('status') or 0))
            times.append(int(row['timestamp']))
    n = len(statuses)
    bad = [t for t, s in zip(times, statuses) if s != 200]
    return {
        'total': n,
        'ok_pct': 100 * statuses.count(200) / n,
        '503_pct': 100 * statuses.count(503) / n,
        'sem_resposta_pct': 100 * statuses.count(0) / n,
        'p50_ms': percentile(durations, 50),
        'p95_ms': percentile(durations, 95),
        'p99_ms': percentile(durations, 99),
        'janela_erro_s': (max(bad) - min(bad)) if bad else 0,
    }


def main(paths):
    by_scenario = defaultdict(list)
    for path in paths:
        s = summarize(path)
        print(path, ' '.join(f'{k}={v:.2f}' if isinstance(v, float) else f'{k}={v}' for k, v in s.items()))
        by_scenario[re.sub(r'-\d+\.csv$', '', path.split('/')[-1])].append(s)

    print('\ncenario,metrica,media,desvio_padrao,n')
    for scenario, runs in sorted(by_scenario.items()):
        for key in runs[0]:
            vals = [r[key] for r in runs]
            sd = statistics.stdev(vals) if len(vals) > 1 else 0.0
            print(f'{scenario},{key},{statistics.mean(vals):.2f},{sd:.2f},{len(vals)}')


if __name__ == '__main__':
    main(sys.argv[1:])

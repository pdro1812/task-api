"""Tempos do C1 por rodada, usando o instante de início de cada requisição (fim - duração).

erro_apos_queda_s: início da primeira requisição com erro em relação ao scale do Redis para 0
recuperacao_apos_restore_s: início da última requisição com erro em relação ao scale de volta para 1
indisponivel_total_s: intervalo entre a primeira e a última requisição com erro

Uso (dentro de experiments/results): python3 ../c1_tempos.py > final/c1_tempos.csv
"""
import csv, glob, re, statistics as st, sys
from collections import defaultdict
out = defaultdict(lambda: defaultdict(list))
for path in sorted(glob.glob('redis-*.csv')):
    sc = re.sub(r'-\d+\.csv$', '', path)
    fail = float(open(path[:-4]+'.fail').read()); rec = float(open(path[:-4]+'.recover').read())
    reqs = []
    for r in csv.DictReader(open(path)):
        if r['metric_name'] != 'http_req_duration': continue
        end = int(r['timestamp']); d = float(r['metric_value'])/1000
        reqs.append((end - d, int(r['status'] or 0)))
    reqs.sort()
    # primeira requisição (por início) não-200 após a queda
    first_bad = next(t for t, s in reqs if t >= fail - 1 and s != 200)
    # última requisição não-200 (por início) -> recuperação contada a partir do restore
    last_bad = max(t for t, s in reqs if s != 200)
    out[sc]['erro_apos_queda_s'].append(first_bad - fail)
    out[sc]['recuperacao_apos_restore_s'].append(last_bad - rec)
    out[sc]['indisponivel_total_s'].append(last_bad - first_bad)
w = csv.writer(sys.stdout)
w.writerow(['configuracao','metrica','media','dp','min','max','n'])
for sc in sorted(out):
    for m, v in out[sc].items():
        w.writerow([sc, m, f'{st.mean(v):.2f}', f'{st.stdev(v):.2f}', f'{min(v):.2f}', f'{max(v):.2f}', len(v)])

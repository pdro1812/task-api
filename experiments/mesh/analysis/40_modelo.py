#!/usr/bin/env python3
# STATUS: rascunho, testado só com dados sintéticos
"""Modelo composicional do acréscimo de latência de um mesh (RQ3).

Ideia: o acréscimo de latência que o mesh causa numa requisição é a soma do custo dos "saltos" por proxy que ela
atravessa. Cada salto custa um tempo de serviço s (ms) e espera em fila; com utilização rho, a espera segue um termo
do tipo M/M/1:
    acréscimo_médio(lambda) = H * s / (1 - rho),   rho = u * lambda * H
    acréscimo_p99(lambda)   = H * s * ln(100) / (1 - rho)          (cauda exponencial do tempo de resposta M/M/1)
H = R_app * h_cfg + e_cfg: saltos por requisição (R_app chamadas RPC por requisição externa, h_cfg saltos por RPC na
configuração, e_cfg saltos na entrada). Parâmetros por configuração: s e u. Ajustados no echo e no Online Boutique
(mínimos quadrados sobre as medianas por carga) e usados para PREVER o Hotel Reservation, que não entra no ajuste.

As cargas da bateria são % da MENOR saturação entre as configurações (mesma taxa absoluta para todas); o modelo usa
a taxa obtida (rps) de cada rodada, não a porcentagem, então não depende dessa escolha. Ver também a vazão máxima por
configuração (04-saturacao.sh): o termo 1/(1-rho) diverge perto dela, o que permite checar u contra SAT_<app>_<cfg>.

Uso: python 40_modelo.py <cells.csv> [--saltos saltos.json] [--saida ../paper/tables/modelo.tex]
Saída: tabela com s, u e o erro de previsão (média e p99) no Hotel, por configuração.
"""
import argparse
import json
import math
import os

import numpy as np
import pandas as pd
from scipy.optimize import least_squares

# ANOTAR: R_app (chamadas RPC internas por requisição externa). Medir na IS: soma de istio_requests_total
# (reporter=destination) dividida pelas requisições do k6. Valores abaixo são estimativas iniciais.
SALTOS_PADRAO = {
    "R": {"echo": 1, "ob": 4, "hotel": 3},
    # saltos de proxy por RPC interna e na entrada, por configuração
    "h": {"IS": 2, "LK": 2, "IA4": 2, "IA7": 3, "CI": 1},
    "e": {"IS": 1, "LK": 1, "IA4": 1, "IA7": 1, "CI": 1},
}


def saltos(cfg, app, tab):
    return tab["R"][app] * tab["h"][cfg] + tab["e"][cfg]


def preparar(df):
    """Mediana por (config, app, carga) de média e p99, e acréscimo sobre a B na mesma app/carga."""
    col_media = "mean_ms" if "mean_ms" in df else "p50_ms"     # o agregado tem p50; ANOTAR se trocar pela média
    g = df.groupby(["config", "app", "load"]).agg(rps=("rps", "median"), m=(col_media, "median"),
                                                 p99=("p99_ms", "median")).reset_index()
    b = g[g.config == "B"].set_index(["app", "load"])
    g = g[g.config != "B"].copy()
    g["d_m"] = [r.m - b.loc[(r.app, r.load), "m"] for r in g.itertuples()]
    g["d_p99"] = [r.p99 - b.loc[(r.app, r.load), "p99"] for r in g.itertuples()]
    return g


def prever(params, lam, H, cauda=False):
    s, u = params
    rho = np.clip(u * lam * H, 0, 0.99)
    k = math.log(100) if cauda else 1.0
    return H * s * k / (1 - rho)


def ajustar(g, cfg, tab):
    tr = g[(g.config == cfg) & g.app.isin(["echo", "ob"])]
    if tr.empty:
        return None
    H = np.array([saltos(cfg, a, tab) for a in tr.app], float)
    lam = tr.rps.values / 1000.0          # em mil req/s, para u ficar numa escala razoável

    def residuos(p):
        return np.concatenate([prever(p, lam, H) - tr.d_m.values,
                               (prever(p, lam, H, cauda=True) - tr.d_p99.values) / math.log(100)])
    r = least_squares(residuos, x0=[0.1, 0.01], bounds=([0, 0], [np.inf, np.inf]))
    return r.x


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cells")
    ap.add_argument("--saltos")
    ap.add_argument("--saida", default=os.path.join(os.path.dirname(__file__), "..", "paper", "tables", "modelo.tex"))
    a = ap.parse_args()
    tab = json.load(open(a.saltos)) if a.saltos else SALTOS_PADRAO
    g = preparar(pd.read_csv(a.cells))
    linhas = []
    for cfg in ["IS", "IA4", "IA7", "LK", "CI"]:
        p = ajustar(g, cfg, tab)
        te = g[(g.config == cfg) & (g.app == "hotel")]
        if p is None or te.empty:
            continue
        H = saltos(cfg, "hotel", tab)
        lam = te.rps.values / 1000.0
        pm, p99 = prever(p, lam, H), prever(p, lam, H, cauda=True)
        erro_m = float(np.median(np.abs(pm - te.d_m.values) / np.maximum(np.abs(te.d_m.values), 1e-6)))
        erro_99 = float(np.median(np.abs(p99 - te.d_p99.values) / np.maximum(np.abs(te.d_p99.values), 1e-6)))
        linhas.append({"config": cfg, "s_ms": p[0], "u": p[1], "H_hotel": H, "erro_media": erro_m, "erro_p99": erro_99})
    res = pd.DataFrame(linhas)
    print(res.to_string(index=False))
    os.makedirs(os.path.dirname(a.saida), exist_ok=True)
    with open(a.saida, "w") as f:
        f.write("% gerado por analysis/40_modelo.py\n\\begin{tabular}{lrrrr}\n\\toprule\n")
        f.write("Config. & $s$ (ms) & $u$ & err. mean & err. p99 \\\\\n\\midrule\n")
        for r in res.itertuples():
            f.write(f"{r.config} & {r.s_ms:.3f} & {r.u:.4f} & {100 * r.erro_media:.0f}\\% & {100 * r.erro_p99:.0f}\\% \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n")


if __name__ == "__main__":
    main()

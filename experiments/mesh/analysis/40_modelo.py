#!/usr/bin/env python3
# STATUS: rascunho, testado só com os dados da bateria (sem validação externa)
"""Modelo composicional do acréscimo de latência de um mesh (RQ3), com o grafo de chamadas medido.

    acréscimo(mesh, app, carga) = P_mesh(app) * c_mesh + q_mesh * rho/(1 - rho)

  P_mesh(app)  travessias de proxy por requisição externa, contadas a partir de hops.json (09-saltos.sh):
               B 0; IS e LK 2 por chamada interna + 1 na entrada (sidecar do pod de borda);
               IA4 2 por chamada entre nós + 1 por chamada no mesmo nó + 1 na entrada (ztunnel);
               IA7 = IA4 + 1 waypoint por chamada HTTP/gRPC; CI 1 (WireGuard) por chamada entre nós +
               1 (Envoy do nó, regra L7) por chamada HTTP/gRPC + 1 na entrada.
  rho          utilização de CPU do worker mais ocupado na rodada (rho_hot, medida).
  c_mesh       custo por travessia de proxy (ms; reportado em µs), q_mesh peso da fila; ajuste NNLS.
Acréscimo = mediana do mesh menos mediana da B (10 repetições) na mesma app e carga, para a média e para o p99
(ajustes separados). Treino em echo e Online Boutique; o Hotel fica de fora e é previsto. Também faz validação
deixando uma carga de fora (treino nas outras duas cargas das 3 apps).

Uso: python 40_modelo.py <cells.csv com mean_ms e rho_hot> <hops.json> [--saida ../paper/tables/modelo.tex]
"""
import argparse
import json
import os

import numpy as np
import pandas as pd
from scipy.optimize import nnls

MESHES = ["IS", "IA4", "IA7", "LK", "CI"]


def travessias(cfg, h):
    rpc = h["rpc_entre_nos"] + h["rpc_mesmo_no"]
    if cfg in ("IS", "LK"):
        return 2 * rpc + 1
    if cfg == "IA4":
        return 2 * h["rpc_entre_nos"] + h["rpc_mesmo_no"] + 1
    if cfg == "IA7":
        return 2 * h["rpc_entre_nos"] + h["rpc_mesmo_no"] + 1 + rpc
    if cfg == "CI":
        return h["rpc_entre_nos"] + rpc + 1
    return 0.0


def tabela(cells, hops):
    g = cells.groupby(["config", "app", "load"]).agg(mean=("mean_ms", "median"), p99=("p99_ms", "median"),
                                                     rho=("rho_hot", "median")).reset_index()
    b = g[g.config == "B"].set_index(["app", "load"])
    g = g[g.config.isin(MESHES)].copy()
    g["d_mean"] = [r.mean - b.loc[(r.app, r.load), "mean"] for r in g.itertuples()]
    g["d_p99"] = [r.p99 - b.loc[(r.app, r.load), "p99"] for r in g.itertuples()]
    g["P"] = [travessias(r.config, hops[r.app]) for r in g.itertuples()]
    g["fila"] = g.rho.clip(upper=0.95) / (1 - g.rho.clip(upper=0.95))
    return g


def ajusta(tr, alvo):
    coef, _ = nnls(tr[["P", "fila"]].values, tr[alvo].values)
    return coef


def erro_rel(pred, real):
    return float(np.median(np.abs(pred - real) / np.maximum(np.abs(real), 1e-6)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cells")
    ap.add_argument("hops")
    ap.add_argument("--saida", default=os.path.join(os.path.dirname(__file__), "..", "paper", "tables", "modelo.tex"))
    a = ap.parse_args()
    cells = pd.read_csv(a.cells)
    hops = json.load(open(a.hops))
    g = tabela(cells, hops)
    linhas = []
    for m in MESHES:
        x = g[g.config == m]
        tr, te = x[x.app.isin(["echo", "ob"])], x[x.app == "hotel"]
        lin = {"config": m, "P_echo": x[x.app == "echo"].P.iloc[0], "P_ob": x[x.app == "ob"].P.iloc[0],
               "P_hotel": x[x.app == "hotel"].P.iloc[0]}
        for alvo in ("d_mean", "d_p99"):
            c, q = ajusta(tr, alvo)
            pred = te.P.values * c + te.fila.values * q
            lin[f"c_us_{alvo}"] = 1000 * c
            lin[f"q_{alvo}"] = q
            lin[f"erro_hotel_{alvo}"] = erro_rel(pred, te[alvo].values)
            # deixa uma carga de fora: treina nas outras duas cargas das 3 apps
            erros = []
            for load in sorted(x.load.unique()):
                c2, q2 = ajusta(x[x.load != load], alvo)
                t2 = x[x.load == load]
                erros.append(erro_rel(t2.P.values * c2 + t2.fila.values * q2, t2[alvo].values))
            lin[f"erro_lolo_{alvo}"] = float(np.median(erros))
        linhas.append(lin)
    res = pd.DataFrame(linhas)
    pd.set_option("display.width", 200)
    print(res.round(3).to_string(index=False))
    os.makedirs(os.path.dirname(a.saida), exist_ok=True)
    with open(a.saida, "w") as f:
        f.write("% gerado por analysis/40_modelo.py\n\\begin{tabular}{lrrrrrr}\n\\toprule\n")
        f.write("Config. & $P_\\mathrm{hotel}$ & $c$ ($\\mu$s) & err. mean & $c_{p99}$ ($\\mu$s) & err. p99 & "
                "LOLO p99 \\\\\n\\midrule\n")
        for r in res.itertuples():
            f.write(f"{r.config} & {r.P_hotel:.1f} & {r.c_us_d_mean:.0f} & {100 * r.erro_hotel_d_mean:.0f}\\% & "
                    f"{r.c_us_d_p99:.0f} & {100 * r.erro_hotel_d_p99:.0f}\\% & {100 * r.erro_lolo_d_p99:.0f}\\% \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n")


if __name__ == "__main__":
    main()

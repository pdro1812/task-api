#!/usr/bin/env python3
# STATUS: rascunho, não testado com a bateria de energia
"""Compara a energia com e sem halt-polling do KVM (bateria principal x 05b-energia.sh).

Uso: python 60_energia.py <cells da bateria principal> <cells da energia-hp0> [--saida ../paper/tables/energia.tex]

Ambos os cells.csv vêm do 10_agregar.py (j_per_req já líquido da ociosa da B de cada bateria). Para as cargas em
comum (30 e 90%), por app e configuração: J/req (mediana) com e sem halt-polling e a variação contra a B; o resíduo
do ajuste W ~ núcleos ocupados (agora com os núcleos de todas as rodadas da bateria de energia) por configuração;
e a variação do p99 entre as duas baterias (para declarar se o halt-polling mexe na latência).
"""
import argparse
import os

import numpy as np
import pandas as pd

ORDEM = ["B", "IS", "IA4", "IA7", "LK", "CI"]


def nucleos(df):
    cols = [c for c in df if c.startswith("cpu_")]
    return df[cols].sum(axis=1)


def residuos(df):
    x = nucleos(df).values
    w = (df.pkg_j / df.seconds).values
    a = np.vstack([x, np.ones_like(x)]).T
    coef, *_ = np.linalg.lstsq(a, w, rcond=None)
    df = df.assign(res=w - a @ coef)
    return coef, df.groupby("config").res.mean()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("principal")
    ap.add_argument("hp0")
    ap.add_argument("--saida", default=os.path.join(os.path.dirname(__file__), "..", "paper", "tables", "energia.tex"))
    a = ap.parse_args()
    p, h = pd.read_csv(a.principal), pd.read_csv(a.hp0)
    cargas = sorted(set(h.load) & set(p.load))
    p = p[p.load.isin(cargas)]
    linhas = []
    for (app, load), g in h.groupby(["app", "load"]):
        gp = p[(p.app == app) & (p.load == load)]
        bh = g[g.config == "B"].j_per_req.median()
        bp = gp[gp.config == "B"].j_per_req.median()
        bp99 = gp[gp.config == "B"].p99_ms.median()
        for cfg in ORDEM:
            jh = g[g.config == cfg].j_per_req.median()
            jp = gp[gp.config == cfg].j_per_req.median()
            linhas.append({"app": app, "load": load, "config": cfg, "J_req_hp0": jh, "vs_B_hp0_%": 100 * (jh / bh - 1),
                           "J_req_hp200": jp, "vs_B_hp200_%": 100 * (jp / bp - 1),
                           "p99_hp0": g[g.config == cfg].p99_ms.median(), "p99_hp200": gp[gp.config == cfg].p99_ms.median(),
                           "idle_extra_w": g[g.config == cfg].idle_extra_w.median()})
    t = pd.DataFrame(linhas)
    t["p99_var_%"] = 100 * (t.p99_hp0 / t.p99_hp200 - 1)
    pd.set_option("display.width", 220)
    print(t.round(3).to_string(index=False))
    for nome, df in (("halt-polling 200 µs (bateria principal)", p), ("halt-polling 0", h)):
        coef, r = residuos(df)
        print(f"\n{nome}: W = {coef[0]:.2f} * núcleos + {coef[1]:.1f}; resíduo médio por config (W):",
              r.reindex(ORDEM).round(2).to_dict())
    t.to_csv(os.path.join(os.path.dirname(os.path.abspath(a.hp0)), "energia-comparacao.csv"), index=False)
    with open(a.saida, "w") as f:
        f.write("% gerado por analysis/60_energia.py\n\\begin{tabular}{l" + "r" * (3 * len(cargas)) + "}\n")
        f.write("\\toprule\nConfig. & " + " & ".join(f"{app} {l}\\%" for app in ("echo", "ob", "hotel") for l in cargas)
                + " \\\\\n\\midrule\n")
        for cfg in ORDEM:
            cel = []
            for app in ("echo", "ob", "hotel"):
                for l in cargas:
                    r = t[(t.app == app) & (t.load == l) & (t.config == cfg)]
                    cel.append("--" if r.empty else f"{1000 * r.J_req_hp0.iloc[0]:.1f}")
            f.write(f"{cfg} & " + " & ".join(cel) + " \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n% mJ por requisição, líquido da ociosa da B, halt_poll_ns = 0\n")


if __name__ == "__main__":
    main()

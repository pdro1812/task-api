#!/usr/bin/env python3
"""Modelo do RQ3 com travessias entre nós, testado fora da aplicação (HR) e fora da posição (10-placement.sh).

    acréscimo(mesh, app, posição, carga) = c_p * P + c_x * X + q * rho/(1 - rho)

  P    travessias de proxy por requisição (do grafo de chamadas de hops.json e da posição dos pods):
       IS, LK 2 por chamada; IA4 1 ztunnel por nó tocado (1 no mesmo nó, 2 entre nós); IA7 ztunnels dos nós
       tocados em {cliente, waypoint, servidor} + 1 waypoint; CI 1 Envoy do nó; CI4 0. Entrada: +1 (0 na CI4).
  X    travessias entre nós por requisição no caminho do mesh (inclui a entrada k6 -> w1 -> pod de borda); igual à
       da B em todos, menos na IA7 (cliente -> waypoint -> servidor).
  rho  utilização do worker mais ocupado (mediana das rodadas, de prom-node-cpu.json).
Acréscimo = mediana do mesh menos mediana da B na mesma app, posição e carga (média e p99). Ajuste NNLS por mesh
em echo + OB da bateria principal; previsão do HR (fora da aplicação) e das células de posicionamento (fora da
posição; B de referência: a da mesma posição). Também a lei do gargalo: vazão máxima ~ taxa / rho_hot (célula de
maior carga), comparada com a saturação medida.

Uso: 41_modelo_x.py <bateria> <placement> <ci4> <hops.json> <saturação.csv> [--saida ../paper/tables/modelo.tex]
"""
import argparse
import glob
import importlib.util
import json
import os
import statistics

import numpy as np
import pandas as pd
from scipy.optimize import nnls

_spec = importlib.util.spec_from_file_location("nu", os.path.join(os.path.dirname(__file__), "12_node_util.py"))
nu = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(nu)

ENTRADA = "w1"   # o k6 entra pelo NodePort de w1 em todas as apps
NOS = {
    ("echo", "orig"): {"relay": "w2", "echo": "w3"},
    ("ob", "orig"): {"adservice": "w1", "currencyservice": "w1", "paymentservice": "w1", "redis-cart": "w1",
                     "cartservice": "w2", "emailservice": "w2", "productcatalogservice": "w2", "shippingservice": "w2",
                     "checkoutservice": "w3", "frontend": "w3", "recommendationservice": "w3"},
    ("ob", "fe-alone"): {"adservice": "w1", "checkoutservice": "w1", "emailservice": "w1",
                         "productcatalogservice": "w1", "redis-cart": "w1", "cartservice": "w2", "currencyservice": "w2",
                         "paymentservice": "w2", "recommendationservice": "w2", "shippingservice": "w2", "frontend": "w3"},
    ("hotel", "orig"): {"frontend": "w2", "profile": "w2", "reservation": "w2", "search": "w3", "geo": "w3",
                        "rate": "w3", "recommendation": "w1", "user": "w1"},
}
BORDA = {"echo": "relay", "ob": "frontend", "hotel": "frontend"}
WAYPOINT = {"echo": "w1", "ob": "w2", "hotel": "w3"}
MESHES = ["IS", "IA4", "IA7", "LK", "CI", "CI4"]


def caminho(cfg, a, b, w):
    """(P, X) de uma chamada do nó a ao nó b; w = nó do waypoint (IA7)."""
    if cfg == "IA7":
        return len({a, w, b}) + 1, int(a != w) + int(w != b)
    x = int(a != b)
    return {"B": 0, "IS": 2, "LK": 2, "IA4": 1 + x, "CI": 1, "CI4": 0}[cfg], x


def px(cfg, app, pos, wp, hops):
    nos = NOS[(app, pos)]
    w = wp or WAYPOINT[app]
    borda = nos[BORDA[app]]
    p, x = caminho(cfg, ENTRADA, borda, w)
    p = {"B": 0, "CI4": 0}.get(cfg, 1)            # entrada: um proxy no pod/nó de borda
    if cfg == "IA7":
        x = int(ENTRADA != borda)                   # a entrada não passa pelo waypoint
    for e in hops[app]["arestas"]:
        if e["tipo"] != "rpc":
            continue
        dp, dx = caminho(cfg, nos[e["de"]], nos[e["para"]], w)
        p += e["por_req"] * dp
        x += e["por_req"] * dx
    return p, x


def rho_runs(d):
    out = {}
    for m in glob.glob(os.path.join(d, "*", "*", "meta.json")):
        f = os.path.join(os.path.dirname(m), "prom-node-cpu.json")
        if os.path.exists(f):
            u = nu.util_rodada(f)
            out[os.path.dirname(m)] = max(u.get(n, 0) for n in ("w1", "w2", "w3"))
    return out


def celulas(cells_csv, d, origem):
    c = pd.read_csv(cells_csv)
    rho = rho_runs(d)
    c["dir"] = [os.path.join(d, (r.placement + "-" + r.config) if origem == "placement" else r.config,
                             f"{r.app}-{r.load}-{r.rep}") for r in c.itertuples()]
    c["rho"] = c.dir.map(rho)
    if "placement" not in c:
        c["placement"] = "orig"
    if "waypoint_node_ob" not in c:
        c["waypoint_node_ob"] = "w2"
    c["placement"] = c.placement.fillna("orig")
    c["origem"] = origem
    if "mean_ms" not in c:
        c["mean_ms"] = np.nan   # cells.csv antigos não têm a média
    return c


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for k in ("bateria", "placement", "ci4", "hops", "sat"):
        ap.add_argument(k)
    ap.add_argument("--saida", default=os.path.join(os.path.dirname(__file__), "..", "paper", "tables", "modelo.tex"))
    a = ap.parse_args()
    hops = json.load(open(a.hops))
    c = pd.concat([celulas(os.path.join(a.bateria, "cells.csv"), a.bateria, "bateria"),
                   celulas(os.path.join(a.placement, "cells.csv"), a.placement, "placement"),
                   celulas(os.path.join(a.ci4, "cells.csv"), a.ci4, "ci4")])
    c = c[c.config.isin(["B"] + MESHES)]
    g = c.groupby(["origem", "config", "app", "placement", "waypoint_node_ob", "load"]).agg(
        mean=("mean_ms", "median"), p99=("p99_ms", "median"), rho=("rho", "median"), rate=("rate", "first"),
        n=("rep", "count")).reset_index()
    # referência B: a da mesma posição (fe-alone tem B própria; o resto usa a B da bateria principal)
    bb = g[(g.config == "B")].set_index(["app", "placement", "load"])
    def ref(r, col):
        k = (r.app, r.placement if (r.app, r.placement, r.load) in bb.index else "orig", r.load)
        v = bb.loc[k, col]
        return float(v.iloc[0]) if hasattr(v, "iloc") else float(v)
    g = g[g.config != "B"].copy()
    g["d_mean"] = [r.mean - ref(r, "mean") for r in g.itertuples()]
    g["d_p99"] = [r.p99 - ref(r, "p99") for r in g.itertuples()]
    pxs = [px(r.config, r.app, r.placement, r.waypoint_node_ob if r.app == "ob" else None, hops) for r in g.itertuples()]
    g["P"] = [p for p, _ in pxs]
    g["X"] = [x for _, x in pxs]
    rc = g.rho.clip(upper=0.95)
    g["fila"] = rc / (1 - rc)
    cols = ["P", "X", "fila"]
    linhas, prev = [], []
    for m in MESHES:
        x = g[g.config == m]
        tr = x[(x.app.isin(["echo", "ob"])) & (x.placement == "orig") & (x.waypoint_node_ob == "w2")
               & (x.origem != "placement")]
        if len(tr) < 3:
            continue
        lin = {"config": m, "P_hotel": x[x.app == "hotel"].P.iloc[0] if (x.app == "hotel").any() else np.nan,
               "X_hotel": x[x.app == "hotel"].X.iloc[0] if (x.app == "hotel").any() else np.nan}
        for alvo in ("d_mean", "d_p99"):
            if tr[alvo].isna().any():
                lin.update({f"cp_{alvo}": np.nan, f"cx_{alvo}": np.nan, f"q_{alvo}": np.nan,
                            f"err_hotel_{alvo}": np.nan, f"err_pos_{alvo}": np.nan})
                continue
            coef, _ = nnls(tr[cols].values, tr[alvo].values)
            lin.update({f"cp_{alvo}": 1000 * coef[0], f"cx_{alvo}": 1000 * coef[1], f"q_{alvo}": coef[2]})
            for nome, te in (("hotel", x[x.app == "hotel"]), ("pos", x[x.origem == "placement"])):
                if te.empty:
                    lin[f"err_{nome}_{alvo}"] = np.nan
                    continue
                pred = te[cols].values @ coef
                err = np.abs(pred - te[alvo].values) / np.maximum(np.abs(te[alvo].values), 1e-6)
                lin[f"err_{nome}_{alvo}"] = float(np.median(err))
                if alvo == "d_p99":
                    for r, p in zip(te.itertuples(), pred):
                        prev.append({"config": m, "app": r.app, "pos": r.placement, "wp": r.waypoint_node_ob,
                                     "load": r.load, "P": r.P, "X": r.X, "rho": r.rho, "real": r.d_p99, "pred": p})
        linhas.append(lin)
    res = pd.DataFrame(linhas)
    pd.set_option("display.width", 250)
    print(res.round(3).to_string(index=False))
    print(pd.DataFrame(prev).round(2).to_string(index=False))
    # lei do gargalo: vazão máxima ~ taxa / rho_hot, na maior carga (bateria principal e CI4)
    sat = pd.read_csv(a.sat)
    gb = c[c.placement == "orig"].groupby(["config", "app", "load"]).agg(rho=("rho", "median"), rate=("rate", "first")).reset_index()
    top = gb[gb.load == gb.load.max()].copy()
    top["xmax"] = top.rate / top.rho
    top = top.merge(sat, on=["config", "app"], how="left")
    top["err"] = (top.xmax - top.sat) / top.sat
    print(top.round(3).to_string(index=False))
    with open(a.saida, "w") as f:
        f.write("% generated by analysis/41_modelo_x.py\n\\begin{tabular}{lrrrrrr}\n\\toprule\n")
        f.write("Config. & $c_p$ ($\\mu$s) & $c_x$ ($\\mu$s) & $q$ (ms) & err.\\ HR & err.\\ place. & "
                "err.\\ $X_{\\max}$ \\\\\n\\midrule\n")
        for r in res.itertuples():
            # lei do gargalo: só OB e HR (no echo o gargalo é um processo, o relay, não o nó)
            e = top[(top.config == r.config) & (top.app != "echo")].err.abs()
            eb = "--" if e.dropna().empty else f"{100 * e.median():.0f}\\%"
            ep = "--" if np.isnan(r.err_pos_d_p99) else f"{100 * r.err_pos_d_p99:.0f}\\%"
            f.write(f"{r.config} & {r.cp_d_p99:.0f} & {r.cx_d_p99:.0f} & {r.q_d_p99:.1f} & "
                    f"{100 * r.err_hotel_d_p99:.0f}\\% & {ep} & {eb} \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n")
    print(a.saida)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# STATUS: rascunho, testado só com dados sintéticos
"""Estatística sobre cells.csv (10_agregar.py) e tabelas LaTeX para o artigo.

Uso: python 20_estatistica.py <cells.csv> [--tabelas ../paper/tables] [--metricas p99_ms p50_ms j_per_req]

Para cada métrica, app e carga:
  - mediana por configuração com IC de 95% por bootstrap (10000 reamostragens das repetições);
  - Kruskal-Wallis entre as configurações;
  - Mann-Whitney de cada mesh contra a B, p-valores corrigidos por Holm dentro de (app, carga);
  - delta de Cliff (tamanho de efeito; |d| < 0,147 desprezível, < 0,33 pequeno, < 0,474 médio, senão grande);
  - coeficiente de variação do p99 entre repetições (estabilidade da medida).
Saídas: estatistica.csv (tudo, ao lado do cells.csv) e uma tabela .tex por métrica em --tabelas.
"""
import argparse
import os

import numpy as np
import pandas as pd
from scipy import stats

ORDEM = ["B", "IS", "IA4", "IA7", "LK", "CI"]
NOMES = {"B": "No mesh", "IS": "Istio sidecar", "IA4": "Istio ambient (L4)", "IA7": "Istio ambient + waypoint",
         "LK": "Linkerd", "CI": "Cilium (WG + L7)"}
RNG = np.random.default_rng(2027)


def ic_bootstrap(x, n=10000, alfa=0.05):
    x = np.asarray(x, float)
    if len(x) < 2:
        return (np.nan, np.nan)
    meds = np.median(RNG.choice(x, size=(n, len(x)), replace=True), axis=1)
    return tuple(np.quantile(meds, [alfa / 2, 1 - alfa / 2]))


def cliff_delta(a, b):
    a, b = np.asarray(a, float), np.asarray(b, float)
    if not len(a) or not len(b):
        return np.nan
    maior = (a[:, None] > b[None, :]).sum()
    menor = (a[:, None] < b[None, :]).sum()
    return (maior - menor) / (len(a) * len(b))


def holm(pvals):
    p = np.asarray(pvals, float)
    ordem = np.argsort(p)
    ajust = np.empty_like(p)
    acum = 0.0
    for k, i in enumerate(ordem):
        acum = max(acum, min(1.0, (len(p) - k) * p[i]))
        ajust[i] = acum
    return ajust


def analisa(df, metrica):
    linhas = []
    for (app, load), g in df.groupby(["app", "load"]):
        grupos = {c: g.loc[g.config == c, metrica].dropna().values for c in ORDEM if (g.config == c).any()}
        validos = [v for v in grupos.values() if len(v) > 1]
        kw_p = stats.kruskal(*validos).pvalue if len(validos) > 1 else np.nan
        base = grupos.get("B", np.array([]))
        comparacoes = [c for c in grupos if c != "B" and len(base) and len(grupos[c])]
        pvals = [stats.mannwhitneyu(grupos[c], base, alternative="two-sided").pvalue for c in comparacoes]
        p_holm = dict(zip(comparacoes, holm(pvals))) if pvals else {}
        for c, v in grupos.items():
            lo, hi = ic_bootstrap(v)
            med = float(np.median(v)) if len(v) else np.nan
            med_b = float(np.median(base)) if len(base) else np.nan
            linhas.append({
                "metrica": metrica, "app": app, "load": load, "config": c, "n": len(v),
                "mediana": med, "ic_lo": lo, "ic_hi": hi,
                "cv": float(np.std(v, ddof=1) / np.mean(v)) if len(v) > 1 and np.mean(v) else np.nan,
                "delta_vs_B": med - med_b if c != "B" else 0.0,
                "razao_vs_B": med / med_b if c != "B" and med_b else 1.0,
                "kw_p": kw_p, "mw_p_holm": p_holm.get(c, np.nan),
                "cliff_vs_B": cliff_delta(v, base) if c != "B" else np.nan,
            })
    return pd.DataFrame(linhas)


def tabela_tex(res, metrica, rotulo, caminho):
    """Uma linha por configuração; colunas app/carga com 'mediana [IC]' e marca de significância."""
    r = res[res.metrica == metrica]
    colunas = sorted(r[["app", "load"]].drop_duplicates().itertuples(index=False), key=lambda t: (t.app, int(t.load)))
    with open(caminho, "w") as f:
        f.write("% gerado por analysis/20_estatistica.py; não editar à mão\n")
        f.write("\\begin{tabular}{l" + "r" * len(colunas) + "}\n\\toprule\n")
        f.write("Config. & " + " & ".join(f"{c.app} {c.load}\\%" for c in colunas) + " \\\\\n\\midrule\n")
        for cfg in ORDEM:
            celulas = []
            for c in colunas:
                x = r[(r.config == cfg) & (r.app == c.app) & (r.load == c.load)]
                if x.empty:
                    celulas.append("--")
                    continue
                x = x.iloc[0]
                sig = "$^{*}$" if cfg != "B" and x.mw_p_holm < 0.05 else ""
                celulas.append(f"{x.mediana:.2f}{sig}")
            f.write(f"{NOMES[cfg]} & " + " & ".join(celulas) + " \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n")
        f.write(f"% {rotulo}: mediana de 10 repetições; * = diferente da B (Mann-Whitney, Holm, p<0,05)\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cells")
    ap.add_argument("--tabelas", default=os.path.join(os.path.dirname(__file__), "..", "paper", "tables"))
    ap.add_argument("--metricas", nargs="+", default=["p50_ms", "p99_ms", "p999_ms", "j_per_req"])
    a = ap.parse_args()
    df = pd.read_csv(a.cells)
    df["load"] = df["load"].astype(str)
    res = pd.concat([analisa(df, m) for m in a.metricas if m in df], ignore_index=True)
    saida = os.path.join(os.path.dirname(os.path.abspath(a.cells)), "estatistica.csv")
    res.to_csv(saida, index=False)
    os.makedirs(a.tabelas, exist_ok=True)
    for m in a.metricas:
        if m in df:
            tabela_tex(res, m, m, os.path.join(a.tabelas, f"{m}.tex"))
    print(f"{len(res)} linhas -> {saida}; tabelas em {a.tabelas}")


if __name__ == "__main__":
    main()

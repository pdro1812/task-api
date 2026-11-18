#!/usr/bin/env python3
# STATUS: rascunho, testado só com dados sintéticos
"""Figuras do artigo, em PDF, largura de coluna IEEE (3,5 pol.) e legíveis em escala de cinza.

Uso: python 30_figuras.py <diretório da bateria> [--perfil <diretório do 06-perfil.sh>]
                          [--saturacao <saturacao.env>] [--saida ../paper/figs]

Usa <bateria>/cells.csv (10_agregar.py) e, para as CDFs, <bateria>/cdf/ (10_agregar.py --cdf).
Figuras:
  cdf_<app>.pdf        CDF da latência a 60% da carga, uma curva por configuração (repetições juntas)
  p99_carga.pdf        p99 (mediana das repetições) por carga, um painel por app; a carga é % da MENOR saturação
                       entre as configurações (mesma taxa absoluta para todas)
  vazao.pdf            (com --saturacao) vazão máxima dentro do SLO por configuração e app, relativa à B
  recursos.pdf         mCPU e MiB por 1000 req/s, empilhados por componente, a 60% da carga
  energia.pdf          J por requisição (líquido da potência ociosa), por configuração e app
  perfil.pdf           (com --perfil) fração das amostras de CPU por categoria de função, por configuração
"""
import argparse
import glob
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

ORDEM = ["B", "IS", "IA4", "IA7", "LK", "CI"]
# escala de cinza + traço + marcador: distinguíveis sem cor
ESTILO = {"B": ("0.0", "-", "o"), "IS": ("0.25", "--", "s"), "IA4": ("0.45", "-.", "^"),
          "IA7": ("0.6", ":", "v"), "LK": ("0.35", (0, (5, 1)), "D"), "CI": ("0.7", (0, (3, 1, 1, 1)), "x")}
HACHURAS = ["", "///", "\\\\\\", "xxx", "...", "ooo", "---", "+++", "|||", "**"]
COMP = ["app", "proxy", "ztunnel", "waypoint", "cilium_agent", "cilium_envoy", "istio_cni", "control_plane"]
LARGURA = 3.5

plt.rcParams.update({"font.size": 8, "font.family": "serif", "axes.linewidth": 0.6, "lines.linewidth": 1.0,
                     "legend.fontsize": 6.5, "legend.frameon": False, "pdf.fonttype": 42})


def salva(fig, saida, nome):
    fig.tight_layout(pad=0.3)
    fig.savefig(os.path.join(saida, nome))
    plt.close(fig)
    print("  ", nome)


def fig_cdf(bateria, saida, carga="60"):
    for app in ("echo", "ob", "hotel"):
        fig, ax = plt.subplots(figsize=(LARGURA, 2.2))
        desenhou = False
        for cfg in ORDEM:
            arqs = glob.glob(os.path.join(bateria, "cdf", f"{cfg}_{app}_{carga}_*.csv"))
            if not arqs:
                continue
            ms = np.sort(np.concatenate([pd.read_csv(a)["ms"].values for a in arqs]))
            cor, traco, _ = ESTILO[cfg]
            ax.plot(ms, np.linspace(0, 1, len(ms)), color=cor, linestyle=traco, label=cfg)
            desenhou = True
        if not desenhou:
            plt.close(fig)
            continue
        ax.set_xscale("log")
        ax.set_xlabel("latency (ms)")
        ax.set_ylabel("CDF")
        ax.legend(ncol=3, loc="lower right")
        salva(fig, saida, f"cdf_{app}.pdf")


def fig_p99(df, saida):
    apps = [a for a in ("echo", "ob", "hotel") if (df.app == a).any()]
    fig, axs = plt.subplots(1, len(apps), figsize=(LARGURA, 1.8), squeeze=False)
    for ax, app in zip(axs[0], apps):
        g = df[df.app == app].groupby(["config", "load"])["p99_ms"].median().reset_index()
        for cfg in ORDEM:
            x = g[g.config == cfg].sort_values("load")
            if x.empty:
                continue
            cor, traco, marca = ESTILO[cfg]
            ax.plot(x.load, x.p99_ms, color=cor, linestyle=traco, marker=marca, markersize=3, label=cfg)
        ax.set_title(app)
        ax.set_xticks([30, 60, 90])
        ax.set_xlabel("load (%)")
        ax.set_yscale("log")
    axs[0][0].set_ylabel("p99 (ms)")
    axs[0][-1].legend(ncol=1, loc="upper left", bbox_to_anchor=(1, 1))
    salva(fig, saida, "p99_carga.pdf")


def fig_recursos(df, saida, carga=90):
    g = df[df.load == carga]
    if g.empty:
        return
    fig, axs = plt.subplots(2, 1, figsize=(LARGURA, 3.8), sharex=True)
    rotulos = []
    for col, (ax, prefixo, unidade) in enumerate(zip(axs, ("mcpu_per_krps_", "mib_per_krps_"),
                                                     ("mCPU / 1k req/s", "MiB / 1k req/s"))):
        pos = 0
        rotulos = []
        for app in ("echo", "ob", "hotel"):
            for cfg in ORDEM:
                x = g[(g.app == app) & (g.config == cfg)]
                if x.empty:
                    continue
                base = 0.0
                for k, c in enumerate(COMP):
                    v = x[prefixo + c].median() if prefixo + c in x else 0.0
                    ax.bar(pos, v, bottom=base, color="white", edgecolor="black", hatch=HACHURAS[k],
                           linewidth=0.4, label=c if pos == 0 else None)
                    base += v
                rotulos.append((pos, f"{app}\n{cfg}" if cfg == "B" else cfg))
                pos += 1
            pos += 0.6
        ax.set_ylabel(unidade)
    axs[1].set_xticks([p for p, _ in rotulos])
    axs[1].set_xticklabels([r for _, r in rotulos], rotation=90, fontsize=6)
    fig.legend(*axs[0].get_legend_handles_labels(), ncol=4, loc="upper center", fontsize=5.5,
               bbox_to_anchor=(0.5, 1.0))
    fig.tight_layout(pad=0.3, rect=(0, 0, 1, 0.9))
    fig.savefig(os.path.join(saida, "recursos.pdf"))
    plt.close(fig)
    print("   recursos.pdf")


def fig_energia(df, saida, carga=60):
    g = df[df.load == carga]
    if g.empty or "j_per_req" not in g:
        return
    fig, ax = plt.subplots(figsize=(LARGURA, 2.0))
    largura = 0.13
    for k, cfg in enumerate(ORDEM):
        vals = [g[(g.app == a) & (g.config == cfg)]["j_per_req"].median() for a in ("echo", "ob", "hotel")]
        ax.bar(np.arange(3) + (k - 2.5) * largura, vals, largura, color="white", edgecolor="black",
               hatch=HACHURAS[k], linewidth=0.4, label=cfg)
    ax.set_xticks(range(3))
    ax.set_xticklabels(["echo", "ob", "hotel"])
    ax.set_ylabel("J / request (net)")
    ax.set_yscale("log")
    ax.legend(ncol=3)
    salva(fig, saida, "energia.pdf")


# Categorias de função nas pilhas do perf (primeira que casar); ANOTAR: revisar com as pilhas reais
CATEGORIAS = [("tls/crypto", ("ssl", "tls", "aes", "chacha", "crypto", "rustls", "boringssl")),
              ("http parse", ("http", "hpack", "h2", "nghttp", "hyper")),
              ("ebpf/xdp", ("bpf_prog", "bpf_", "xdp")),
              ("wireguard", ("wg_", "wireguard", "chacha20poly1305")),
              ("kernel net", ("tcp_", "ip_", "__netif", "net_rx", "skb", "nf_", "veth", "inet_")),
              ("syscall/sched", ("entry_syscall", "do_syscall", "schedule", "futex", "epoll")),
              ("app", ())]


def categoria_pilha(pilha):
    p = pilha.lower()
    for nome, chaves in CATEGORIAS:
        if any(k in p for k in chaves):
            return nome
    return "outros"


def fig_perfil(perfil, saida, app="echo"):
    linhas = []
    for cfg in ORDEM:
        total = {}
        for arq in glob.glob(os.path.join(perfil, cfg, app, "*.folded")):
            with open(arq) as f:
                for linha in f:
                    pilha, _, n = linha.rpartition(" ")
                    c = categoria_pilha(pilha)
                    total[c] = total.get(c, 0) + int(n)
        if total:
            s = sum(total.values())
            linhas.append({"config": cfg, **{k: v / s for k, v in total.items()}})
    if not linhas:
        return
    t = pd.DataFrame(linhas).fillna(0).set_index("config")
    fig, ax = plt.subplots(figsize=(LARGURA, 2.0))
    base = np.zeros(len(t))
    for k, c in enumerate(t.columns):
        ax.barh(t.index, t[c], left=base, color="white", edgecolor="black", hatch=HACHURAS[k], linewidth=0.4,
                label=c)
        base += t[c].values
    ax.set_xlabel("fraction of CPU samples (worker nodes)")
    ax.legend(ncol=3, fontsize=5.5, loc="upper center", bbox_to_anchor=(0.5, -0.35))
    salva(fig, saida, "perfil.pdf")


def fig_vazao(arquivo, saida):
    """Barras: SAT_<app>_<cfg> / SAT_<app>_B, um grupo por app (04-saturacao.sh)."""
    sat = {}
    for linha in open(arquivo):
        nome, _, v = linha.strip().partition("=")
        partes = nome.split("_")
        if len(partes) == 3 and partes[0] == "SAT" and v.isdigit():
            sat[(partes[1], partes[2])] = int(v)
    apps = [a for a in ("echo", "ob", "hotel") if (a, "B") in sat]
    if not apps:
        return
    fig, ax = plt.subplots(figsize=(LARGURA, 1.9))
    largura = 0.13
    for k, cfg in enumerate(ORDEM):
        vals = [sat.get((a, cfg), np.nan) / sat[(a, "B")] for a in apps]
        ax.bar(np.arange(len(apps)) + (k - 2.5) * largura, vals, largura, color="white", edgecolor="black",
               hatch=HACHURAS[k], linewidth=0.4, label=cfg)
    ax.axhline(1.0, color="0.5", linewidth=0.5)
    ax.set_xticks(range(len(apps)))
    ax.set_xticklabels([f"{a}\n(B: {sat[(a, 'B')]} req/s)" for a in apps])
    ax.set_ylabel("max. throughput\n(relative to B)")
    ax.legend(ncol=6, fontsize=5.5, loc="upper center", bbox_to_anchor=(0.5, 1.25))
    salva(fig, saida, "vazao.pdf")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bateria")
    ap.add_argument("--perfil")
    ap.add_argument("--saturacao", help="saturacao.env do 04-saturacao.sh (SAT_<app>_<cfg>)")
    ap.add_argument("--saida", default=os.path.join(os.path.dirname(__file__), "..", "paper", "figs"))
    a = ap.parse_args()
    os.makedirs(a.saida, exist_ok=True)
    df = pd.read_csv(os.path.join(a.bateria, "cells.csv"))
    df["load"] = df["load"].astype(int)
    fig_cdf(a.bateria, a.saida)
    fig_p99(df, a.saida)
    fig_recursos(df, a.saida)
    fig_energia(df, a.saida)
    # perfil.pdf agora vem do 50_perfil.py (categorias calibradas nas pilhas reais); fig_perfil fica como esboço
    if a.perfil and os.environ.get("PERFIL_ANTIGO"):
        fig_perfil(a.perfil, a.saida)
    if a.saturacao:
        fig_vazao(a.saturacao, a.saida)


if __name__ == "__main__":
    main()

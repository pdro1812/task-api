#!/usr/bin/env python3
# STATUS: testado com o perfil de 17/11 (06-perfil.sh)
"""Quebra do custo do plano de dados por categoria (RQ2), a partir do 06-perfil.sh.

Uso: python 50_perfil.py <diretório do perfil> [--tabela ../paper/tables/perfil.tex] [--figura ../paper/figs/perfil.pdf]

Para cada configuração e app (echo, ob), soma as pilhas dos 3 workers (<nó>.folded; o peso de cada pilha é o tempo
de CPU em ns) que pertencem ao plano de dados:
  - processos do proxy: Envoy (threads wrk:worker_*, envoy; sidecar, waypoint ou Envoy do nó do Cilium),
    linkerd2-proxy, ztunnel, cilium-agent e pilot-agent;
  - em qualquer processo, pilhas com WireGuard (wg_*) ou programas eBPF (bpf_prog*): trabalho do datapath no kernel.
Cada pilha vai para uma categoria. Primeiro pela pilha inteira, na ordem WireGuard, eBPF, TLS e HTTP/gRPC; senão
pela função folha: syscalls de socket, rede do kernel (inclui o virtio-net), escalonamento, memória, lógica do proxy
(filtros, roteamento, runtime) e "proxy, não resolvido" (linkerd2-proxy sem símbolos).
Normaliza por requisição (taxa do k6 x 60 s de perfil) e lê do bpftrace (cabeçalho do <nó>.perf.txt.gz) as trocas
de contexto e as syscalls dos processos do proxy.
Saídas: perfil.csv (ao lado do diretório), tabela LaTeX e figura (barras empilhadas, µs de CPU por requisição).
"""
import argparse
import collections
import glob
import gzip
import json
import os
import re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

ORDEM = ["B", "IS", "IA4", "IA7", "LK", "CI"]
PROXY = re.compile(r"^(wrk:worker|envoy|linkerd2-proxy|ztunnel|cilium-agent|pilot-agent)")
PILHA = [("wireguard", re.compile(r"(^|;)(wg_|wireguard)", re.I)),
         ("eBPF", re.compile(r"(^|;)(bpf_prog|__bpf_prog_run)")),
         ("TLS", re.compile(r"ssl|boringssl|bssl|aes_|gcm|chacha|poly1305|rustls|ring::|aws_lc|x25519|sha256|EVP_|"
                            r"CRYPTO_|tls", re.I)),
         ("HTTP/gRPC", re.compile(r"nghttp2|http_parser|llhttp|oghttp2|hpack|Http::|Http2|Grpc|grpc|2h2|5hyper|"
                                  r"h2::|hyper::|codec", re.I))]
FOLHA = [("syscalls", re.compile(r"sendmsg|recvmsg|sys_(read|write|sendto|recvfrom)|ksys_|__x64_sys|epoll|"
                                 r"do_syscall|entry_SYSCALL|syscall_cancel")),
         ("kernel net", re.compile(r"tcp_|ip_|netif|net_rx|napi|skb|nf_|nft_|veth|inet_|dev_queue|sock_|udp_|"
                                   r"iowrite16|virtnet|virtqueue|vring")),
         ("scheduling", re.compile(r"schedule|finish_task_switch|futex|__switch_to|pick_next|try_to_wake")),
         ("memory", re.compile(r"memmove|memcpy|memset|malloc|tcmalloc|operator new|free|mmap|page_fault|"
                               r"copy_user|clear_page")),
         ("proxy, unresolved", re.compile(r"^\[linkerd2-proxy\]$|^\[unknown\]$|^\[ztunnel\]$|^\[envoy\]$"))]
CATS = [c for c, _ in PILHA] + [c for c, _ in FOLHA] + ["proxy logic"]
HACHURAS = ["xxx", "...", "///", "\\\\\\", "---", "ooo", "|||", "+++", "**", ""]


def categoria(pilha):
    for nome, rx in PILHA:
        if rx.search(pilha):
            return nome
    folha = pilha.rsplit(";", 1)[-1]
    for nome, rx in FOLHA:
        if rx.search(folha):
            return nome
    return "proxy logic"


def mapas_bpftrace(arq):
    """Contadores @trocas[comm] e @syscalls[comm] do início do perf.txt.gz."""
    m = {"trocas": collections.Counter(), "syscalls": collections.Counter()}
    rx = re.compile(r"^@(trocas|syscalls)\[(.*)\]: (\d+)$")
    with gzip.open(arq, "rt", errors="replace") as f:
        for i, linha in enumerate(f):
            if i > 5000:
                break
            r = rx.match(linha.strip())
            if r:
                m[r.group(1)][r.group(2)] += int(r.group(3))
    return m


def analisa(d):
    meta = json.load(open(os.path.join(d, "meta.json")))
    summ = json.load(open(os.path.join(d, "k6-summary.json")))
    reqs = summ["metrics"]["http_reqs"]["values"]["rate"] * (meta["end"] - meta["start"])
    ns = collections.Counter()
    for arq in glob.glob(os.path.join(d, "*.folded")):
        for linha in open(arq):
            pilha, _, n = linha.rstrip().rpartition(" ")
            comm = pilha.split(";", 1)[0]
            if PROXY.match(comm) or re.search(r"(^|;)(wg_|wireguard|bpf_prog|__bpf_prog_run)", pilha):
                ns[categoria(pilha)] += int(n)
    trocas = syscalls = 0
    for arq in glob.glob(os.path.join(d, "*.perf.txt.gz")):
        m = mapas_bpftrace(arq)
        trocas += sum(v for k, v in m["trocas"].items() if PROXY.match(k))
        syscalls += sum(v for k, v in m["syscalls"].items() if PROXY.match(k))
    lin = {"config": meta["config"], "app": meta["app"], "rate": meta["rate"], "reqs": round(reqs)}
    for c in CATS:
        lin[f"us_{c}"] = ns.get(c, 0) / 1000 / reqs if reqs else 0
    lin["us_total"] = sum(lin[f"us_{c}"] for c in CATS)
    lin["trocas_por_req"] = trocas / reqs if reqs else 0
    lin["syscalls_por_req"] = syscalls / reqs if reqs else 0
    return lin


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("perfil")
    base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "paper")
    ap.add_argument("--tabela", default=os.path.join(base, "tables", "perfil.tex"))
    ap.add_argument("--figura", default=os.path.join(base, "figs", "perfil.pdf"))
    a = ap.parse_args()
    linhas = [analisa(d) for d in sorted(glob.glob(os.path.join(a.perfil, "*", "*")))
              if os.path.isfile(os.path.join(d, "meta.json"))]
    df = pd.DataFrame(linhas)
    df.to_csv(os.path.join(a.perfil, "perfil.csv"), index=False)
    pd.set_option("display.width", 250)
    print(df.round(1).to_string(index=False))

    with open(a.tabela, "w") as f:
        f.write("% gerado por analysis/50_perfil.py\n\\begin{tabular}{ll" + "r" * 5 + "}\n\\toprule\n")
        f.write("App & Config. & CPU ($\\mu$s/req) & TLS+WG & HTTP & cs/req & sys/req \\\\\n\\midrule\n")
        for app in ("echo", "ob"):
            for cfg in ORDEM:
                r = df[(df.app == app) & (df.config == cfg)]
                if r.empty:
                    continue
                r = r.iloc[0]
                cripto = r["us_TLS"] + r["us_wireguard"]
                pct = lambda v: f"{100 * v / r.us_total:.0f}\\%" if r.us_total else "--"
                f.write(f"{app} & {cfg} & {r.us_total:.0f} & {pct(cripto)} & {pct(r['us_HTTP/gRPC'])} & "
                        f"{r.trocas_por_req:.1f} & {r.syscalls_por_req:.1f} \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n")

    plt.rcParams.update({"font.size": 7, "font.family": "serif", "legend.fontsize": 5.5, "legend.frameon": False,
                         "pdf.fonttype": 42})
    fig, axs = plt.subplots(1, 2, figsize=(3.5, 2.1), sharey=False)
    for ax, app in zip(axs, ("echo", "ob")):
        x = df[df.app == app].set_index("config").reindex(ORDEM).dropna(how="all")
        base_ = np.zeros(len(x))
        for k, c in enumerate(CATS):
            v = x[f"us_{c}"].fillna(0).values
            ax.bar(x.index, v, bottom=base_, color="white", edgecolor="black", hatch=HACHURAS[k], linewidth=0.4,
                   label=c)
            base_ += v
        ax.set_title(app)
        ax.tick_params(axis="x", labelsize=6)
    axs[0].set_ylabel("data-plane CPU ($\\mu$s / request)")
    fig.legend(*axs[0].get_legend_handles_labels(), ncol=4, loc="upper center", bbox_to_anchor=(0.5, 1.02))
    fig.tight_layout(pad=0.3, rect=(0, 0, 1, 0.8))
    fig.savefig(a.figura)
    print("->", a.tabela, a.figura)


if __name__ == "__main__":
    main()

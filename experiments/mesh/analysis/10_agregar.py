#!/usr/bin/env python3
"""Agrega uma bateria (05-bateria.sh) numa tabela com uma linha por rodada: cells.csv.

Uso: python 10_agregar.py <diretório da bateria> [--cdf] [--saida cells.csv]

Lê, por rodada (<cfg>/<app>-<carga>-<rep>/): meta.json, k6-summary.json, prom-cpu.json, prom-mem.json e, com
--cdf, o k6-reqs.csv.gz (uma linha por amostra de métrica do k6), de onde tira os percentis exatos de
http_req_duration e grava 1001 quantis por rodada em cdf/<cfg>_<app>_<carga>_<rep>.csv (para as CDFs).
Por configuração lê idle.json (potência ociosa), para a energia líquida.

Colunas de cells.csv:
  config app load rate rep                 identificação (rate = taxa pedida, req/s)
  rps                                      taxa obtida (requisições / duração medida)
  p50_ms p90_ms p99_ms p999_ms max_ms     latência (do csv.gz com --cdf; senão do k6-summary.json)
  err dropped vus_max                      falhas (fração), iterações descartadas, VUs no pico
  seconds pkg_j core_j                     duração e energia RAPL do pacote e dos núcleos
  idle_w                                   potência ociosa da própria configuração (W), medida com o mesh instalado
  idle_extra_w                             idle_w menos a ociosa da B: custo fixo do mesh em repouso
  j_per_req                                energia do pacote por requisição, líquida da ociosa da B (base comum):
                                           (pkg_j - idle_B*seconds)/reqs; inclui o custo fixo do mesh
  cpu_<comp> mem_<comp>                    núcleos médios e MiB médios por componente (ver COMPONENTES)
  mcpu_per_krps_<comp> mib_per_krps_<comp> o mesmo normalizado por 1000 req/s obtidas
"""
import argparse
import csv
import gzip
import json
import os
import sys

# Componente de cada série do Prometheus (labels namespace, pod, container, node), na ordem de teste
COMPONENTES = ["app", "proxy", "ztunnel", "waypoint", "cilium_agent", "cilium_envoy", "istio_cni",
               "control_plane", "outras_apps", "monitoring", "outros"]


def componente(m, app):
    ns, pod, cont = m.get("namespace", ""), m.get("pod", ""), m.get("container", "")
    # ztunnel e waypoint antes do sidecar: o contêiner deles também se chama istio-proxy
    if ns == "istio-system" and pod.startswith("ztunnel"):
        return "ztunnel"                                # proxy L4 por nó (IA4, IA7)
    if pod.startswith("waypoint-"):
        return "waypoint"                               # Envoy compartilhado por namespace (IA7)
    if cont in ("istio-proxy", "linkerd-proxy"):
        return "proxy"                                  # sidecar por pod (IS, LK)
    if ns == "istio-system" and pod.startswith("istio-cni"):
        return "istio_cni"
    if ns == "kube-system" and pod.startswith("cilium-envoy"):
        return "cilium_envoy"                           # Envoy do nó (L7 na CI)
    if ns == "kube-system" and pod.startswith("cilium") and not pod.startswith("cilium-operator"):
        return "cilium_agent"                           # agente/datapath eBPF (CNI em todas; WireGuard na CI)
    if ns in ("istio-system", "linkerd") or pod.startswith("cilium-operator"):
        return "control_plane"                          # istiod, linkerd destination/identity/injector, operador
    if ns == app:
        return "app"                                    # só a aplicação medida na rodada
    if ns in ("echo", "ob", "hotel"):
        return "outras_apps"                            # as outras duas ficam implantadas, ociosas
    if ns == "monitoring":
        return "monitoring"
    return "outros"


def media_por_componente(arquivo, app):
    """Soma das séries de cada componente e média no tempo; {} se o arquivo faltar ou estiver vazio."""
    try:
        with open(arquivo) as f:
            res = json.load(f)["data"]["result"]
    except (OSError, KeyError, ValueError):
        return {}
    soma = {}
    for serie in res:
        vals = [float(v) for _, v in serie.get("values", [])]
        if vals:
            c = componente(serie["metric"], app)
            soma[c] = soma.get(c, 0.0) + sum(vals) / len(vals)
    return soma


def quantil(ordenados, q):
    if not ordenados:
        return ""
    i = q * (len(ordenados) - 1)
    lo = int(i)
    hi = min(lo + 1, len(ordenados) - 1)
    return ordenados[lo] + (ordenados[hi] - ordenados[lo]) * (i - lo)


def duracoes_csv(arquivo):
    """Valores de http_req_duration (ms) do csv do k6: colunas metric_name,timestamp,metric_value,..."""
    vals = []
    with gzip.open(arquivo, "rt", newline="") as f:
        for row in csv.DictReader(f):
            if row.get("metric_name") == "http_req_duration":
                vals.append(float(row["metric_value"]))
    vals.sort()
    return vals


def valor(summary, nome, chave, padrao=""):
    return summary.get("metrics", {}).get(nome, {}).get("values", {}).get(chave, padrao)


def potencia_ociosa(dir_cfg):
    try:
        with open(os.path.join(dir_cfg, "idle.json")) as f:
            idle = json.load(f)
        return idle["joules"]["intel-rapl:0"] / idle["seconds"]
    except (OSError, KeyError, ValueError, ZeroDivisionError):
        return None


def rodada(d, cfg_dir, idle_w, idle_b, cdf_dir):
    with open(os.path.join(d, "meta.json")) as f:
        meta = json.load(f)
    try:
        with open(os.path.join(d, "k6-summary.json")) as f:
            summ = json.load(f)
    except (OSError, ValueError):
        summ = {}
    seconds = float(meta["end"]) - float(meta["start"])
    reqs = valor(summ, "http_reqs", "count", 0) or 0
    rps = reqs / seconds if seconds else 0
    dur = "http_req_duration"
    lat = {"p50_ms": valor(summ, dur, "med"), "p90_ms": valor(summ, dur, "p(90)"),
           "p99_ms": valor(summ, dur, "p(99)"), "p999_ms": valor(summ, dur, "p(99.9)"),
           "max_ms": valor(summ, dur, "max")}
    csv_gz = os.path.join(d, "k6-reqs.csv.gz")
    if cdf_dir and os.path.isfile(csv_gz):
        v = duracoes_csv(csv_gz)
        if v:
            lat = {"p50_ms": quantil(v, .5), "p90_ms": quantil(v, .9), "p99_ms": quantil(v, .99),
                   "p999_ms": quantil(v, .999), "max_ms": v[-1]}
            nome = f"{meta['config']}_{meta['app']}_{meta['load']}_{meta['rep']}.csv"
            with open(os.path.join(cdf_dir, nome), "w") as f:
                f.write("q,ms\n")
                for i in range(1001):
                    f.write(f"{i / 1000:.3f},{quantil(v, i / 1000):.4f}\n")
    pkg_j = meta["joules"].get("intel-rapl:0")
    core_j = meta["joules"].get("intel-rapl:0:0")
    j_req = ""
    if pkg_j is not None and idle_b is not None and reqs:
        j_req = (pkg_j - idle_b * seconds) / reqs
    cpu = media_por_componente(os.path.join(d, "prom-cpu.json"), meta["app"])
    mem = media_por_componente(os.path.join(d, "prom-mem.json"), meta["app"])
    linha = {"config": meta["config"], "app": meta["app"], "load": meta["load"], "rate": meta["rate"],
             "rep": meta["rep"], "rps": round(rps, 2), **lat,
             "err": valor(summ, "http_req_failed", "rate"),
             "dropped": valor(summ, "dropped_iterations", "count", 0),
             "vus_max": valor(summ, "vus_max", "value"),
             "seconds": round(seconds, 3), "pkg_j": pkg_j, "core_j": core_j,
             "idle_w": round(idle_w, 3) if idle_w is not None else "",
             "idle_extra_w": round(idle_w - idle_b, 3) if None not in (idle_w, idle_b) else "",
             "j_per_req": j_req}
    for c in COMPONENTES:
        linha[f"cpu_{c}"] = round(cpu.get(c, 0.0), 5)
        linha[f"mem_{c}"] = round(mem.get(c, 0.0) / 2**20, 2)
    for c in COMPONENTES:
        linha[f"mcpu_per_krps_{c}"] = round(1000 * cpu.get(c, 0.0) / (rps / 1000), 3) if rps else ""
        linha[f"mib_per_krps_{c}"] = round(mem.get(c, 0.0) / 2**20 / (rps / 1000), 3) if rps else ""
    return linha


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bateria")
    ap.add_argument("--cdf", action="store_true", help="ler os csv.gz (lento) e gravar quantis por rodada")
    ap.add_argument("--saida", default=None)
    a = ap.parse_args()
    saida = a.saida or os.path.join(a.bateria, "cells.csv")
    cdf_dir = os.path.join(a.bateria, "cdf") if a.cdf else None
    if cdf_dir:
        os.makedirs(cdf_dir, exist_ok=True)
    linhas = []
    for cfg in sorted(os.listdir(a.bateria)):
        cfg_dir = os.path.join(a.bateria, cfg)
        if not os.path.isdir(cfg_dir) or cfg == "cdf":
            continue
        idle_w = potencia_ociosa(cfg_dir)
        idle_b = potencia_ociosa(os.path.join(a.bateria, "B"))   # base comum: ociosa da configuração sem mesh
        for r in sorted(os.listdir(cfg_dir)):
            d = os.path.join(cfg_dir, r)
            if os.path.isfile(os.path.join(d, "meta.json")):
                linhas.append(rodada(d, cfg_dir, idle_w, idle_b, cdf_dir))
    if not linhas:
        sys.exit(f"nenhuma rodada com meta.json em {a.bateria}")
    with open(saida, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(linhas[0]))
        w.writeheader()
        w.writerows(linhas)
    print(f"{len(linhas)} rodadas -> {saida}")


if __name__ == "__main__":
    main()

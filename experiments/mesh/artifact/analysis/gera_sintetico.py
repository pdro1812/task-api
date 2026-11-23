#!/usr/bin/env python3
"""Gera uma bateria falsa, no mesmo formato do 05-bateria.sh, para testar os scripts de análise.

Uso: python gera_sintetico.py <diretório> [--reps 3]
Os números são inventados (acréscimo de latência e de CPU crescente com o mesh); não servem para conclusões.
"""
import argparse
import csv
import gzip
import json
import os
import random

CFGS = {"B": (0.0, 0.0), "IS": (1.2, 0.35), "IA4": (0.3, 0.12), "IA7": (0.9, 0.25), "LK": (0.7, 0.2), "CI": (0.5, 0.15)}
SAT = {"echo": 14000, "ob": 1500, "hotel": 1000}
BASE_MS = {"echo": 1.5, "ob": 9.0, "hotel": 6.0}


def prom(series, t0, t1):
    pts = int((t1 - t0) // 5) + 1
    return {"status": "success", "data": {"resultType": "matrix", "result": [
        {"metric": m, "values": [[t0 + 5 * i, str(max(0.0, v * random.uniform(0.9, 1.1)))] for i in range(pts)]}
        for m, v in series]}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--reps", type=int, default=3)
    a = ap.parse_args()
    random.seed(1)
    for cfg, (lat_extra, cpu_extra) in CFGS.items():
        os.makedirs(os.path.join(a.dir, cfg), exist_ok=True)
        json.dump({"seconds": 60, "joules": {"intel-rapl:0": 60 * 25.0, "intel-rapl:0:0": 60 * 8.0}},
                  open(os.path.join(a.dir, cfg, "idle.json"), "w"))
        for app, sat in SAT.items():
            for load in (30, 60, 90):
                rate = sat * load // 100
                for rep in range(1, a.reps + 1):
                    d = os.path.join(a.dir, cfg, f"{app}-{load}-{rep}")
                    os.makedirs(d, exist_ok=True)
                    t0, t1 = 1_800_000_000.0 + rep * 1000, 1_800_000_180.0 + rep * 1000
                    rho = load / 100
                    media = BASE_MS[app] + lat_extra * {"echo": 3, "ob": 9, "hotel": 7}[app] / (1 - 0.8 * rho)
                    n = 2000
                    durs = sorted(random.expovariate(1 / media) + 0.3 * media for _ in range(n))
                    with gzip.open(os.path.join(d, "k6-reqs.csv.gz"), "wt", newline="") as f:
                        w = csv.writer(f)
                        w.writerow(["metric_name", "timestamp", "metric_value", "check", "error", "error_code",
                                    "expected_response", "group", "method", "name", "proto", "scenario", "service",
                                    "status", "subproto", "tls_version", "url", "extra_tags", "metadata"])
                        for x in durs:
                            w.writerow(["http_reqs", int(t0), 1] + [""] * 16)
                            w.writerow(["http_req_duration", int(t0), f"{x:.4f}"] + [""] * 16)
                    q = lambda p: durs[int(p * (n - 1))]
                    reqs = int(rate * 180 * random.uniform(0.995, 1.0))
                    json.dump({"metrics": {
                        "http_reqs": {"values": {"count": reqs, "rate": reqs / 180}},
                        "http_req_duration": {"values": {"med": q(.5), "p(90)": q(.9), "p(99)": q(.99),
                                                         "p(99.9)": q(.999), "max": durs[-1], "avg": media}},
                        "http_req_failed": {"values": {"rate": 0.0}},
                        "dropped_iterations": {"values": {"count": 0}},
                        "vus_max": {"values": {"value": 200}}}}, open(os.path.join(d, "k6-summary.json"), "w"))
                    krps = rate / 1000
                    cpu = [({"namespace": app, "pod": f"{app}-x", "container": "server", "node": "w1"}, 0.4 * krps)]
                    if cfg in ("IS", "LK"):
                        cpu.append(({"namespace": app, "pod": f"{app}-x", "container":
                                     "istio-proxy" if cfg == "IS" else "linkerd-proxy", "node": "w1"}, cpu_extra * krps))
                    if cfg in ("IA4", "IA7"):
                        cpu.append(({"namespace": "istio-system", "pod": "ztunnel-a", "container": "istio-proxy",
                                     "node": "w1"}, cpu_extra * krps))
                    if cfg == "IA7":
                        cpu.append(({"namespace": app, "pod": "waypoint-a", "container": "istio-proxy",
                                     "node": "w2"}, cpu_extra * krps))
                    cpu.append(({"namespace": "kube-system", "pod": "cilium-abc", "container": "cilium-agent",
                                 "node": "w1"}, 0.05 + (cpu_extra * krps if cfg == "CI" else 0)))
                    cpu.append(({"namespace": "kube-system", "pod": "cilium-envoy-abc", "container": "cilium-envoy",
                                 "node": "w1"}, cpu_extra * krps if cfg == "CI" else 0.001))
                    mem = [(m, 50e6 + 20e6 * v) for m, v in cpu]
                    json.dump(prom(cpu, t0, t1), open(os.path.join(d, "prom-cpu.json"), "w"))
                    json.dump(prom(mem, t0, t1), open(os.path.join(d, "prom-mem.json"), "w"))
                    json.dump(prom([({"instance": "w1", "mode": "idle"}, 2.0)], t0, t1),
                              open(os.path.join(d, "prom-node-cpu.json"), "w"))
                    watts = 25 + 10 * rho + 8 * cpu_extra * krps / 10
                    json.dump({"config": cfg, "app": app, "load": str(load), "rate": rate, "rep": rep,
                               "start": t0, "end": t1,
                               "joules": {"intel-rapl:0": watts * 180, "intel-rapl:0:0": 0.4 * watts * 180}},
                              open(os.path.join(d, "meta.json"), "w"))
    print(f"bateria sintética em {a.dir}")


if __name__ == "__main__":
    main()

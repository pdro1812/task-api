#!/usr/bin/env python3
"""Utilização de CPU por nó (cp, w1, w2, w3) em cada rodada, a partir do prom-node-cpu.json (node_exporter).
Utilização = (soma dos modos menos idle e iowait) / (soma de todos os modos), isto é, a fração das vCPUs da VM.
Mediana por config x app x carga. Uso: 12_node_util.py <bateria> [saída.csv]"""
import csv, json, statistics, sys
from collections import defaultdict
from pathlib import Path

NODE = {"192.168.150.10": "cp", "192.168.150.11": "w1", "192.168.150.12": "w2", "192.168.150.13": "w3"}


def util_rodada(path):
    res = json.load(open(path))["data"]["result"]
    tot, ocioso = defaultdict(list), defaultdict(list)
    por = defaultdict(lambda: defaultdict(float))  # nó -> instante -> soma
    oc = defaultdict(lambda: defaultdict(float))
    for s in res:
        no = NODE.get(s["metric"]["instance"].split(":")[0])
        if no is None:
            continue
        for t, v in s["values"]:
            por[no][t] += float(v)
            if s["metric"]["mode"] in ("idle", "iowait"):
                oc[no][t] += float(v)
    out = {}
    for no, serie in por.items():
        u = [1 - oc[no][t] / serie[t] for t in serie if serie[t] > 0]
        if u:
            out[no] = statistics.mean(u)
    return out


def main():
    bat = Path(sys.argv[1])
    saida = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).parent / "out" / "node_util.csv"
    cel = defaultdict(lambda: defaultdict(list))
    for meta in bat.glob("*/*/meta.json"):
        m = json.load(open(meta))
        f = meta.parent / "prom-node-cpu.json"
        if not f.exists():
            continue
        for no, u in util_rodada(f).items():
            cel[(m["config"], m["app"], int(m["load"]), m["rate"])][no].append(u)
    ordem = {c: i for i, c in enumerate("B IS IA4 IA7 LK CI CI4".split())}
    saida.parent.mkdir(parents=True, exist_ok=True)
    with open(saida, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["config", "app", "load", "rate", "reps", "cp", "w1", "w2", "w3"])
        for k in sorted(cel, key=lambda k: (k[1], k[2], ordem.get(k[0], 99), k[0])):
            d = cel[k]
            w.writerow([*k, len(d.get("w1", []))] + [f"{statistics.median(d[n]):.3f}" if d.get(n) else "" for n in ("cp", "w1", "w2", "w3")])
    print(saida)


if __name__ == "__main__":
    main()

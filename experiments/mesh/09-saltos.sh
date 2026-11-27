#!/usr/bin/env bash
# Mede o grafo de chamadas de cada aplicação (para o modelo do RQ3): na IS, carga de 30% da base da bateria por
# 3 min e leitura dos contadores dos sidecars (istio_requests_total e istio_tcp_connections_opened_total, lado
# cliente) antes e depois. Por requisição externa: chamadas internas HTTP/gRPC (H) e conexões TCP a bancos, cada
# aresta marcada como "mesmo nó" ou "entre nós" pela posição fixa dos pods (igual em todas as configurações).
# Uso: ./09-saltos.sh [saída.json]   Padrão: /mnt/dados/resultados/hops.json. Deixa o cluster na B no fim.
source "$(dirname "$0")/lib/common.sh"
source "$MESH_DIR/lib/measure.sh"
OUT=${1:-/mnt/dados/resultados/hops.json}
TMP="$STATE/saltos"; rm -rf "$TMP"; mkdir -p "$TMP"
[ "$(cat "$STATE/config-atual" 2>/dev/null)" = IS ] || "$MESH_DIR/03-config.sh" IS > "$TMP/IS-config.log" 2>&1 \
  || die "03-config.sh IS falhou"

contadores() {  # $1 app, $2 arquivo: métricas do lado cliente de todos os sidecars do namespace
  local p
  for p in $(kubectl -n "$1" get pods -o name); do
    kubectl -n "$1" exec "$p" -c istio-proxy -- pilot-agent request GET stats/prometheus 2>/dev/null \
      | grep -E '^istio_(requests_total|tcp_connections_opened_total)\{' | grep 'reporter="source"' || true
  done > "$2"   # || true: sidecar sem chamadas de saída não tem a métrica (grep vazio sai com 1)
}

for app in echo ob hotel; do
  base=$(sat_min "$app" B IS IA4 IA7 LK CI) || exit 1; rate=$(( base * 30 / 100 ))
  step "$app a $rate req/s por 180 s"
  k6_run "$app" "$rate" 30s >/dev/null 2>&1 || true
  contadores "$app" "$TMP/$app-antes.txt"
  SUMMARY="$TMP/$app-k6.json" k6_run "$app" "$rate" 180s >/dev/null 2>&1 || true
  sleep 5
  contadores "$app" "$TMP/$app-depois.txt"
  kubectl -n "$app" get pods -o json | jq -r '.items[] | "\(.metadata.labels.app // .metadata.labels["io.kompose.service"]) \(.spec.nodeName)"' \
    > "$TMP/$app-nos.txt"
done

python3 - "$TMP" "$OUT" <<'PY'
import json, re, sys, collections
tmp, out = sys.argv[1], sys.argv[2]
rx = re.compile(r'^(istio_\w+)\{(.*)\} ([0-9.e+]+)$')
def ler(f):
    d = collections.Counter()
    for linha in open(f):
        m = rx.match(linha.strip())
        if not m: continue
        lab = dict(re.findall(r'(\w+)="([^"]*)"', m.group(2)))
        d[(m.group(1), lab.get("source_workload"), lab.get("destination_workload"))] += float(m.group(3))
    return d
res = {}
for app in ("echo", "ob", "hotel"):
    a, b = ler(f"{tmp}/{app}-antes.txt"), ler(f"{tmp}/{app}-depois.txt")
    reqs = json.load(open(f"{tmp}/{app}-k6.json"))["metrics"]["http_reqs"]["values"]["count"]
    no = dict(l.split() for l in open(f"{tmp}/{app}-nos.txt") if len(l.split()) == 2)
    arestas = []
    for k in b:
        m, s, d = k
        n = b[k] - a.get(k, 0)
        if n <= 0 or d in ("unknown", None) or s == d: continue
        tipo = "rpc" if m == "istio_requests_total" else "tcp"
        mesmo = no.get(s) is not None and no.get(s) == no.get(d)
        arestas.append({"de": s, "para": d, "tipo": tipo, "por_req": n / reqs, "mesmo_no": mesmo})
    soma = lambda t, mn: sum(e["por_req"] for e in arestas if e["tipo"] == t and e["mesmo_no"] == mn)
    res[app] = {"requisicoes_k6": reqs,
                "rpc_entre_nos": soma("rpc", False), "rpc_mesmo_no": soma("rpc", True),
                "tcp_entre_nos": soma("tcp", False), "tcp_mesmo_no": soma("tcp", True),
                "arestas": sorted(arestas, key=lambda e: -e["por_req"])}
    print(app, {k: round(v, 3) for k, v in res[app].items() if k != "arestas"})
json.dump(res, open(out, "w"), indent=1)
print("->", out)
PY
"$MESH_DIR/03-config.sh" B > "$TMP/B-config.log" 2>&1 || warn "não voltou à B"
# Observação: o salto de entrada (k6 -> pod de borda) não aparece aqui (o k6 está fora do mesh); conta como +1
# travessia de proxy do lado servidor nas configurações com sidecar.

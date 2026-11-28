#!/usr/bin/env bash
# Operações de banco por requisição externa (complementa hops.json, que só conta chamadas gRPC: as conexões TCP em
# pool para MongoDB, memcached e redis não abrem conexões novas durante a medição). Na B, para HR e OB: lê os
# contadores de cada banco antes e depois de uma carga conhecida (30% da base, 120 s) e divide pelas requisições do k6.
#   MongoDB: db.serverStatus().opcounters (query, insert, update, delete, getmore, command)
#   memcached: stats (cmd_get, cmd_set, cmd_touch, delete_hits, delete_misses), via kubectl port-forward
#   redis: INFO commandstats (soma das chamadas, menos INFO)
# Uso: ./15a-ops-bancos.sh [saída.json]   Padrão: /mnt/dados/resultados/ops-bancos.json
source "$(dirname "$0")/lib/common.sh"
source "$MESH_DIR/lib/measure.sh"
OUT=${1:-/mnt/dados/resultados/ops-bancos.json}
TMP=$(mktemp -d)
[ "$(cat "$STATE/config-atual" 2>/dev/null)" = B ] || "$MESH_DIR/03-config.sh" B > "$TMP/B-config.log" 2>&1 || die "03-config.sh B falhou"

mongo_ops() {  # $1 ns, $2 pod
  kubectl -n "$1" exec "$2" -- mongo --quiet --eval \
    'var o=db.serverStatus().opcounters; print(o.query+o.insert+o.update+o.delete+o.getmore+o.command)' 2>/dev/null | tail -1
}
memcached_ops() {  # $1 ns, $2 pod
  local porta=$((20000 + RANDOM % 10000)) pf v
  kubectl -n "$1" port-forward "pod/$2" "$porta:11211" >/dev/null 2>&1 & pf=$!
  sleep 2
  v=$(python3 - "$porta" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.sendall(b"stats\r\n"); d = b""
while not d.endswith(b"END\r\n"):
    d += s.recv(65536)
st = dict(l.split()[1:3] for l in d.decode().splitlines() if l.startswith("STAT"))
print(sum(int(st.get(k, 0)) for k in ("cmd_get", "cmd_set", "cmd_touch", "delete_hits", "delete_misses")))
PY
)
  kill "$pf" 2>/dev/null || true; wait "$pf" 2>/dev/null || true
  echo "$v"
}
redis_ops() {  # $1 ns, $2 pod
  kubectl -n "$1" exec "$2" -- redis-cli INFO commandstats 2>/dev/null \
    | awk -F'[:=,]' '/^cmdstat_/ && $1 != "cmdstat_info" {s += $3} END {print s + 0}'
}
contadores() {  # $1 ns -> linhas "pod tipo ops nó"
  kubectl -n "$1" get pods --no-headers -o custom-columns=N:.metadata.name,NO:.spec.nodeName | while read -r p no; do
    case $p in
      mongodb-*) echo "$p mongodb $(mongo_ops "$1" "$p") $no" ;;
      memcached-*) echo "$p memcached $(memcached_ops "$1" "$p") $no" ;;
      redis-*) echo "$p redis $(redis_ops "$1" "$p") $no" ;;
    esac
  done
}

echo "{" > "$TMP/out.json"
primeiro=1
for app in hotel ob; do
  base=$(sat_min "$app" B IS IA4 IA7 LK CI) || exit 1; rate=$(( base * 30 / 100 ))
  step "$app a $rate req/s por 120 s"
  k6_run "$app" "$rate" 30s >/dev/null 2>&1 || true
  contadores "$app" > "$TMP/$app-antes.txt"
  SUMMARY="$TMP/$app-k6.json" k6_run "$app" "$rate" 120s >/dev/null 2>&1 || warn "k6 terminou com erro ($app)"
  contadores "$app" > "$TMP/$app-depois.txt"
  reqs=$(jq '.metrics.http_reqs.values.count' "$TMP/$app-k6.json")
  [ $primeiro = 1 ] || echo "," >> "$TMP/out.json"; primeiro=0
  python3 - "$app" "$reqs" "$TMP/$app-antes.txt" "$TMP/$app-depois.txt" >> "$TMP/out.json" <<'PY'
import json, sys
app, reqs = sys.argv[1], float(sys.argv[2])
def le(f):
    return {l.split()[0]: l.split() for l in open(f) if len(l.split()) == 4}
a, d = le(sys.argv[3]), le(sys.argv[4])
bancos = []
for p, (_, tipo, ops, no) in d.items():
    if p in a and ops.isdigit() and a[p][2].isdigit():
        bancos.append({"pod": p, "tipo": tipo, "no": no, "ops_por_req": (int(ops) - int(a[p][2])) / reqs})
print(json.dumps(app) + ": " + json.dumps({"requisicoes_k6": reqs, "bancos": bancos}, indent=1))
PY
done
echo "}" >> "$TMP/out.json"
jq . "$TMP/out.json" > "$OUT" && cat "$OUT"

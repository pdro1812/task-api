#!/usr/bin/env bash
# Cenário 2: indisponibilidade do Redis.
# Para cada rodada: inicia a carga, derruba o Redis em T=FAIL_AT, restaura em T=RECOVER_AT.
# Uso: MODE=failfast RUNS=10 ./experiments/run-redis-outage.sh
# Pré-requisito: kubectl port-forward -n task-api svc/task-api-service 8080:80 (ou um Ingress)
set -euo pipefail
NS=${NS:-task-api}
MODE=${MODE:-failfast}
RUNS=${RUNS:-10}
FAIL_AT=${FAIL_AT:-30}
RECOVER_AT=${RECOVER_AT:-90}
DURATION=${DURATION:-150}
OUT=${OUT:-experiments/results}
mkdir -p "$OUT"

for i in $(seq 1 "$RUNS"); do
  echo "== rodada $i ($MODE)"
  kubectl -n "$NS" rollout status deploy/redis --timeout=120s
  kubectl -n "$NS" rollout status deploy/task-api --timeout=120s
  k6 run -q -e DURATION="${DURATION}s" --out csv="$OUT/redis-$MODE-$i.csv" experiments/k6/carga-constante.js &
  K6=$!
  sleep "$FAIL_AT"
  date +%s.%N > "$OUT/redis-$MODE-$i.fail"
  kubectl -n "$NS" scale deploy/redis --replicas=0
  sleep $((RECOVER_AT - FAIL_AT))
  date +%s.%N > "$OUT/redis-$MODE-$i.recover"
  kubectl -n "$NS" scale deploy/redis --replicas=1
  wait "$K6" || true
  # Evidência do comportamento do orquestrador: reinícios e endpoints do Service
  kubectl -n "$NS" get pods -o wide > "$OUT/redis-$MODE-$i.pods"
  sleep 20
done

#!/usr/bin/env bash
# Cenário: falha do Redis sob carga.
# Para cada rodada: inicia a carga, provoca a falha em T=FAIL_AT e a desfaz em T=RECOVER_AT.
#   FAULT=outage (padrão): Redis indisponível (scale 0 → 1; a conexão é fechada)
#   FAULT=pause:           Redis pendurado (CLIENT PAUSE ALL; a conexão continua aberta, os comandos não respondem)
# Uso: MODE=failfast RUNS=10 ./experiments/run-redis-outage.sh
#   START=n retoma da rodada n; MONITOR=1 grava EndpointSlices, CPU, /metrics e o Pod do Redis (experiments/monitor.sh);
#   COUNT_TASKS=1 grava em <base>.tasks o LLEN da lista de tarefas antes da falha e depois da recuperação.
# Pré-requisito: tráfego pelo Service (NodePort/Ingress) em BASE_URL; port-forward ignora readiness.
set -euo pipefail
NS=${NS:-task-api}
MODE=${MODE:-failfast}
RUNS=${RUNS:-10}
FAULT=${FAULT:-outage}
FAIL_AT=${FAIL_AT:-30}
RECOVER_AT=${RECOVER_AT:-90}
DURATION=${DURATION:-150}
OUT=${OUT:-experiments/results}
PREFIX=${PREFIX:-$([ "$FAULT" = pause ] && echo pausa || echo redis)}
mkdir -p "$OUT"
[ "${MONITOR:-0}" = 1 ] && source "$(dirname "$0")/monitor.sh"

redis_cli() {
  local pass
  pass=$(kubectl -n "$NS" get secret task-api-secret -o jsonpath='{.data.REDIS_PASSWORD}' | base64 -d)
  kubectl -n "$NS" exec deploy/redis -- redis-cli -a "$pass" --no-auth-warning "$@"
}

for i in $(seq "${START:-1}" "$RUNS"); do
  base="$OUT/$PREFIX-$MODE-$i"
  echo "== rodada $i ($MODE, $FAULT)"
  kubectl -n "$NS" rollout status deploy/redis --timeout=120s
  kubectl -n "$NS" rollout status deploy/task-api --timeout=120s
  [ "${MONITOR:-0}" = 1 ] && monitor_start "$base"
  k6 run -q -e DURATION="${DURATION}s" --out csv="$base.csv" experiments/k6/carga-constante.js &
  K6=$!
  sleep "$FAIL_AT"
  [ "${COUNT_TASKS:-0}" = 1 ] && echo "antes $(redis_cli LLEN tasks)" > "$base.tasks"
  date +%s.%N > "$base.fail"
  if [ "$FAULT" = pause ]; then
    redis_cli CLIENT PAUSE $(( (RECOVER_AT - FAIL_AT) * 1000 )) ALL
  else
    kubectl -n "$NS" scale deploy/redis --replicas=0
  fi
  sleep $((RECOVER_AT - FAIL_AT))
  date +%s.%N > "$base.recover"
  [ "$FAULT" = pause ] || kubectl -n "$NS" scale deploy/redis --replicas=1
  wait "$K6" || true
  [ "${MONITOR:-0}" = 1 ] && monitor_stop
  if [ "${COUNT_TASKS:-0}" = 1 ]; then
    kubectl -n "$NS" rollout status deploy/redis --timeout=180s >/dev/null
    until redis_cli PING 2>/dev/null | grep -q PONG; do sleep 1; done
    echo "depois $(redis_cli LLEN tasks)" >> "$base.tasks"
  fi
  # Evidência do comportamento do orquestrador: reinícios e endpoints do Service
  kubectl -n "$NS" get pods -o wide > "$base.pods"
  sleep 20
done

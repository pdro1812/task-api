#!/usr/bin/env bash
# Cenário: rollback de uma versão quebrada sob carga (imagem cujo /ready sempre responde 503).
# Por rodada: carga constante; em T=DEPLOY_AT troca para BROKEN_IMAGE; o operador detecta a falha quando
# `rollout status` estoura DETECT segundos; então faz `kubectl rollout undo` e mede até o Deployment estabilizar.
# Um medidor independente consulta /version a cada 100 ms (a versão quebrada nunca deveria responder).
# Uso: GOOD_IMAGE=task-api:exp-<sha> BROKEN_IMAGE=task-api:exp-quebrada RUNS=10 ./experiments/run-broken-rollback.sh
set -euo pipefail
NS=${NS:-task-api}
RUNS=${RUNS:-10}
DEPLOY_AT=${DEPLOY_AT:-30}
DETECT=${DETECT:-60}
DURATION=${DURATION:-150}
OUT=${OUT:-experiments/results}
GOOD_IMAGE=${GOOD_IMAGE:?defina GOOD_IMAGE}
BROKEN_IMAGE=${BROKEN_IMAGE:?defina BROKEN_IMAGE}
BASE_URL=${BASE_URL:?defina BASE_URL}
mkdir -p "$OUT"
[ "${MONITOR:-0}" = 1 ] && source "$(dirname "$0")/monitor.sh"

for i in $(seq "${START:-1}" "$RUNS"); do
  base="$OUT/quebrada-$i"
  echo "== rodada $i (versão quebrada)"
  kubectl -n "$NS" set image deploy/task-api task-api="$GOOD_IMAGE" >/dev/null
  kubectl -n "$NS" rollout status deploy/task-api --timeout=180s
  sleep 5
  [ "${MONITOR:-0}" = 1 ] && monitor_start "$base"
  python3 "$(dirname "$0")/poll-version.py" "$BASE_URL" "$base.versions" 0.1 &
  POLL=$!
  k6 run -q -e DURATION="${DURATION}s" --out csv="$base.csv" experiments/k6/carga-constante.js &
  K6=$!
  sleep "$DEPLOY_AT"
  date +%s.%N > "$base.deploy"
  kubectl -n "$NS" set image deploy/task-api task-api="$BROKEN_IMAGE" >/dev/null
  if kubectl -n "$NS" rollout status deploy/task-api --timeout="${DETECT}s"; then
    echo "AVISO: o rollout da versão quebrada concluiu (não deveria)" | tee "$base.aviso"
  fi
  date +%s.%N > "$base.detect"
  kubectl -n "$NS" rollout undo deploy/task-api >/dev/null
  date +%s.%N > "$base.undo"
  kubectl -n "$NS" rollout status deploy/task-api --timeout=180s
  # Estável = nenhum Pod da versão quebrada restante
  until [ -z "$(kubectl -n "$NS" get pods -l app=task-api -o jsonpath="{range .items[?(@.spec.containers[0].image=='$BROKEN_IMAGE')]}{.metadata.name}{end}")" ]; do sleep 0.2; done
  date +%s.%N > "$base.done"
  wait "$K6" || true
  kill "$POLL"; wait "$POLL" 2>/dev/null || true
  [ "${MONITOR:-0}" = 1 ] && monitor_stop
  kubectl -n "$NS" get pods -o wide > "$base.pods"
  kubectl -n "$NS" rollout history deploy/task-api > "$base.history"
  sleep 15
done

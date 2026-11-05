#!/usr/bin/env bash
# C2: rolling update sob carga. Compara configurações (com/sem preStop, com/sem tini etc.)
# alternando a imagem entre duas tags já publicadas.
# Uso: LABEL=prestop TAG_A=abc123 TAG_B=def456 RUNS=10 ./experiments/run-rolling-update.sh
#   A rodada 1 troca para TAG_B: comece com a imagem em TAG_A. MONITOR=1 grava os monitores de experiments/monitor.sh.
set -euo pipefail
NS=${NS:-task-api}
IMAGE=${IMAGE:?defina IMAGE, ex.: usuario/task-api}
LABEL=${LABEL:-default}
RUNS=${RUNS:-10}
DEPLOY_AT=${DEPLOY_AT:-30}
OUT=${OUT:-experiments/results}
mkdir -p "$OUT"
[ "${MONITOR:-0}" = 1 ] && source "$(dirname "$0")/monitor.sh"

for i in $(seq 1 "$RUNS"); do
  TAG=$([ $((i % 2)) -eq 1 ] && echo "$TAG_B" || echo "$TAG_A")
  echo "== rodada $i ($LABEL) -> $TAG"
  [ "${MONITOR:-0}" = 1 ] && monitor_start "$OUT/rolling-$LABEL-$i"
  k6 run -q -e DURATION=90s --out csv="$OUT/rolling-$LABEL-$i.csv" experiments/k6/carga-constante.js &
  K6=$!
  sleep "$DEPLOY_AT"
  date +%s.%N > "$OUT/rolling-$LABEL-$i.deploy"
  # Obs.: com o ArgoCD em selfHeal, desative a sincronização automática durante este cenário
  # ou faça a troca de tag via commit no repositório de manifestos.
  kubectl -n "$NS" set image deploy/task-api task-api="$IMAGE:$TAG"
  kubectl -n "$NS" rollout status deploy/task-api --timeout=180s
  date +%s.%N > "$OUT/rolling-$LABEL-$i.done"
  wait "$K6" || true
  [ "${MONITOR:-0}" = 1 ] && monitor_stop
  kubectl -n "$NS" get pods -o wide > "$OUT/rolling-$LABEL-$i.pods"
  sleep 15
done

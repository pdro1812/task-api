#!/usr/bin/env bash
# Cenário 1: rolling update sob carga. Compara configurações (com/sem preStop, com/sem tini etc.)
# alternando a imagem entre duas tags já publicadas.
# Uso: LABEL=prestop TAG_A=abc123 TAG_B=def456 RUNS=10 ./experiments/run-rolling-update.sh
set -euo pipefail
NS=${NS:-task-api}
IMAGE=${IMAGE:?defina IMAGE, ex.: usuario/task-api}
LABEL=${LABEL:-default}
RUNS=${RUNS:-10}
DEPLOY_AT=${DEPLOY_AT:-30}
OUT=${OUT:-experiments/results}
mkdir -p "$OUT"

for i in $(seq 1 "$RUNS"); do
  TAG=$([ $((i % 2)) -eq 1 ] && echo "$TAG_B" || echo "$TAG_A")
  echo "== rodada $i ($LABEL) -> $TAG"
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
  sleep 15
done

#!/usr/bin/env bash
# Refação do C1 em ordem aleatória: cada (configuração, rodada) é sorteada; antes de cada rodada a API é
# reconfigurada (RESILIENCE_MODE / READINESS_DEPENDS_ON_REDIS). Monitores ligados e VUs suficientes para o k6
# não descartar iterações. Retoma do ponto em que parou (pula rodadas com .pods já gravado).
# Uso: CONFIGS="failfast:true:noreuse breaker:true:noreuse" RUNS=10 SEED=1 FAULT=outage \
#        OUT=experiments/results/v2 BASE_URL=http://IP:30080 ./experiments/run-c1-randomizado.sh
#   configuração = modo:readiness(true|false):cliente(keepalive|noreuse)
set -euo pipefail
NS=${NS:-task-api}
RUNS=${RUNS:-10}
SEED=${SEED:-1}
FAULT=${FAULT:-outage}
OUT=${OUT:-experiments/results/v2}
CONFIGS=${CONFIGS:?defina CONFIGS}
export OUT FAULT MONITOR=1 PRE_VUS=${PRE_VUS:-600} MAX_VUS=${MAX_VUS:-1000} BASE_URL=${BASE_URL:?defina BASE_URL}
PREFIX=$([ "$FAULT" = pause ] && echo pausa || echo redis)
mkdir -p "$OUT"

schedule=$(for c in $CONFIGS; do for i in $(seq 1 "$RUNS"); do echo "$c $i"; done; done \
  | shuf --random-source=<(yes "$SEED"))
echo "$schedule" > "$OUT/ordem-$PREFIX.txt"

while read -r cfg i; do
  IFS=: read -r mode rd client <<< "$cfg"
  suffix=""; [ "$client" = noreuse ] && suffix=-noreuse
  name="$mode-rd$rd$suffix"
  [ -f "$OUT/$PREFIX-$name-$i.pods" ] && continue
  echo "[$(date +%T)] $name rodada $i" | tee -a "$OUT/run.log"
  kubectl -n "$NS" set env deploy/task-api RESILIENCE_MODE="$mode" READINESS_DEPENDS_ON_REDIS="$rd" >/dev/null
  kubectl -n "$NS" rollout status deploy/task-api --timeout=180s >/dev/null
  sleep 10
  NO_REUSE=$([ "$client" = noreuse ] && echo 1 || echo 0) MODE="$name" START="$i" RUNS="$i" \
    bash "$(dirname "$0")/run-redis-outage.sh" >> "$OUT/run.log" 2>&1
done <<< "$schedule"
echo "[$(date +%T)] FIM" | tee -a "$OUT/run.log"

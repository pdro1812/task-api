#!/usr/bin/env bash
# Saturação complementar (21/11), depois do 11-noturno.sh:
#   1. CI4: busca inicial (passos de 25%, grava SAT_*_CI4 em .state/saturacao.env, que a bateria não usa: sat_min
#      é sempre sobre as 6 configurações originais), bissecção (SATF_) e duas subidas sem censura (SATR_)
#      -> <res>/ci4/saturacao/
#   2. as demais células (não censuradas) com a mesma subida, 2 repetições: 11-noturno.sh com FIM estendido
# Espera o 11-noturno.sh em curso terminar. Uso: setsid nohup ./12-saturacao-extra.sh [resultados] > /dev/null 2>&1 < /dev/null &
source "$(dirname "$0")/lib/common.sh"
RES=${1:-/mnt/dados/resultados}
D="$RES/ci4/saturacao"; mkdir -p "$D"
LOG="$RES/saturacao-extra.log"
exec >> "$LOG" 2>&1
log() { echo "[$(date '+%F %T')] $*"; }
while pgrep -f '^bash ./11-noturno\.sh' >/dev/null; do sleep 30; done
log "início"
cp "$STATE/saturacao.env" "$D/saturacao.env.antes"
if [ ! -f "$D/sobe2.env" ]; then
  "$MESH_DIR/03-config.sh" CI4 > "$D/03-CI4.log" 2>&1 || { log "03-config CI4 falhou"; exit 1; }
  grep -q '^SAT_hotel_CI4=' "$STATE/saturacao.env" || "$MESH_DIR/04-saturacao.sh" >> "$D/04.log" 2>&1 || { log "busca inicial falhou"; exit 1; }
  log "inicial: $(grep '_CI4=' "$STATE/saturacao.env" | paste -sd' ')"
  [ -f "$D/fina.env" ] || REFINAR=1 SATF_OUT="$D/fina.env" SAT_LOG_DIR="$D" "$MESH_DIR/04-saturacao.sh" >> "$D/04.log" 2>&1 || { log "bissecção falhou"; exit 1; }
  log "bissecção: $(paste -sd' ' "$D/fina.env")"
  for r in 1 2; do
    [ -f "$D/sobe$r.env" ] && continue
    SUBIR=1 SATF_BASE="$D/fina.env" SATF_OUT="$D/sobe$r.env.tmp" SAT_LOG_DIR="$D" "$MESH_DIR/04-saturacao.sh" >> "$D/04.log" 2>&1 \
      || { log "subida $r falhou"; exit 1; }
    mv "$D/sobe$r.env.tmp" "$D/sobe$r.env"
    log "subida $r: $(paste -sd' ' "$D/sobe$r.env")"
  done
fi
log "demais células: 11-noturno.sh com FIM em +${HORAS_DEMAIS:-6} h"
FIM=$(( $(date +%s) + ${HORAS_DEMAIS:-6} * 3600 )) "$MESH_DIR/11-noturno.sh" "$RES"
log "fim"

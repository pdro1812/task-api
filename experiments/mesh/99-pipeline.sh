#!/usr/bin/env bash
# STATUS: rascunho, não testado
# Encadeia o que vem depois da bateria, para não perder horas com a sessão desconectada:
#   1. espera o 05-bateria.sh terminar e confere as 540 rodadas;
#   2. análise: agregação, estatística, figuras e modelo (analysis/), com tabelas e figuras em paper/;
#   3. refina a saturação por bissecção nas 6 configurações (REFINAR=1 04-saturacao.sh);
#   4. perfil RQ2 (06-perfil.sh, nunca testado: fica por último para não segurar o resto);
#   5. figuras de novo, agora com a vazão refinada e o perfil.
# Cada etapa grava um marcador .ok: rodar de novo pula o que já terminou. Para no primeiro erro.
# Uso: setsid nohup ./99-pipeline.sh [bateria] [resultados] > /dev/null 2>&1 < /dev/null &
# Log com horários: <resultados>/pipeline.log
source "$(dirname "$0")/lib/common.sh"
BATERIA=${1:-/mnt/dados/resultados/bateria-1}
RES=${2:-/mnt/dados/resultados}
TOTAL=${TOTAL:-540}
MARC="$RES/.pipeline"; mkdir -p "$MARC"
LOG="$RES/pipeline.log"
PY="$MESH_DIR/analysis/.venv/bin/python"
exec >> "$LOG" 2>&1

log() { echo "[$(date '+%F %T')] $*"; }
etapa() {  # $1 nome, demais: comando
  local nome=$1; shift
  if [ -f "$MARC/$nome.ok" ]; then log "$nome: já feita, pulando"; return 0; fi
  log "$nome: início"
  if "$@"; then touch "$MARC/$nome.ok"; log "$nome: ok"
  else log "$nome: ERRO (código $?); pipeline parado. Corrija e rode de novo: pula o que já terminou."; exit 1; fi
}

espera_bateria() {
  while pgrep -f '^bash ./05-bateria\.sh' >/dev/null; do sleep 60; done   # só o processo da bateria
  local n
  n=$(find "$BATERIA" -name meta.json | wc -l)
  log "bateria: $n/$TOTAL rodadas"
  [ "$n" -ge "$TOTAL" ] || { log "bateria incompleta (ver $BATERIA.log); retome com ./05-bateria.sh $BATERIA"; return 1; }
}

refina() {
  REFINAR=1 CONFIGS="B IS IA4 IA7 LK CI" "$MESH_DIR/04-saturacao.sh" || return 1
  mkdir -p "$RES/saturacao-fina"
  cp "$STATE"/saturacao-fina-*.tsv "$STATE/saturacao.env" "$RES/saturacao-fina/"
}

analise() {
  "$PY" "$MESH_DIR/analysis/10_agregar.py" "$BATERIA" --cdf &&
  "$PY" "$MESH_DIR/analysis/20_estatistica.py" "$BATERIA/cells.csv" &&
  figuras &&
  "$PY" "$MESH_DIR/analysis/40_modelo.py" "$BATERIA/cells.csv"
}
figuras() {
  "$PY" "$MESH_DIR/analysis/30_figuras.py" "$BATERIA" --perfil "$RES/perfil" --saturacao "$STATE/saturacao.env" &&
  { [ ! -d "$RES/perfil" ] || "$PY" "$MESH_DIR/analysis/50_perfil.py" "$RES/perfil"; }
}

log "pipeline: bateria=$BATERIA resultados=$RES"
etapa bateria espera_bateria
etapa analise analise
etapa saturacao-fina refina
etapa perfil "$MESH_DIR/06-perfil.sh" "$RES/perfil"
etapa figuras-final figuras
volta_b() { "$MESH_DIR/03-config.sh" B > "$RES/pipeline-B.log" 2>&1; }
etapa cluster-B volta_b
log "pipeline concluído"

#!/usr/bin/env bash
# Medições pedidas pelas revisões (28/11), na ordem, cada etapa com marcador .ok (retomável):
#   1. ops-bancos: operações de MongoDB/memcached/redis por requisição (15a-ops-bancos.sh, na B)
#   2. n5: controles com 5 repetições no mesmo dia, as duas partes em ordem sorteada:
#        CI4 e IA4 no OB e no HR, 60% e 90%           -> <res>/n5/cilium-ambient
#        CI, CINH e CINHA no echo, 60% e 90%          -> <res>/n5/hubble
#   3. deploys: dois deploys independentes extras das 7 configurações no OB, 60% e 90%, 3 repetições por deploy
#        -> <res>/deploys/d2 e d3 (cada 05-bateria.sh restaura o snapshot e reinstala mesh e aplicações)
# Confere o preparo do host (como o 13-controle-ci.sh) antes de cada etapa e para contêineres em execução.
# Uso: setsid nohup ./15-extras.sh [resultados] > /dev/null 2>&1 < /dev/null &     Log: <resultados>/extras.log
source "$(dirname "$0")/lib/common.sh"
RES=${1:-/mnt/dados/resultados}
MARC="$RES/.extras"; mkdir -p "$MARC"
exec >> "$RES/extras.log" 2>&1
log() { echo "[$(date '+%F %T')] $*"; }
host_ok() {
  [ "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)" = performance ] &&
  [ "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)" = 1 ] &&
  [ "$(cat /sys/devices/system/cpu/cpu2/cpuidle/state2/disable)" = 1 ] &&
  [ "$(cat /sys/module/kvm/parameters/halt_poll_ns)" = 200000 ] &&
  [ -r /sys/class/powercap/intel-rapl:0/energy_uj ]
}
etapa() {  # $1 nome, demais: comando
  local nome=$1; shift
  if [ -f "$MARC/$nome.ok" ]; then log "$nome: já feita, pulando"; return 0; fi
  until host_ok; do log "host sem o preparo do 00-host.sh; esperando"; sleep 60; done
  docker ps -q | xargs -r docker stop >/dev/null 2>&1 || true
  log "$nome: início"
  if "$@"; then touch "$MARC/$nome.ok"; log "$nome: ok"
  else log "$nome: ERRO (código $?); parado. Rode de novo: pula o que já terminou."; exit 1; fi
}
n5() {
  local parte
  for parte in $(printf 'cilium-ambient\nhubble\n' | shuf); do
    case $parte in
      cilium-ambient) CONFIGS="CI4 IA4" APPS="ob hotel" LOADS="60 90" REPS=5 "$MESH_DIR/05-bateria.sh" "$RES/n5/cilium-ambient" || return 1 ;;
      hubble) CONFIGS="CI CINH CINHA" APPS=echo LOADS="60 90" REPS=5 "$MESH_DIR/05-bateria.sh" "$RES/n5/hubble" || return 1 ;;
    esac
  done
}
deploy() { CONFIGS="B IS IA4 IA7 LK CI CI4" APPS=ob LOADS="60 90" REPS=3 "$MESH_DIR/05-bateria.sh" "$RES/deploys/$1"; }

log "extras: resultados=$RES"
etapa ops-bancos "$MESH_DIR/15a-ops-bancos.sh" "$RES/ops-bancos.json"
etapa n5 n5
etapa deploy-d2 deploy d2
etapa deploy-d3 deploy d3
log "fim"

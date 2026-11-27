#!/usr/bin/env bash
# Controle de mesmo dia (27/11) para as ablações da CI: CI, CINH, CINHA e CI4 no echo a 60% e 90%, 3 repetições,
# com o mesmo preparo de host da bateria principal. Espera o 00-host.sh (governor performance, sem turbo, C-states
# profundos desligados, RAPL legível) antes de medir; para contêineres que estejam rodando.
# Uso: setsid nohup ./13-controle-ci.sh [diretório] > /dev/null 2>&1 < /dev/null &     Log: <diretório>.log
source "$(dirname "$0")/lib/common.sh"
DIR=${1:-/mnt/dados/resultados/ci-controle}
exec >> "$DIR.log" 2>&1
log() { echo "[$(date '+%F %T')] $*"; }
pronto() {
  [ "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)" = performance ] &&
  [ "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)" = 1 ] &&
  [ "$(cat /sys/devices/system/cpu/cpu2/cpuidle/state2/disable)" = 1 ] &&
  [ -r /sys/class/powercap/intel-rapl:0/energy_uj ]
}
log "esperando o 00-host.sh"
until pronto; do sleep 30; done
[ "$(cat /sys/module/kvm/parameters/halt_poll_ns)" = 200000 ] || { log "halt_poll_ns diferente de 200000"; exit 1; }
docker ps -q | xargs -r docker stop >/dev/null 2>&1 || true
log "host pronto (halt_poll_ns=$(cat /sys/module/kvm/parameters/halt_poll_ns), contêineres: $(docker ps -q | wc -l)); medindo"
CONFIGS="CI CINH CINHA CI4" APPS=echo LOADS="60 90" REPS=3 "$MESH_DIR/05-bateria.sh" "$DIR" || { log "ERRO no 05-bateria.sh"; exit 1; }
log "fim"

#!/usr/bin/env bash
# Controle de mesmo dia (27/11) para as comparações que dependiam de dias diferentes:
#   - B, IA4, CI4 e IS na posição original, OB e HR a 60% e 90%, 3 repetições (05-bateria.sh) -> <dir>/orig
#   - IS com o frontend sozinho (fe-alone), OB a 60% e 90%, 3 repetições (10-placement.sh)   -> <dir>/placement
# As duas partes em ordem sorteada; dentro de cada uma, a ordem é a dos próprios scripts (aleatória com semente).
# Confere o preparo do host (igual ao 13-controle-ci.sh) e para contêineres em execução.
# Uso: setsid nohup ./14-controle-mesmo-dia.sh [diretório] > /dev/null 2>&1 < /dev/null &     Log: <diretório>.log
source "$(dirname "$0")/lib/common.sh"
DIR=${1:-/mnt/dados/resultados/controle-mesmo-dia}
mkdir -p "$DIR"
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
log "host pronto (halt_poll_ns=$(cat /sys/module/kvm/parameters/halt_poll_ns), contêineres: $(docker ps -q | wc -l))"
orig() { CONFIGS="B IA4 CI4 IS" APPS="ob hotel" LOADS="60 90" REPS=3 "$MESH_DIR/05-bateria.sh" "$DIR/orig"; }
fe() { BLOCOS="fe-alone:IS" REPS=3 LOADS="60 90" "$MESH_DIR/10-placement.sh" "$DIR/placement"; }
for parte in $(printf 'orig\nfe\n' | shuf); do
  log "parte $parte"
  $parte || { log "ERRO na parte $parte"; exit 1; }
done
log "fim"

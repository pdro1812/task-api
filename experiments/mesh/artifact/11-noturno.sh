#!/usr/bin/env bash
# Experimentos complementares (revisão crítica de 20/11), encadeados como no 99-pipeline.sh: cada etapa grava um
# marcador .ok e rodar de novo pula o que já terminou; para no primeiro erro.
#   0. host: confere e registra o preparo (igual ao da bateria principal: 00-host.sh, halt-polling do KVM ligado no
#      padrão, sem a stack talhao nem o kind tcc); para o que concorre com a medição
#   1. posicionamento do OB (10-placement.sh)                         -> <res>/placement
#   2. CI4: Cilium só L4 (WireGuard, sem regra L7), 3 apps x 3 cargas x 5 rep.   -> <res>/ci4/CI4
#   3. CINH (CI sem Hubble) e CINHA (sem Hubble nem log de acesso do Envoy), echo 60% e 90%, 3 rep. -> <res>/ci4/
#   4. bpf_stats: custo dos programas eBPF na CI e na CI4 (06-perfil.sh, BPF_STATS=1) -> <res>/ci4/perfil-bpf
#   5. se sobrar tempo até FIM (padrão: 09:00), repete a saturação REP_SAT vezes subindo até duas reprovações
#      seguidas (SUBIR=1 04-saturacao.sh): primeiro as células censuradas da saturacao-fina (todos os passos da
#      bissecção aprovados), depois as demais                           -> <res>/saturacao-rep/rep<N>
# Uso: setsid nohup ./11-noturno.sh [resultados] > /dev/null 2>&1 < /dev/null &      Log: <resultados>/noturno.log
source "$(dirname "$0")/lib/common.sh"
RES=${1:-/mnt/dados/resultados}
HP_ESPERADO=${HP_ESPERADO:-200000}   # halt_poll_ns da bateria principal (padrão do KVM)
REP_SAT=${REP_SAT:-2}
if [ -z "${FIM:-}" ]; then
  FIM=$(date -d 09:00 +%s); [ "$(date +%s)" -lt "$FIM" ] || FIM=$(date -d 'tomorrow 09:00' +%s)
fi
MARC="$RES/.noturno"; mkdir -p "$MARC"
LOG="$RES/noturno.log"
exec >> "$LOG" 2>&1

log() { echo "[$(date '+%F %T')] $*"; }
etapa() {  # $1 nome, demais: comando
  local nome=$1; shift
  if [ -f "$MARC/$nome.ok" ]; then log "$nome: já feita, pulando"; return 0; fi
  log "$nome: início"
  if "$@"; then touch "$MARC/$nome.ok"; log "$nome: ok"
  else log "$nome: ERRO (código $?); parado. Corrija e rode de novo: pula o que já terminou."; exit 1; fi
}

host() {  # confere o preparo do 00-host.sh (não sobrevive a reboot) e para o que concorre; registra tudo
  local f="$RES/noturno-host.txt" gov turbo hp prof
  gov=$(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | paste -sd,)
  turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
  hp=$(cat /sys/module/kvm/parameters/halt_poll_ns)
  prof=$(cat /sys/devices/system/cpu/cpu2/cpuidle/state2/disable 2>/dev/null || echo ?)
  [ "$gov" = performance ] && [ "$turbo" = 1 ] && [ "$prof" = 1 ] || {
    log "host sem o preparo do 00-host.sh (governor=$gov no_turbo=$turbo cstate2_off=$prof): rode ./00-host.sh"; return 1; }
  [ "$hp" = "$HP_ESPERADO" ] || { log "halt_poll_ns=$hp, esperado $HP_ESPERADO (como na bateria principal)"; return 1; }
  [ -r /sys/class/powercap/intel-rapl:0/energy_uj ] || { log "RAPL ilegível: rode ./00-host.sh"; return 1; }
  if [ -n "$(docker ps -q)" ]; then
    log "parando contêineres: $(docker ps --format '{{.Names}}' | paste -sd' ')"
    docker compose -p talhao stop >/dev/null 2>&1 || true
    docker stop tcc-control-plane tcc-worker tcc-worker2 >/dev/null 2>&1 || true
    [ -z "$(docker ps -q)" ] || { log "ainda há contêineres rodando: $(docker ps --format '{{.Names}}' | paste -sd' ')"; return 1; }
  fi
  {
    echo "# $(date -Is)"
    echo "governor=$gov no_turbo=$turbo cstates_profundos_desligados=$prof halt_poll_ns=$hp"
    echo "docker_ps=$(docker ps -q | wc -l) uptime=$(uptime -p) kernel=$(uname -r)"
  } >> "$f"
}

perfil_bpf() {
  BPF_STATS=1 CONFIGS="CI CI4" APPS="echo ob" "$MESH_DIR/06-perfil.sh" "$RES/ci4/perfil-bpf"
}

# Células da saturacao-fina em que os 4 passos da bissecção passaram (limite superior visto uma vez só)
declare -A CENSURADAS=([B]="echo hotel" [IS]="echo ob" [IA4]="ob" [IA7]="echo hotel" [LK]="echo ob hotel" [CI]="echo hotel")
sat_rep() {  # censuradas em todas as repetições, depois as outras; uma configuração só começa se couber antes de FIM
  local r cfg d apps grupo a
  for grupo in censuradas demais; do
    for r in $(seq 1 "$REP_SAT"); do
      d="$RES/saturacao-rep/rep$r"; mkdir -p "$d"
      for cfg in B IS IA4 IA7 LK CI; do
        [ -f "$MARC/sat-$grupo-rep$r-$cfg.ok" ] && continue
        apps=${CENSURADAS[$cfg]}
        if [ "$grupo" = demais ]; then apps=$(for a in echo ob hotel; do case " ${CENSURADAS[$cfg]} " in *" $a "*) ;; *) echo -n "$a "; esac; done); fi
        [ -n "${apps// }" ] || { touch "$MARC/sat-$grupo-rep$r-$cfg.ok"; continue; }
        if [ $(( $(date +%s) + 30 * 60 )) -gt "$FIM" ]; then log "saturacao-rep: sem tempo antes de $(date -d @"$FIM" +%H:%M); parando em $grupo rep$r $cfg"; return 0; fi
        log "saturacao-rep: $grupo rep$r $cfg ($apps)"
        "$MESH_DIR/03-config.sh" "$cfg" > "$d/03-$cfg-$grupo.log" 2>&1 || return 1
        # shellcheck disable=SC2086
        SUBIR=1 SATF_BASE="$RES/saturacao-fina/saturacao.env" SATF_OUT="$d/saturacao-sobe.env" SAT_LOG_DIR="$d" \
          "$MESH_DIR/04-saturacao.sh" $apps >> "$d/04.log" 2>&1 || return 1
        touch "$MARC/sat-$grupo-rep$r-$cfg.ok"
      done
    done
  done
}

log "noturno: resultados=$RES fim=$(date -d @"$FIM" '+%F %H:%M')"
etapa host host
etapa placement "$MESH_DIR/10-placement.sh" "$RES/placement"
ci4() { CONFIGS=CI4 REPS=5 "$MESH_DIR/05-bateria.sh" "$RES/ci4"; }
etapa ci4 ci4
cinh() { CONFIGS="CINH CINHA" APPS=echo LOADS="60 90" REPS=3 "$MESH_DIR/05-bateria.sh" "$RES/ci4"; }
etapa cinh cinh
etapa perfil-bpf perfil_bpf
sat_rep || { log "saturacao-rep: ERRO"; exit 1; }
log "noturno concluído"

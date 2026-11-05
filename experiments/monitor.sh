#!/usr/bin/env bash
# Monitores em segundo plano para uma rodada. Uso (com source):
#   source experiments/monitor.sh; monitor_start <prefixo>; ...; monitor_stop
# Gera:
#   <prefixo>.endpoints  epoch ip=ready ... dos EndpointSlices do task-api-service (a cada 0,5 s, só mudanças)
#   <prefixo>.cpu        epoch %cpu_host (a cada 1 s, de /proc/stat)
#   <prefixo>.docker     epoch nó %cpu mem (a cada ~2 s, docker stats dos nós do kind)
MON_NS=${NS:-task-api}
MON_PIDS=()

_mon_endpoints() {
  local last=""
  while true; do
    local cur
    cur=$(kubectl -n "$MON_NS" get endpointslices -l kubernetes.io/service-name=task-api-service \
      -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}={.conditions.ready} {end}' 2>/dev/null)
    if [ "$cur" != "$last" ]; then echo "$(date +%s.%N) $cur"; last=$cur; fi
    sleep 0.5
  done
}

_mon_cpu() {
  local a b
  read -r _ a1 a2 a3 a4 a5 a6 a7 _ < /proc/stat
  while sleep 1; do
    read -r _ b1 b2 b3 b4 b5 b6 b7 _ < /proc/stat
    local busy=$(( (b1+b2+b3+b6+b7) - (a1+a2+a3+a6+a7) )) total=$(( (b1+b2+b3+b4+b5+b6+b7) - (a1+a2+a3+a4+a5+a6+a7) ))
    echo "$(date +%s.%N) $(( total > 0 ? 100 * busy / total : 0 ))"
    a1=$b1 a2=$b2 a3=$b3 a4=$b4 a5=$b5 a6=$b6 a7=$b7
  done
}

_mon_docker() {
  while true; do
    docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' tcc-control-plane tcc-worker tcc-worker2 2>/dev/null \
      | while read -r l; do echo "$(date +%s.%N) $l"; done
  done
}

monitor_start() {
  _mon_endpoints > "$1.endpoints" & MON_PIDS+=($!)
  _mon_cpu > "$1.cpu" & MON_PIDS+=($!)
  _mon_docker > "$1.docker" & MON_PIDS+=($!)
}

monitor_stop() {
  local p
  for p in "${MON_PIDS[@]}"; do pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done
  # wait devolve 143 (SIGTERM) para os monitores encerrados; não deve derrubar quem usa set -e
  wait "${MON_PIDS[@]}" 2>/dev/null || true
  MON_PIDS=()
}

#!/usr/bin/env bash
# STATUS: rascunho, não testado
# Perfil do plano de dados (RQ2: de onde vem o custo de cada mesh). Para cada configuração, com carga constante de
# 60% da saturação em uma app, coleta nos nós de trabalho, durante PERF_S segundos:
#   - perf record -a -g (todas as CPUs da VM) -> pilhas "folded" para flamegraph, por nó;
#   - bpftrace: trocas de contexto e syscalls por processo, tempo de softirq por vetor;
#   - CI: bpf_stats (run_time_ns e run_cnt de cada programa eBPF) antes e depois, para o custo do datapath eBPF;
#   - requisições feitas pelo k6 no intervalo (k6-summary.json), para normalizar por requisição.
# BPF_STATS=1 liga kernel.bpf_stats_enabled nos nós durante a coleta (run_time_ns e run_cnt por programa no
# bpftool); tem custo próprio, por isso fica desligado no perfil principal e só vale para o custo dos programas eBPF.
# Uso: ./06-perfil.sh [diretório]   Variáveis: CONFIGS="B IS IA4 IA7 LK CI"  APPS="echo ob"  LOAD=60  PERF_S=60
# Saída: <diretório>/<cfg>/<app>/{<nó>.folded, <nó>-bpftrace.txt, <nó>-bpf-antes.json, <nó>-bpf-depois.json,
#        k6-summary.json, meta.json}. Padrão: $RESULTS_ROOT/perfil.
source "$(dirname "$0")/lib/common.sh"
source "$MESH_DIR/lib/measure.sh"
CONFIGS=${CONFIGS:-"B IS IA4 IA7 LK CI"}
APPS=${APPS:-"echo ob"}
LOAD=${LOAD:-60}
PERF_S=${PERF_S:-60}
WORKERS=(w1 w2 w3)
OUT=${1:-$RESULTS_ROOT/perfil}
mkdir -p "$OUT"

# FlameGraph (stackcollapse-perf.pl) no host, para dobrar as pilhas
FG="$STATE/FlameGraph"
[ -d "$FG" ] || git clone -q --depth 1 https://github.com/brendangregg/FlameGraph "$FG"

BPFTRACE='
tracepoint:sched:sched_switch { @trocas[args->prev_comm] = count(); }
tracepoint:raw_syscalls:sys_enter { @syscalls[comm] = count(); }
tracepoint:irq:softirq_entry { @t[cpu, args->vec] = nsecs; }
tracepoint:irq:softirq_exit /@t[cpu, args->vec]/ {
  @softirq_ns[args->vec] = sum(nsecs - @t[cpu, args->vec]); delete(@t[cpu, args->vec]);
}
interval:s:'"$PERF_S"' { exit(); }
END { clear(@t); }'

coleta_no() {  # $1 nó, $2 diretório: perf e bpftrace em paralelo na VM, depois copia
  local vm=$1 d=$2
  [ -n "${BPF_STATS:-}" ] && vssh "$vm" "sudo sysctl -qw kernel.bpf_stats_enabled=1"
  vssh "$vm" "sudo bpftool prog show -j" > "$d/$vm-bpf-antes.json" 2>/dev/null || true
  vssh "$vm" "cd /tmp && sudo rm -f perf.data && \
    (sudo perf record -a -g -F 99 -o /tmp/perf.data -- sleep $PERF_S >/dev/null 2>&1 &) && \
    sudo bpftrace -e '$BPFTRACE' 2>/dev/null; sleep 2; \
    sudo perf script -i /tmp/perf.data 2>/dev/null" > "$d/$vm.perf.txt"
  vssh "$vm" "sudo bpftool prog show -j" > "$d/$vm-bpf-depois.json" 2>/dev/null || true
  [ -n "${BPF_STATS:-}" ] && vssh "$vm" "sudo sysctl -qw kernel.bpf_stats_enabled=0"
  "$FG/stackcollapse-perf.pl" "$d/$vm.perf.txt" > "$d/$vm.folded" && gzip -f "$d/$vm.perf.txt"
}

for cfg in $CONFIGS; do
  step "[$cfg] preparando"
  "$MESH_DIR/03-config.sh" "$cfg" > "$OUT/$cfg-config.log" 2>&1 || die "03-config.sh $cfg falhou"
  for app in $APPS; do
    d="$OUT/$cfg/$app"; mkdir -p "$d"
    base=$(sat_min "$app" B IS IA4 IA7 LK CI) || exit 1; rate=$(( base * LOAD / 100 ))   # a mesma base da bateria
    step "[$cfg] $app a $rate req/s ($LOAD%)"
    k6_run "$app" "$rate" "$WARMUP" >/dev/null 2>&1 || true
    # a carga dura o perfil inteiro mais uma folga; o k6 roda nos núcleos E
    SUMMARY="$d/k6-summary.json" k6_run "$app" "$rate" "$((PERF_S + 20))s" > "$d/k6.log" 2>&1 &
    k6pid=$!
    sleep 10
    t0=$(date +%s)
    for vm in "${WORKERS[@]}"; do coleta_no "$vm" "$d" & done
    wait $(jobs -p | grep -v "^$k6pid$") 2>/dev/null
    t1=$(date +%s)
    wait "$k6pid" || warn "k6 terminou com erro em $d"
    echo "{\"config\": \"$cfg\", \"app\": \"$app\", \"load\": $LOAD, \"rate\": $rate, \"start\": $t0, \"end\": $t1}" \
      > "$d/meta.json"
  done
done
step "perfil concluído: $OUT"
# ANOTAR: conferir no primeiro uso se o perf da VM resolve símbolos do Envoy/ztunnel/linkerd-proxy (binários sem
# símbolos aparecem como [unknown]); se não resolver, a quebra fica por processo (comm) e por função do kernel.

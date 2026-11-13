# Medição de uma rodada: aquecimento, carga em malha aberta com k6 (nos núcleos E), energia RAPL do host e
# séries de CPU e memória por contêiner do Prometheus no intervalo medido.
RESULTS_ROOT=${RESULTS_ROOT:-$MESH_DIR/../results/mesh}
PROM="http://${VM_IP[cp]}:30090"
WARMUP=${WARMUP:-60s}
DURATION=${DURATION:-180s}
declare -A APP_URL=([echo]="http://${VM_IP[w1]}:30082" [ob]="http://${VM_IP[w1]}:30080" [hotel]="http://${VM_IP[w1]}:30081")
RAPL_ZONES=(intel-rapl:0 intel-rapl:0:0)

rapl_read() {  # imprime "zona=microjoules" para cada zona
  for z in "${RAPL_ZONES[@]}"; do echo "$z=$(cat /sys/class/powercap/$z/energy_uj)"; done
}
rapl_joules() {  # $1 e $2: saídas de rapl_read (início e fim); trata a volta do contador
  local z a b max
  for z in "${RAPL_ZONES[@]}"; do
    a=$(echo "$1" | sed -n "s/^$z=//p"); b=$(echo "$2" | sed -n "s/^$z=//p")
    max=$(cat /sys/class/powercap/$z/max_energy_range_uj)
    [ "$b" -lt "$a" ] && b=$((b + max))
    echo "\"$z\": $(( (b - a) / 1000 ))e-3"
  done | paste -sd, -
}

prom_range() {  # $1 consulta, $2 início, $3 fim (epoch), $4 arquivo
  curl -sf --max-time 60 "$PROM/api/v1/query_range" --data-urlencode "query=$1" \
    --data-urlencode "start=$2" --data-urlencode "end=$3" --data-urlencode "step=5" > "$4" \
    || warn "consulta ao Prometheus falhou: $1"
}

k6_run() {  # $1 app, $2 taxa, $3 duração, demais: argumentos extras do k6
  local app=$1 rate=$2 dur=$3; shift 3
  taskset -c "$(e_cores)" k6 run --quiet -e BASE_URL="${APP_URL[$app]}" -e RATE="$rate" -e DURATION="$dur" \
    -e SUMMARY="${SUMMARY:-}" \
    "$@" "$MESH_DIR/k6/$app.js"
}

idle_power() {  # potência ociosa do host com o cluster parado, para descontar da energia das rodadas
  local out=$1 s e t0
  t0=$(date +%s); s=$(rapl_read); sleep 60; e=$(rapl_read)
  echo "{\"seconds\": $(( $(date +%s) - t0 )), \"joules\": {$(rapl_joules "$s" "$e")}}" > "$out"
}

run_cell() {  # $1 config, $2 app, $3 carga (rótulo), $4 taxa, $5 repetição, $6 diretório da rodada
  local cfg=$1 app=$2 load=$3 rate=$4 rep=$5 dir=$6 s e t0 t1
  mkdir -p "$dir"
  k6_run "$app" "$rate" "$WARMUP" >/dev/null 2>&1 || true
  t0=$(date +%s.%N); s=$(rapl_read)
  SUMMARY="$dir/k6-summary.json" k6_run "$app" "$rate" "$DURATION" --out "csv=$dir/k6-reqs.csv.gz" \
    > "$dir/k6.log" 2>&1 || warn "k6 terminou com erro em $dir (ver k6.log)"
  e=$(rapl_read); t1=$(date +%s.%N)
  prom_range 'sum by (namespace,pod,container,node) (rate(container_cpu_usage_seconds_total{container!=""}[15s]))' \
    "$t0" "$t1" "$dir/prom-cpu.json"
  prom_range 'sum by (namespace,pod,container,node) (container_memory_working_set_bytes{container!=""})' \
    "$t0" "$t1" "$dir/prom-mem.json"
  prom_range 'sum by (instance,mode) (rate(node_cpu_seconds_total[15s]))' "$t0" "$t1" "$dir/prom-node-cpu.json"
  cat > "$dir/meta.json" <<JSON
{"config": "$cfg", "app": "$app", "load": "$load", "rate": $rate, "rep": $rep,
 "start": $t0, "end": $t1, "joules": {$(rapl_joules "$s" "$e")}}
JSON
}

# Lê p99 (ms), taxa de erro e iterações descartadas de um resumo do k6
k6_stats() {
  jq -r '.metrics as $m | ($m.dropped_iterations.values.count // 0) as $d |
          [$m.http_req_duration.values["p(99)"], ($m.http_req_failed.values.rate // 0),
           ($d / (($m.iterations.values.count // 0) + $d + 0.000001))] | @tsv' "$1"
}

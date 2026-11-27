#!/usr/bin/env bash
# Reprodução do MeshInsight (Zhu et al., SoCC 2023): acréscimo de latência e de CPU do Istio com sidecar sobre a
# mesma aplicação sem mesh, numa taxa perto da saturação. O artigo (Istio 1.13 / Envoy 1.21, Online Boutique e Hotel)
# não dá um número único: "request latency increases by 27-269% and CPU usage increases by 42-163%", conforme a
# configuração (modo gRPC até +269% de latência e +163% de CPU; modo TCP até +61% e +92%), com taxas perto do máximo
# que a máquina sustenta. Critério aqui: IS contra B no OB a 90% da menor saturação entre B e IS (que as duas
# sustentam; a 90% da B o IS colapsa) deve cair em 27-269% de latência e
# 42-163% de CPU; fora disso, reportar e explicar (Istio mais novo, outro hardware, cluster virtualizado).
# Uso: ./07-meshinsight.sh [diretório]   Variáveis: APP=ob  RATE=<req/s>  REPS=5
# Saída: <diretório>/<cfg>-<rep>/ (mesmos arquivos de uma rodada da bateria), rodadas.tsv e resumo.tsv
source "$(dirname "$0")/lib/common.sh"
source "$MESH_DIR/lib/measure.sh"
APP=${APP:-ob}
# taxa perto da saturação da B, como no MeshInsight
if [ -z "${RATE:-}" ]; then
  base=$(sat_min "$APP" B IS) || exit 1; RATE=$(( base * 90 / 100 ))   # 90% da menor entre B e IS: as duas sustentam
fi
REPS=${REPS:-5}
OUT=${1:-$RESULTS_ROOT/meshinsight}
mkdir -p "$OUT"

for cfg in B IS; do
  "$MESH_DIR/03-config.sh" "$cfg" > "$OUT/$cfg-config.log" 2>&1 || die "03-config.sh $cfg falhou"
  for rep in $(seq 1 "$REPS"); do
    [ -f "$OUT/$cfg-$rep/meta.json" ] && continue
    step "[$cfg] $APP a $RATE req/s, rodada $rep"
    run_cell "$cfg" "$APP" mi "$RATE" "$rep" "$OUT/$cfg-$rep"
  done
done

# Resumo: medianas de p50/p99 e de CPU total do cluster por configuração, e o acréscimo do IS sobre a B
{
  echo -e "config\tp50_ms\tp99_ms\tcpu_cores"
  for cfg in B IS; do
    for rep in $(seq 1 "$REPS"); do
      d="$OUT/$cfg-$rep"
      p50=$(jq '.metrics.http_req_duration.values.med' "$d/k6-summary.json")
      p99=$(jq '.metrics.http_req_duration.values["p(99)"]' "$d/k6-summary.json")
      cpu=$(jq '[.data.result[].values | map(.[1] | tonumber) | add / length] | add' "$d/prom-cpu.json")
      echo -e "$cfg\t$p50\t$p99\t$cpu"
    done
  done
} > "$OUT/rodadas.tsv"
python3 - "$OUT/rodadas.tsv" <<'PY' | tee "$OUT/resumo.tsv"
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
med = {c: {k: statistics.median(float(r[k]) for r in rows if r["config"] == c) for k in ("p50_ms", "p99_ms", "cpu_cores")}
       for c in ("B", "IS")}
FAIXA = {"p50_ms": (27, 269), "p99_ms": (27, 269), "cpu_cores": (42, 163)}   # MeshInsight, SoCC 2023
print("metrica\tB\tIS\tacrescimo_%\tfaixa_publicada_%\tdentro")
for k in ("p50_ms", "p99_ms", "cpu_cores"):
    a = 100 * (med['IS'][k] / med['B'][k] - 1)
    lo, hi = FAIXA[k]
    print(f"{k}\t{med['B'][k]:.3f}\t{med['IS'][k]:.3f}\t{a:.1f}\t{lo}-{hi}\t{'sim' if lo <= a <= hi else 'NAO'}")
PY

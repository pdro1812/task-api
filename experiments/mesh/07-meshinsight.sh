#!/usr/bin/env bash
# STATUS: rascunho, não testado
# Reprodução de um número do MeshInsight (Zhu et al., SoCC 2023): o acréscimo de latência e de CPU do Istio com
# sidecar sobre a mesma aplicação sem mesh, a uma taxa fixa. Serve para situar o nosso testbed: se o acréscimo
# medido aqui cair na mesma ordem de grandeza do publicado, os demais resultados são comparáveis.
# Uso: ./07-meshinsight.sh [diretório]   Variáveis: APP=ob  RATE=<req/s>  REPS=5
# Saída: <diretório>/<cfg>-<rep>/ (mesmos arquivos de uma rodada da bateria) e <diretório>/resumo.tsv
source "$(dirname "$0")/lib/common.sh"
source "$MESH_DIR/lib/measure.sh"
APP=${APP:-ob}
# ANOTAR: taxa e aplicação usadas no artigo do MeshInsight para o número que vamos comparar. Sem isso, usa 30% da
# saturação da B (carga leve, longe do joelho, como num microbenchmark).
if [ -z "${RATE:-}" ]; then
  [ -f "$STATE/saturacao.env" ] || die "defina RATE ou rode antes o piloto"
  source "$STATE/saturacao.env"; var="SAT_$APP"; RATE=$(( ${!var} * 30 / 100 ))
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
print("metrica\tB\tIS\tacrescimo_%")
for k in ("p50_ms", "p99_ms", "cpu_cores"):
    print(f"{k}\t{med['B'][k]:.3f}\t{med['IS'][k]:.3f}\t{100 * (med['IS'][k] / med['B'][k] - 1):.1f}")
PY
# ANOTAR: valor publicado no MeshInsight para comparar (acréscimo de latência e de CPU do Istio sidecar na mesma
# aplicação/taxa), com a figura ou tabela de onde saiu: latência ____ %, CPU ____ % (fonte: ____).

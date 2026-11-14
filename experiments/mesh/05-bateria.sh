#!/usr/bin/env bash
# Bateria principal: para cada configuração (em ordem aleatória), prepara o cluster com 03-config.sh, mede a
# potência ociosa e roda as células app x carga x repetição em ordem aleatória. Retoma de onde parou: uma rodada
# com meta.json já gravado é pulada. A semente fica no diretório da bateria, então a ordem é reproduzível.
# Uso: ./05-bateria.sh [diretório]   Variáveis: CONFIGS="B IS IA4 IA7 LK CI"  REPS=10  LOADS="30 60 90"  APPS="echo ob hotel"
source "$(dirname "$0")/lib/common.sh"
source "$MESH_DIR/lib/measure.sh"
[ -f "$STATE/saturacao.env" ] || die "rode antes o piloto: ./03-config.sh B && ./04-saturacao.sh"
source "$STATE/saturacao.env"
CONFIGS=${CONFIGS:-"B IS IA4 IA7 LK CI"}
REPS=${REPS:-10}
LOADS=${LOADS:-"30 60 90"}
APPS=${APPS:-"echo ob hotel"}
DIR=${1:-$RESULTS_ROOT/bateria-$(date +%Y%m%d-%H%M)}
mkdir -p "$DIR"

# Espaço: o k6-reqs.csv.gz domina (medido: 36-51 B por requisição, ~8 KB por req/s numa rodada de 180 s).
# Recusa começar se a projeção das rodadas pendentes passar de 80% do espaço livre no destino.
KB_POR_RPS=${KB_POR_RPS:-8}
proj_kb=0
for cfg in $CONFIGS; do for app in $APPS; do for load in $LOADS; do for rep in $(seq 1 "$REPS"); do
  [ -f "$DIR/$cfg/$app-$load-$rep/meta.json" ] && continue
  var="SAT_$app"; proj_kb=$(( proj_kb + ${!var} * load / 100 * KB_POR_RPS * ${DURATION%s} / 180 + 500 ))
done; done; done; done
livre_kb=$(df -Pk "$DIR" | awk 'NR == 2 {print $4}')
echo "projeção de disco: $((proj_kb / 1024)) MB para as rodadas pendentes; livre em $DIR: $((livre_kb / 1024)) MB"
[ "$proj_kb" -le $(( livre_kb * 8 / 10 )) ] || die "a bateria passaria de 80% do espaço livre em $DIR: escolha outro destino"
[ -f "$DIR/seed" ] || echo $RANDOM > "$DIR/seed"
SEED=$(cat "$DIR/seed")
cp "$STATE/versoes-instaladas.txt" "$STATE/saturacao.env" "$DIR/" 2>/dev/null || true
shuffle() { shuf --random-source=<(yes "$SEED$1"); }

for cfg in $(echo "$CONFIGS" | tr ' ' '\n' | shuffle cfg); do
  cells=()
  for app in $APPS; do for load in $LOADS; do for rep in $(seq 1 "$REPS"); do
    [ -f "$DIR/$cfg/$app-$load-$rep/meta.json" ] || cells+=("$app $load $rep")
  done; done; done
  [ ${#cells[@]} -eq 0 ] && { echo "$cfg: completa"; continue; }
  step "$cfg: ${#cells[@]} rodadas pendentes"
  "$MESH_DIR/03-config.sh" "$cfg" > "$DIR/$cfg-config.log" 2>&1 || die "03-config.sh $cfg falhou (ver $DIR/$cfg-config.log)"
  mkdir -p "$DIR/$cfg"
  kubectl get pods -A -o wide > "$DIR/$cfg/pods.txt"
  idle_power "$DIR/$cfg/idle.json"
  i=0
  while read -r app load rep; do
    i=$((i + 1))
    var="SAT_$app"; rate=$(( ${!var} * load / 100 ))
    echo "[$(date +%H:%M)] $cfg $i/${#cells[@]}: $app carga $load% ($rate req/s) rodada $rep"
    run_cell "$cfg" "$app" "$load" "$rate" "$rep" "$DIR/$cfg/$app-$load-$rep"
  done < <(printf '%s\n' "${cells[@]}" | shuffle "$cfg")
done
step "bateria concluída: $DIR"

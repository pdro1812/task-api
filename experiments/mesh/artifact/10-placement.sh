#!/usr/bin/env bash
# Experimento de posicionamento (RQ1/RQ3: a cauda das malhas L7 é ditada pelo nó mais ocupado?). Só Online Boutique,
# nas taxas absolutas da bateria principal (60% e 90%: 385 e 578 req/s), com run_cell como no 05-bateria.sh.
# Blocos (posição x configuração), em ordem aleatória com semente; dentro de cada bloco, carga x repetição também:
#   fe-alone  B, IS, IA7   frontend sozinho em w3; os outros 10 serviços se revezam entre w1 e w2 (waypoint da IA7 em w2)
#   wp-moved  IA7          posição original; waypoint do ob em w1 (o nó menos ocupado na IA7, analysis/out/node_util.csv)
#   orig      IA7          controle do mesmo dia: posição e waypoint originais (waypoint em w2), como na bateria
# Retoma de onde parou (rodada com meta.json é pulada). Saída: <dir>/<posição>-<cfg>/ob-<carga>-<rep>/
# Uso: ./10-placement.sh [diretório]   Variáveis: REPS=5  LOADS="60 90"  BLOCOS="fe-alone:B fe-alone:IS ..."
source "$(dirname "$0")/lib/common.sh"
source "$MESH_DIR/lib/measure.sh"
REPS=${REPS:-5}
LOADS=${LOADS:-"60 90"}
BLOCOS=${BLOCOS:-"fe-alone:B fe-alone:IS fe-alone:IA7 wp-moved:IA7 orig:IA7"}
WP_MOVIDO=${WP_MOVIDO:-w1}
# Mesma base da bateria principal: a menor saturação do ob entre as 6 configurações
SAT_ob=$(sat_min ob B IS IA4 IA7 LK CI) || exit 1
DIR=${1:-$RESULTS_ROOT/placement}
mkdir -p "$DIR"
[ -f "$DIR/seed" ] || echo $RANDOM > "$DIR/seed"
SEED=$(cat "$DIR/seed")
cp "$STATE/versoes-instaladas.txt" "$STATE/saturacao.env" "$DIR/" 2>/dev/null || true
shuffle() { shuf --random-source=<(yes "$SEED$1"); }
echo "ob: base das cargas $SAT_ob req/s; taxas: $(for l in $LOADS; do echo -n "$l%=$(( SAT_ob * l / 100 )) "; done)"

for bloco in $(echo "$BLOCOS" | tr ' ' '\n' | shuffle blocos); do
  pos=${bloco%%:*}; cfg=${bloco#*:}; bd="$DIR/$pos-$cfg"
  cells=()
  for load in $LOADS; do for rep in $(seq 1 "$REPS"); do
    [ -f "$bd/ob-$load-$rep/meta.json" ] || cells+=("$load $rep")
  done; done
  [ ${#cells[@]} -eq 0 ] && { echo "$pos-$cfg: completo"; continue; }
  case $pos in
    fe-alone) export OB_PLACEMENT=fe-alone; unset WAYPOINT_NODE_OB ;;
    wp-moved) export OB_PLACEMENT=orig WAYPOINT_NODE_OB=$WP_MOVIDO ;;
    orig) export OB_PLACEMENT=orig; unset WAYPOINT_NODE_OB ;;
    *) die "posição desconhecida: $pos" ;;
  esac
  step "$pos-$cfg: ${#cells[@]} rodadas pendentes (OB_PLACEMENT=$OB_PLACEMENT WAYPOINT_NODE_OB=${WAYPOINT_NODE_OB:-w2})"
  "$MESH_DIR/03-config.sh" "$cfg" > "$DIR/$pos-$cfg-config.log" 2>&1 || die "03-config.sh $cfg falhou (ver $DIR/$pos-$cfg-config.log)"
  mkdir -p "$bd"
  kubectl get pods -A -o wide > "$bd/pods.txt"
  # confere a posição pedida antes de medir
  fe=$(kubectl -n ob get pods -l app=frontend -o jsonpath='{.items[0].spec.nodeName}')
  nos=$(kubectl -n ob get pods --no-headers -o custom-columns=N:.metadata.name,NO:.spec.nodeName)
  junto=$(echo "$nos" | awk -v n="$fe" '$2 == n && $1 !~ /^frontend-/' | wc -l)
  [ "$pos" != fe-alone ] || [ "$junto" -eq 0 ] || die "$pos-$cfg: frontend em $fe com $junto outros pods do ob"
  if [ "$cfg" = IA7 ]; then
    wp=$(echo "$nos" | awk '$1 ~ /^waypoint-/ {print $2; exit}')
    [ "$wp" = "${WAYPOINT_NODE_OB:-w2}" ] || die "$pos-$cfg: waypoint do ob em $wp, esperado ${WAYPOINT_NODE_OB:-w2}"
  fi
  idle_power "$bd/idle.json"
  i=0
  while read -r load rep; do
    i=$((i + 1))
    rate=$(( SAT_ob * load / 100 ))
    livre=$(df -Pk "$DIR" | awk 'NR == 2 {print $4}')
    [ "$livre" -ge $(( ${MIN_LIVRE_GB:-3} * 1024 * 1024 )) ] || die "menos de ${MIN_LIVRE_GB:-3} GB livres em $DIR: pausado"
    echo "[$(date +%H:%M)] $pos-$cfg $i/${#cells[@]}: ob carga $load% ($rate req/s) rodada $rep"
    run_cell "$cfg" ob "$load" "$rate" "$rep" "$bd/ob-$load-$rep"
  done < <(printf '%s\n' "${cells[@]}" | shuffle "$bloco")
done
step "posicionamento concluído: $DIR"

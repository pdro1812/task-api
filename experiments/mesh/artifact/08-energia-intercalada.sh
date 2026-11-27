#!/usr/bin/env bash
# Checagem da energia do IS (resíduo de ~-2 W na bateria, onde cada configuração rodou num bloco de horas):
# B e IS em blocos curtos intercalados (B×3, IS×3, B×3, IS×3) no OB a 90% da base da bateria, com a temperatura do
# pacote (coretemp) registrada por rodada. Se o IS continuar abaixo do ajuste W ~ núcleos, o efeito é do mesh; se
# sumir, era confusão com o horário.
# Uso: ./08-energia-intercalada.sh [diretório]   Saída: <dir>/<cfg>-<bloco>-<rep>/ como na bateria + temp.txt
source "$(dirname "$0")/lib/common.sh"
source "$MESH_DIR/lib/measure.sh"
OUT=${1:-/mnt/dados/resultados/energia-intercalada}
mkdir -p "$OUT"
base=$(sat_min ob B IS IA4 IA7 LK CI) || exit 1; rate=$(( base * 90 / 100 ))
temp() { sensors 2>/dev/null | sed -n 's/^Package id 0: *+\([0-9.]*\).*/\1/p'; }
bloco=0
for cfg in B IS B IS; do
  bloco=$((bloco + 1))
  "$MESH_DIR/03-config.sh" "$cfg" > "$OUT/$cfg-$bloco-config.log" 2>&1 || die "03-config.sh $cfg falhou"
  for rep in 1 2 3; do
    d="$OUT/$cfg-$bloco-$rep"
    [ -f "$d/meta.json" ] && continue
    step "[bloco $bloco] $cfg ob a $rate req/s, rodada $rep"
    t_ini=$(temp)
    run_cell "$cfg" ob 90 "$rate" "$rep" "$d"
    echo "inicio=$t_ini fim=$(temp)" > "$d/temp.txt"
  done
done
step "concluído: $OUT"

#!/usr/bin/env bash
# Piloto: acha, para cada aplicação, a maior taxa que o cluster SEM mesh (configuração B) sustenta dentro do SLO.
# A bateria principal usa 30%, 60% e 90% dessas taxas em todas as configurações.
# Uso: ./03-config.sh B && ./04-saturacao.sh [echo|ob|hotel ...]
# Critério: p99 <= SLO, erros <= 1% e iterações descartadas pelo k6 <= 1%. A taxa sobe 25% a cada passo de 60 s.
source "$(dirname "$0")/lib/common.sh"
source "$MESH_DIR/lib/measure.sh"
[ "$(cat "$STATE/config-atual" 2>/dev/null)" = B ] || die "rode antes: ./03-config.sh B"
declare -A START=([echo]=${START_ECHO:-500} [ob]=${START_OB:-50} [hotel]=${START_HOTEL:-200})
declare -A SLO=([echo]=${SLO_ECHO_MS:-20} [ob]=${SLO_OB_MS:-500} [hotel]=${SLO_HOTEL_MS:-100})
OUT="$STATE/saturacao.env"
APPS=("$@"); [ ${#APPS[@]} -eq 0 ] && APPS=(echo ob hotel)
log="$STATE/saturacao-$(date +%Y%m%d-%H%M).tsv"
echo -e "app\trate\tp99_ms\terr\tdropped" > "$log"

for app in "${APPS[@]}"; do
  step "$app (SLO p99 <= ${SLO[$app]} ms)"
  rate=${START[$app]}; ok=0
  k6_run "$app" "$rate" 30s >/dev/null 2>&1 || true
  while :; do
    SUMMARY="$STATE/sat.json" k6_run "$app" "$rate" 60s >/dev/null 2>&1 || true
    read -r p99 err drop < <(k6_stats "$STATE/sat.json")
    echo -e "$app\t$rate\t$p99\t$err\t$drop" | tee -a "$log"
    if awk -v p="$p99" -v s="${SLO[$app]}" -v e="$err" -v d="$drop" 'BEGIN{exit !(p<=s && e<=0.01 && d<=0.01)}'; then
      ok=$rate; rate=$(( rate * 5 / 4 ))
    else
      break
    fi
  done
  [ "$ok" -gt 0 ] || warn "$app já viola o SLO na taxa inicial ${START[$app]}: reduza START_$(echo "$app" | tr a-z A-Z)"
  sed -i "/^SAT_$app=/d" "$OUT" 2>/dev/null || true
  echo "SAT_$app=$ok" >> "$OUT"
  echo "saturação de $app: $ok req/s"
done
cat "$OUT"

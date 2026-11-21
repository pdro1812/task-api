#!/usr/bin/env bash
# Piloto: acha, para cada aplicação, a maior taxa que uma configuração sustenta dentro do SLO. Roda na configuração
# em que o cluster está, ou em cada uma de CONFIGS (prepara com 03-config.sh). Grava SAT_<app>_<cfg> em
# $STATE/saturacao.env. A vazão máxima por configuração é métrica do RQ1; a bateria usa 30/60/90% da MENOR saturação
# entre as configurações (sat_min em lib/measure.sh), para que todas sustentem todos os níveis.
# Uso: ./04-saturacao.sh [echo|ob|hotel ...]            na configuração atual
#      CONFIGS="IS IA4 IA7 LK CI" ./04-saturacao.sh      em várias, uma depois da outra
# Critério: p99 <= SLO, erros <= 1% e iterações descartadas pelo k6 <= 1%. A taxa sobe 25% a cada passo de 60 s.
# A última taxa aprovada é confirmada com mais um passo; se falhar, recua um passo (o joelho é instável).
# REFINAR=1 (depois da bateria): bissecção de 4 passos entre o último aprovado e o primeiro reprovado, mesmo critério;
#   grava SATF_<app>_<cfg> (resolução ~1,5%), para a métrica de vazão do artigo. A bateria continua usando SAT_.
#   SATF_OUT e SAT_LOG_DIR (repetições, 11-noturno.sh) mudam onde vão o SATF_/SATR_ e o .tsv.
# SUBIR=1 (repetição sem censura): na bissecção de muitas células todos os passos passaram, e o limite superior era
#   só o passo reprovado uma vez na busca inicial. Aqui: confirma SATF_, testa de novo esse limite (1,25 x SAT_) e
#   continua subindo 5% por passo até DUAS reprovações seguidas; grava SATR_<app>_<cfg> = a maior taxa aprovada
#   abaixo dessas duas reprovações (e SATR_FAIL_ = a primeira delas). Lê SATF_ de SATF_BASE (padrão: $OUT).
# Taxa inicial: 30% da saturação da B, se já medida; senão (ou com START_FORCADO=1) START_<APP>.
source "$(dirname "$0")/lib/common.sh"
source "$MESH_DIR/lib/measure.sh"
declare -A START=([echo]=${START_ECHO:-500} [ob]=${START_OB:-50} [hotel]=${START_HOTEL:-200})
declare -A SLO=([echo]=${SLO_ECHO_MS:-20} [ob]=${SLO_OB_MS:-500} [hotel]=${SLO_HOTEL_MS:-100})
OUT="$STATE/saturacao.env"
APPS=("$@"); [ ${#APPS[@]} -eq 0 ] && APPS=(echo ob hotel)

passa() {  # $1 app, $2 taxa: um passo de 60 s; imprime a linha do log e devolve 0 se cumpre o SLO
  local app=$1 rate=$2 p99 err drop
  SUMMARY="$STATE/sat.json" k6_run "$app" "$rate" 60s >/dev/null 2>&1 || true
  read -r p99 err drop < <(k6_stats "$STATE/sat.json")
  echo -e "$CFG\t$app\t$rate\t$p99\t$err\t$drop" | tee -a "$log" >&2
  awk -v p="$p99" -v s="${SLO[$app]}" -v e="$err" -v d="$drop" 'BEGIN{exit !(p<=s && e<=0.01 && d<=0.01)}'
}

satura() {  # na configuração atual
  CFG=$(cat "$STATE/config-atual")
  log="$STATE/saturacao-$CFG-$(date +%Y%m%d-%H%M).tsv"
  echo -e "config\tapp\trate\tp99_ms\terr\tdropped" > "$log"
  for app in "${APPS[@]}"; do
    step "[$CFG] $app (SLO p99 <= ${SLO[$app]} ms)"
    local rate=${START[$app]} ok=0 base
    base=$(sed -n "s/^SAT_${app}_B=//p" "$OUT" 2>/dev/null | tail -1)
    # START_FORCADO=1 usa START_<APP> mesmo fora da B (ex.: CI no echo já viola o SLO a 30% da B)
    [ "$CFG" != B ] && [ -n "$base" ] && [ -z "${START_FORCADO:-}" ] && rate=$(( base * 30 / 100 ))
    k6_run "$app" "$rate" 30s >/dev/null 2>&1 || true
    while passa "$app" "$rate"; do ok=$rate; rate=$(( rate * 5 / 4 )); done
    if [ "$ok" -gt 0 ] && ! passa "$app" "$ok"; then
      ok=$(( ok * 4 / 5 )); passa "$app" "$ok" || ok=0
    fi
    [ "$ok" -gt 0 ] || warn "$app não sustenta a taxa inicial na $CFG: reduza START_$(echo "$app" | tr a-z A-Z)"
    sed -i "/^SAT_${app}_$CFG=/d" "$OUT" 2>/dev/null || true
    echo "SAT_${app}_$CFG=$ok" >> "$OUT"
    echo "saturação de $app na $CFG: $ok req/s"
  done
}

refina() {  # REFINAR=1: bissecção entre SAT_<app>_<cfg> (passou) e +25% (falhou); grava SATF_<app>_<cfg>
  CFG=$(cat "$STATE/config-atual")
  local fout=${SATF_OUT:-$OUT} ldir=${SAT_LOG_DIR:-$STATE}
  mkdir -p "$ldir"; touch "$fout"
  log="$ldir/saturacao-fina-$CFG-$(date +%Y%m%d-%H%M).tsv"
  echo -e "config\tapp\trate\tp99_ms\terr\tdropped" > "$log"
  for app in "${APPS[@]}"; do
    local lo hi mid k
    lo=$(sat_de "$app" "$CFG") || exit 1; hi=$(( lo * 5 / 4 ))
    step "[$CFG] $app: refinando entre $lo e $hi req/s"
    k6_run "$app" "$lo" 30s >/dev/null 2>&1 || true
    for k in 1 2 3 4; do
      mid=$(( (lo + hi) / 2 ))
      if passa "$app" "$mid"; then lo=$mid; else hi=$mid; fi
    done
    sed -i "/^SATF_${app}_$CFG=/d" "$fout" 2>/dev/null || true
    echo "SATF_${app}_$CFG=$lo" >> "$fout"
    echo "saturação refinada de $app na $CFG: $lo req/s (resolução $(( hi - lo )) req/s)"
  done
}

sobe() {  # SUBIR=1: busca para cima até duas reprovações seguidas; grava SATR_<app>_<cfg>
  CFG=$(cat "$STATE/config-atual")
  local fout=${SATF_OUT:-$OUT} ldir=${SAT_LOG_DIR:-$STATE} base=${SATF_BASE:-$OUT}
  mkdir -p "$ldir"; touch "$fout"
  log="$ldir/saturacao-sobe-$CFG-$(date +%Y%m%d-%H%M).tsv"
  echo -e "config\tapp\trate\tp99_ms\terr\tdropped" > "$log"
  for app in "${APPS[@]}"; do
    local f0 hi rate ok=0 falhas=0 prim=0
    f0=$(sed -n "s/^SATF_${app}_$CFG=//p" "$base" | tail -1)
    [ -n "$f0" ] || die "falta SATF_${app}_$CFG em $base"
    hi=$(( $(sat_de "$app" "$CFG") * 5 / 4 ))
    step "[$CFG] $app: subindo a partir de $f0 (limite anterior $hi req/s)"
    k6_run "$app" "$f0" 30s >/dev/null 2>&1 || true
    for rate in "$f0" "$hi"; do
      if passa "$app" "$rate"; then ok=$rate; falhas=0; prim=0
      else falhas=$((falhas + 1)); [ "$falhas" -eq 1 ] && prim=$rate; fi
    done
    rate=$hi
    while [ "$falhas" -lt 2 ]; do
      rate=$(( rate * 105 / 100 ))
      if passa "$app" "$rate"; then ok=$rate; falhas=0; prim=0
      else falhas=$((falhas + 1)); [ "$falhas" -eq 1 ] && prim=$rate; fi
    done
    # SATF_ e o limite reprovaram: desce 5% por passo até aprovar (no máximo 8 passos)
    rate=$f0; local k=0
    while [ "$ok" -eq 0 ] && [ "$k" -lt 8 ]; do
      k=$((k + 1)); rate=$(( rate * 95 / 100 ))
      if passa "$app" "$rate"; then ok=$rate; fi
    done
    sed -i "/^SATR_${app}_$CFG=/d; /^SATR_FAIL_${app}_$CFG=/d" "$fout" 2>/dev/null || true
    echo "SATR_${app}_$CFG=$ok" >> "$fout"
    echo "SATR_FAIL_${app}_$CFG=$prim" >> "$fout"
    echo "saturação (subida) de $app na $CFG: $ok req/s (reprovou duas vezes seguidas a partir de $prim)"
  done
}

[ -n "${REFINAR:-}" ] && { satura() { refina; }; }
[ -n "${SUBIR:-}" ] && { satura() { sobe; }; }
if [ -n "${CONFIGS:-}" ]; then
  for cfg in $CONFIGS; do
    "$MESH_DIR/03-config.sh" "$cfg" > "$STATE/03-$cfg-saturacao.log" 2>&1 || die "03-config.sh $cfg falhou"
    satura
  done
else
  satura
fi
grep '^SAT_' "$OUT"

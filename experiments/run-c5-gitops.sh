#!/usr/bin/env bash
# Retomada do C5 GitOps (rollback de versão quebrada por git revert) a partir da rodada START, com o Argo CD
# acompanhando BRANCH durante as rodadas e restaurado na main ao final (kubectl apply do argocd-app.yaml da main).
# Uso (na raiz do task-api): START=2 RUNS=10 MANIFESTS_DIR=../task-api-manifests OUT=experiments/results/v2 \
#        ./experiments/run-c5-gitops.sh
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-experiments/results/v2}
RUNS=${RUNS:-10}
START=${START:-1}
MANIFESTS_DIR=$(cd "${MANIFESTS_DIR:-../task-api-manifests}" && pwd)
BRANCH=${BRANCH:-experimento-v2}
IMG_BROKEN=${IMG_BROKEN:-task-api:v2-quebrada}
NS=task-api
LOG=$OUT/c5-gitops.log
log() { echo "[$(date +%F' '%T)] $*" | tee -a "$LOG"; }
img() { kubectl -n $NS get deploy/task-api -o jsonpath='{.spec.template.spec.containers[0].image}'; }
wait_argo() {
  local s
  for _ in $(seq 1 90); do
    kubectl -n argocd annotate application task-api-app argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1
    s=$(kubectl -n argocd get application task-api-app -o jsonpath='{.status.sync.status}/{.status.health.status}/{.status.sync.revision}')
    [ "$s" = "Synced/Healthy/$1" ] && return 0; sleep 10
  done
  log "ERRO: Argo CD não ficou Synced/Healthy em $1 ($s)"; return 1
}
unset PRE_VUS NO_REUSE
NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' tcc-worker)
export BASE_URL=http://$NODE_IP:30080 MANIFESTS_DIR BRANCH
log "INÍCIO C5 GitOps, rodadas $START a $RUNS"

git -C "$MANIFESTS_DIR" fetch -q origin
git -C "$MANIFESTS_DIR" checkout -q -B "$BRANCH" "origin/$BRANCH"
git -C "$MANIFESTS_DIR" show "origin/$BRANCH:argocd-app.yaml" | kubectl apply -f - >/dev/null
if wait_argo "$(git -C "$MANIFESTS_DIR" rev-parse HEAD)"; then
  {
    echo "# Retomada do C5 GitOps ($(date -Iseconds)), rodadas $START a $RUNS"
    echo "task-api: $(git rev-parse HEAD)$([ -n "$(git status --porcelain -- experiments ':!experiments/results')" ] && echo ' (ATENÇÃO: árvore com alterações)')"
    echo "task-api-manifests: branch $BRANCH em $(git -C "$MANIFESTS_DIR" rev-parse HEAD); imagem boa $(img)"
    sha256sum experiments/run-c5-gitops.sh experiments/run-broken-rollback.sh experiments/poll-version.py \
      experiments/monitor.sh experiments/k6/carga-constante.js | sed 's/^/  /'
  } > "$OUT/ambiente-c5-gitops.txt"
  GOOD_IMAGE=$(img) BROKEN_IMAGE=$IMG_BROKEN METHOD=gitops START=$START RUNS=$RUNS MONITOR=1 OUT=$OUT \
    bash experiments/run-broken-rollback.sh >> "$LOG" 2>&1 || log "ERRO: run-broken-rollback.sh terminou com falha"
fi

git -C "$MANIFESTS_DIR" fetch -q origin
git -C "$MANIFESTS_DIR" show origin/main:argocd-app.yaml | kubectl apply -f - >/dev/null
wait_argo "$(git -C "$MANIFESTS_DIR" rev-parse origin/main)"
log "Argo CD restaurado na main: $(kubectl -n argocd get application task-api-app -o jsonpath='{.status.sync.status}/{.status.health.status} {.spec.syncPolicy.automated}')"
log "FIM C5 GitOps"

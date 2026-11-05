#!/usr/bin/env bash
# Bateria v2, noite 2: C2 (rolling update com/sem preStop), C3 (rollback com medidor independente: imperativo e
# GitOps com refresh, webhook e polling) e C5 (rollback de versão quebrada: imperativo e GitOps), em Node 22.
# Fase imperativa com o sync automático do Argo CD desligado; fase GitOps com o Argo CD acompanhando BRANCH
# (commits e reverts empurrados para lá). Ao final, kubectl apply do argocd-app.yaml da main.
# Pré-requisitos: imagens IMG_A, IMG_B e IMG_BROKEN carregadas nos nós do kind; BRANCH no repositório de manifestos
# com a configuração do experimento (imagem IMG_A, NodePort 30080, Application com targetRevision BRANCH) e,
# no topo, um commit que troca para IMG_B; árvore do git limpa.
# Uso (na raiz do task-api): MANIFESTS_DIR=../task-api-manifests OUT=experiments/results/v2 ./experiments/run-noite2.sh
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-experiments/results/v2}
RUNS=${RUNS:-10}
MANIFESTS_DIR=$(cd "${MANIFESTS_DIR:-../task-api-manifests}" && pwd)
BRANCH=${BRANCH:-experimento-v2}
IMG_A=${IMG_A:-task-api:v2-a}
IMG_B=${IMG_B:-task-api:v2-b}
IMG_BROKEN=${IMG_BROKEN:-task-api:v2-quebrada}
NS=task-api
mkdir -p "$OUT"
LOG=$OUT/noite2.log
log() { echo "[$(date +%F' '%T)] $*" | tee -a "$LOG"; }
img() { kubectl -n $NS get deploy/task-api -o jsonpath='{.spec.template.spec.containers[0].image}'; }
set_image() { kubectl -n $NS set image deploy/task-api task-api="$1" >/dev/null; kubectl -n $NS rollout status deploy/task-api --timeout=300s >/dev/null; }
wait_argo() {
  local s
  for _ in $(seq 1 90); do
    kubectl -n argocd annotate application task-api-app argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1
    s=$(kubectl -n argocd get application task-api-app -o jsonpath='{.status.sync.status}/{.status.health.status}/{.status.sync.revision}')
    [ "$s" = "Synced/Healthy/$1" ] && return 0; sleep 10
  done
  log "ERRO: Argo CD não ficou Synced/Healthy em $1 ($s)"; return 1
}
# Carga com keep-alive real: poucos VUs (com centenas, cada VU fica ocioso mais que o keep-alive do servidor)
unset PRE_VUS NO_REUSE
echo "iniciada $(date +%F' '%T)" > "$OUT/noite2.status"
log "INÍCIO da noite 2 (RUNS=$RUNS)"

NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' tcc-worker)
export BASE_URL=http://$NODE_IP:30080 MANIFESTS_DIR BRANCH

# Argo CD passa a acompanhar BRANCH (Application do próprio branch: sem exclusões, sem auto-poda)
git -C "$MANIFESTS_DIR" fetch -q origin
git -C "$MANIFESTS_DIR" checkout -q -B "$BRANCH" "origin/$BRANCH"
git -C "$MANIFESTS_DIR" show "origin/$BRANCH:argocd-app.yaml" | kubectl apply -f - >/dev/null
wait_argo "$(git -C "$MANIFESTS_DIR" rev-parse HEAD)" || exit 1
log "Argo CD no branch $BRANCH ($(git -C "$MANIFESTS_DIR" rev-parse --short HEAD)), imagem $(img)"

node_digest() { docker exec tcc-worker crictl inspecti -o go-template --template '{{index .status.repoDigests 0}}{{if not .status.repoDigests}}{{.status.id}}{{end}}' "$1" 2>/dev/null; }
{
  echo "# Ambiente da bateria v2 — noite 2 ($(date -Iseconds))"
  echo "Host: $(lscpu | sed -n 's/^Model name: *//p') — $(nproc) threads; RAM $(free -h | awk '/Mem:/{print $2}'); $(. /etc/os-release; echo "$PRETTY_NAME"), kernel $(uname -r)"
  echo "Docker: $(docker version --format '{{.Server.Version}}'); kind: $(kind version)"
  echo "Imagem dos nós (kindest/node): $(docker inspect --format '{{.Config.Image}}' tcc-worker)"
  echo "Kubernetes: $(kubectl version -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])'); kubectl $(kubectl version --client -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')"
  echo "k6: $(k6 version | head -1)"
  for i in "$IMG_A" "$IMG_B" "$IMG_BROKEN"; do
    echo "Imagem $i: id $(docker exec tcc-worker crictl inspecti -o go-template --template '{{.status.id}}' "$i" 2>/dev/null); $(docker run --rm --entrypoint node "$i" -e 'console.log("Node.js", process.version, "BUILD_SHA=" + process.env.BUILD_SHA)')"
  done
  echo "  ($IMG_A = pdros1812/task-api:bed4207 retagueada: $(docker inspect --format '{{index .RepoDigests 0}}' pdros1812/task-api:bed4207 2>/dev/null); $IMG_B = build local do mesmo commit com BUILD_SHA=bed4207-b; $IMG_BROKEN = experiments/imagem-quebrada sobre $IMG_A)"
  echo "Redis: $(kubectl -n $NS get pod -l app=redis -o jsonpath='{.items[0].status.containerStatuses[0].imageID}')"
  echo "Argo CD: $(kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].status.containerStatuses[0].image} {.items[0].status.containerStatuses[0].imageID}')"
  echo "Sealed Secrets: $(kubectl -n kube-system get pod -l name=sealed-secrets-controller -o jsonpath='{.items[0].status.containerStatuses[0].image} {.items[0].status.containerStatuses[0].imageID}')"
  echo "task-api: $(git rev-parse HEAD)$([ -n "$(git status --porcelain -- experiments ':!experiments/results')" ] && echo ' (ATENÇÃO: árvore com alterações)')"
  echo "task-api-manifests: branch $BRANCH em $(git -C "$MANIFESTS_DIR" rev-parse HEAD) (main: $(git -C "$MANIFESTS_DIR" rev-parse origin/main))"
  echo "Carga (C2, C5): k6 constant-arrival-rate 50 req/s, GET /tasks, timeout 5 s, PRE_VUS=50 (keep-alive); C3: /version a cada 100 ms"
  echo "sha256 dos scripts:"
  sha256sum experiments/run-noite2.sh experiments/run-rolling-update.sh experiments/measure-rollback.sh \
    experiments/run-broken-rollback.sh experiments/poll-version.py experiments/monitor.sh \
    experiments/k6/carga-constante.js experiments/imagem-quebrada/Dockerfile | sed 's/^/  /'
} > "$OUT/ambiente-noite2.txt"
log "ambiente registrado em $OUT/ambiente-noite2.txt"

# ---------- Fase imperativa (sync automático desligado) ----------
kubectl -n argocd patch application task-api-app --type=json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null

log "C2: rolling update com preStop"
set_image "$IMG_A"
IMAGE=task-api TAG_A=${IMG_A#task-api:} TAG_B=${IMG_B#task-api:} LABEL=prestop RUNS=$RUNS MONITOR=1 OUT=$OUT \
  bash experiments/run-rolling-update.sh >> "$LOG" 2>&1
log "C2: rolling update sem preStop"
set_image "$IMG_A"
kubectl -n $NS patch deploy/task-api --type=json -p '[{"op":"remove","path":"/spec/template/spec/containers/0/lifecycle"}]' >/dev/null
kubectl -n $NS rollout status deploy/task-api --timeout=300s >/dev/null
IMAGE=task-api TAG_A=${IMG_A#task-api:} TAG_B=${IMG_B#task-api:} LABEL=noprestop RUNS=$RUNS MONITOR=1 OUT=$OUT \
  bash experiments/run-rolling-update.sh >> "$LOG" 2>&1
kubectl -n $NS patch deploy/task-api --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/lifecycle","value":{"preStop":{"exec":{"command":["/bin/sh","-c","sleep 5"]}}}}]' >/dev/null
kubectl -n $NS rollout status deploy/task-api --timeout=300s >/dev/null

log "C3: rollback imperativo (medidor de /version a 100 ms)"
set_image "$IMG_A"; set_image "$IMG_B"; sleep 10   # as duas últimas revisões têm BUILD_SHA diferentes
for i in $(seq 1 "$RUNS"); do
  POLLER=1 MONITOR=1 METHOD=imperativo LABEL=imperativo OUT=$OUT bash experiments/measure-rollback.sh >> "$LOG" 2>&1
  sleep 10
done

log "C5: versão quebrada, rollback imperativo"
GOOD_IMAGE=$(img) BROKEN_IMAGE=$IMG_BROKEN METHOD=imperativo RUNS=$RUNS MONITOR=1 OUT=$OUT \
  bash experiments/run-broken-rollback.sh >> "$LOG" 2>&1

# ---------- Fase GitOps (Argo CD no branch, sync automático + selfHeal) ----------
git -C "$MANIFESTS_DIR" show "origin/$BRANCH:argocd-app.yaml" | kubectl apply -f - >/dev/null
wait_argo "$(git -C "$MANIFESTS_DIR" rev-parse HEAD)" || exit 1
log "Argo CD de volta ao branch com selfHeal; imagem $(img)"

kubectl -n argocd port-forward svc/argocd-server 8443:443 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null' EXIT; sleep 3
export WEBHOOK_URL=https://localhost:8443/api/webhook
for variant in refresh webhook polling; do
  log "C3: rollback GitOps ($variant)"
  for i in $(seq 1 "$RUNS"); do
    case $variant in
      refresh) REFRESH=1 ;; webhook) WEBHOOK=1 ;; polling) ;;
    esac
    REFRESH=${REFRESH:-0} WEBHOOK=${WEBHOOK:-0} POLLER=1 MONITOR=1 METHOD=gitops LABEL=gitops-$variant OUT=$OUT \
      bash experiments/measure-rollback.sh >> "$LOG" 2>&1
    unset REFRESH WEBHOOK
    sleep 10
  done
done

log "C5: versão quebrada, rollback GitOps (commit + push; git revert + push; refresh)"
GOOD_IMAGE=$(img) BROKEN_IMAGE=$IMG_BROKEN METHOD=gitops RUNS=$RUNS MONITOR=1 OUT=$OUT \
  bash experiments/run-broken-rollback.sh >> "$LOG" 2>&1

# ---------- Restauração ----------
git -C "$MANIFESTS_DIR" fetch -q origin
git -C "$MANIFESTS_DIR" show origin/main:argocd-app.yaml | kubectl apply -f - >/dev/null
wait_argo "$(git -C "$MANIFESTS_DIR" rev-parse origin/main)"
log "Argo CD restaurado na main: $(kubectl -n argocd get application task-api-app -o jsonpath='{.status.sync.status}/{.status.health.status} {.spec.syncPolicy.automated}')"
echo "concluída $(date +%F' '%T)" > "$OUT/noite2.status"
log "FIM da noite 2"

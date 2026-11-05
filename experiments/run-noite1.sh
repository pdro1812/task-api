#!/usr/bin/env bash
# Bateria v2, noite 1: C1 (10 configurações x RUNS, ordem aleatória) + C4 (Redis pendurado, 3 modos x RUNS),
# na configuração final dos manifestos (Sealed Secrets, probes autenticadas, PVC + AOF).
# Pré-requisitos: cluster kind "tcc" com o Argo CD Synced/Healthy na main dos manifestos; árvore do git limpa.
# Uso (na raiz do task-api): MANIFESTS_DIR=../task-api-manifests OUT=experiments/results/v2 ./experiments/run-noite1.sh
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-experiments/results/v2}
RUNS=${RUNS:-10}
MANIFESTS_DIR=${MANIFESTS_DIR:-../task-api-manifests}
NS=task-api
mkdir -p "$OUT"
LOG=$OUT/noite1.log
log() { echo "[$(date +%F' '%T)] $*" | tee -a "$LOG"; }
echo "iniciada $(date +%F' '%T)" > "$OUT/noite1.status"
log "INÍCIO da noite 1"

NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' tcc-worker)
export BASE_URL=http://$NODE_IP:30080

# Imagem da API (a do Git, gerada pelo CI) carregada nos nós: os rollouts não dependem do Docker Hub
IMG=$(kubectl -n $NS get deploy task-api -o jsonpath='{.spec.template.spec.containers[0].image}')
docker pull -q "$IMG" >/dev/null && kind load docker-image --name tcc "$IMG" >/dev/null 2>&1

# Durante a bateria o Argo CD não sincroniza: o selfHeal desfaria as mudanças do experimento e uma nova tag do
# CI trocaria a imagem no meio. Ao final, kubectl apply do argocd-app.yaml da main restaura tudo.
kubectl -n argocd patch application task-api-app --type=json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null
kubectl -n $NS patch deploy/task-api --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >/dev/null
kubectl -n $NS patch svc/task-api-service -p '{"spec":{"type":"NodePort","ports":[{"port":80,"targetPort":3000,"nodePort":30080}]}}' >/dev/null
kubectl -n $NS rollout status deploy/task-api --timeout=300s >/dev/null

node_digest() { docker exec tcc-worker crictl inspecti -o go-template --template '{{index .status.repoDigests 0}}' "$1" 2>/dev/null; }
{
  echo "# Ambiente da bateria v2 — noite 1 ($(date -Iseconds))"
  echo "Host: $(lscpu | sed -n 's/^Model name: *//p') — $(nproc) threads; RAM $(free -h | awk '/Mem:/{print $2}'); $(. /etc/os-release; echo "$PRETTY_NAME"), kernel $(uname -r)"
  echo "Docker: $(docker version --format '{{.Server.Version}}')"
  echo "kind: $(kind version)"
  echo "Imagem dos nós (kindest/node): $(docker inspect --format '{{.Config.Image}}' tcc-worker) ($(docker inspect --format '{{.Image}}' tcc-worker))"
  echo "Kubernetes: $(kubectl version -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])'); kube-proxy: $(kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | sed -n 's/^mode: *//p')"
  echo "kubectl: $(kubectl version --client -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')"
  echo "k6: $(k6 version | head -1)"
  echo "API: $IMG -> $(node_digest "$IMG"); Node.js $(docker run --rm --entrypoint node "$IMG" --version)"
  echo "Redis: $(kubectl -n $NS get deploy redis -o jsonpath='{.spec.template.spec.containers[0].image}') -> $(kubectl -n $NS get pod -l app=redis -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'); $(kubectl -n $NS exec deploy/redis -- redis-server --version | cut -d' ' -f1-3)"
  echo "Argo CD: $(kubectl -n argocd get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}') -> $(kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].status.containerStatuses[0].imageID}')"
  echo "Sealed Secrets: $(kubectl -n kube-system get deploy sealed-secrets-controller -o jsonpath='{.spec.template.spec.containers[0].image}') -> $(kubectl -n kube-system get pod -l name=sealed-secrets-controller -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'); kubeseal $(kubeseal --version 2>/dev/null | awk '{print $3}')"
  echo "task-api: $(git rev-parse HEAD)$([ -n "$(git status --porcelain -- experiments ':!experiments/results')" ] && echo ' (ATENÇÃO: árvore com alterações)')"
  echo "task-api-manifests: $(git -C "$MANIFESTS_DIR" fetch -q origin && git -C "$MANIFESTS_DIR" rev-parse origin/main) (Argo CD: $(kubectl -n argocd get application task-api-app -o jsonpath='{.status.sync.revision}'))"
  echo "Ajustes durante a bateria: sync automático do Argo CD desligado; imagePullPolicy=IfNotPresent; Service NodePort 30080"
  echo "Carga: k6 constant-arrival-rate 50 req/s, GET /tasks (5 tarefas semeadas), timeout 5 s, MAX_VUS=1000, PRE_VUS=50 com keep-alive e 600 sem keep-alive"
  echo "sha256 dos scripts:"
  sha256sum experiments/run-noite1.sh experiments/run-c1-randomizado.sh experiments/run-redis-outage.sh \
    experiments/monitor.sh experiments/k6/carga-constante.js | sed 's/^/  /'
} > "$OUT/ambiente-noite1.txt"
log "ambiente registrado em $OUT/ambiente-noite1.txt"

# 5 tarefas pré-existentes: cada rodada registra o LLEN antes da falha e depois da recuperação (persistência)
kubectl -n $NS set env deploy/task-api RESILIENCE_MODE=failfast READINESS_DEPENDS_ON_REDIS=false >/dev/null
kubectl -n $NS rollout status deploy/task-api --timeout=180s >/dev/null
n=$(curl -s "$BASE_URL/tasks" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')
for i in $(seq $((n + 1)) 5); do
  curl -s -o /dev/null -X POST "$BASE_URL/tasks" -H 'Content-Type: application/json' -d "{\"description\":\"persistencia $i\"}"
done
log "tarefas semeadas: $(curl -s "$BASE_URL/tasks" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
export COUNT_TASKS=1

log "C1: 10 configurações x $RUNS rodadas, ordem aleatória"
CONFIGS="baseline:false:keepalive baseline:true:keepalive failfast:false:keepalive failfast:true:keepalive breaker:false:keepalive breaker:true:keepalive failfast:false:noreuse failfast:true:noreuse breaker:false:noreuse breaker:true:noreuse" \
  RUNS=$RUNS SEED=20261105 FAULT=outage OUT=$OUT bash experiments/run-c1-randomizado.sh >> "$LOG" 2>&1
log "C1 concluído"

log "C4: Redis pendurado (CLIENT PAUSE 60 s; a liveness autenticada reinicia o Redis), 3 modos x $RUNS rodadas"
CONFIGS="baseline:false:keepalive failfast:false:keepalive breaker:false:keepalive" \
  RUNS=$RUNS SEED=20261106 FAULT=pause OUT=$OUT bash experiments/run-c1-randomizado.sh >> "$LOG" 2>&1
log "C4 concluído"

git -C "$MANIFESTS_DIR" show origin/main:argocd-app.yaml | kubectl apply -f - >/dev/null
for i in $(seq 1 60); do
  s=$(kubectl -n argocd get application task-api-app -o jsonpath='{.status.sync.status}/{.status.health.status}')
  [ "$s" = Synced/Healthy ] && break; sleep 10
done
log "Argo CD restaurado: $s"
echo "concluída $(date +%F' '%T)" > "$OUT/noite1.status"
log "FIM da noite 1"

#!/usr/bin/env bash
# Ponto de entrada dos experimentos (depois de ./experiments/setup.sh).
# Uso (na raiz do task-api): ./experiments/run.sh <bateria> [arg]
#   noite1               C1 (10 configurações) + C4 (3 modos), RUNS rodadas cada  -> experiments/run-noite1.sh
#   noite2               C2 + C3 + C5 (imperativo e GitOps)                       -> experiments/run-noite2.sh
#   c1 [modo:rd:cliente] C1 de uma configuração (padrão failfast:false:keepalive)
#   c4 [modo]            C4 (Redis pendurado) de um modo (padrão breaker)
#   c5                   C5 (versão quebrada), rollback imperativo
# Variáveis: RUNS (padrão 10), OUT (padrão experiments/results/<bateria>-<data>), MANIFESTS_DIR,
#   IMG_A / IMG_B / IMG_BROKEN (padrão: imagens repro-* geradas pelo setup.sh).
# noite2 usa GitOps: exige que o Argo CD acompanhe um repositório de manifestos com permissão de push (BRANCH).
# Os parâmetros de medição (carga, tempos, VUs) ficam nos scripts chamados e não mudam aqui.
set -uo pipefail
cd "$(dirname "$0")/.."
BATTERY=${1:?uso: ./experiments/run.sh <noite1|noite2|c1|c4|c5> [arg]}
ARG=${2:-}
export RUNS=${RUNS:-10}
export MANIFESTS_DIR=$(cd "${MANIFESTS_DIR:-../task-api-manifests}" && pwd)
export IMG_A=${IMG_A:-task-api:repro-a} IMG_B=${IMG_B:-task-api:repro-b} IMG_BROKEN=${IMG_BROKEN:-task-api:repro-quebrada}
export OUT=${OUT:-experiments/results/$BATTERY-$(date +%Y%m%d-%H%M)}
NS=task-api
mkdir -p "$OUT"
NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' tcc-worker)
export BASE_URL=http://$NODE_IP:30080
has_argo() { kubectl -n argocd get application task-api-app >/dev/null 2>&1; }
# Espera terminar qualquer operação de sync do Argo CD em andamento (uma sync iniciada antes do prepare desfaria
# as mudanças do experimento no meio da rodada)
wait_argo_idle() {
  local phase
  for _ in $(seq 1 90); do
    phase=$(kubectl -n argocd get application task-api-app -o jsonpath='{.status.operationState.phase}' 2>/dev/null)
    [ "$phase" != Running ] && return 0; sleep 5
  done
  echo "AVISO: sync do Argo CD ainda em andamento" >&2
}
wait_argo_synced() {
  local s
  for _ in $(seq 1 90); do
    kubectl -n argocd annotate application task-api-app argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1
    s=$(kubectl -n argocd get application task-api-app -o jsonpath='{.status.sync.status}/{.status.health.status}')
    [ "$s" = Synced/Healthy ] && { wait_argo_idle; return 0; }; sleep 10
  done
  echo "AVISO: Argo CD não ficou Synced/Healthy ($s)" >&2
}

prepare() {
  # Sem sincronização automática durante a injeção de falhas; tráfego pelo Service (NodePort); imagem local
  if has_argo; then
    kubectl -n argocd patch application task-api-app --type=json \
      -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null 2>&1
    wait_argo_idle
    # O task-api-app gerencia a si mesmo: uma sync que estava em andamento reaplica o argocd-app.yaml do Git e
    # religa o sync automático; por isso desliga-se de novo depois que ela termina
    kubectl -n argocd patch application task-api-app --type=json \
      -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null 2>&1
  fi
  kubectl -n $NS patch svc/task-api-service -p '{"spec":{"type":"NodePort","ports":[{"port":80,"targetPort":3000,"nodePort":30080}]}}' >/dev/null
  kubectl -n $NS set image deploy/task-api task-api="$IMG_A" >/dev/null
  kubectl -n $NS patch deploy/task-api --type=json \
    -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >/dev/null
  kubectl -n $NS set env deploy/task-api RESILIENCE_MODE=failfast READINESS_DEPENDS_ON_REDIS=false >/dev/null
  kubectl -n $NS rollout status deploy/task-api --timeout=300s >/dev/null
  local n
  n=$(curl -s "$BASE_URL/tasks" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')
  for i in $(seq $((n + 1)) 5); do
    curl -s -o /dev/null -X POST "$BASE_URL/tasks" -H 'Content-Type: application/json' -d "{\"description\":\"persistencia $i\"}"
  done
}

restore() {
  if has_argo; then
    # Volta ao Git: o selfHeal desfaz env, imagem, imagePullPolicy e NodePort
    git -C "$MANIFESTS_DIR" fetch -q origin 2>/dev/null
    { git -C "$MANIFESTS_DIR" show origin/main:argocd-app.yaml 2>/dev/null || cat "$MANIFESTS_DIR/argocd-app.yaml"; } | kubectl apply -f - >/dev/null
    wait_argo_synced
  else
    kubectl -n $NS set env deploy/task-api RESILIENCE_MODE- READINESS_DEPENDS_ON_REDIS- >/dev/null
    kubectl -n $NS patch svc/task-api-service --type=json \
      -p '[{"op":"replace","path":"/spec/type","value":"ClusterIP"},{"op":"remove","path":"/spec/ports/0/nodePort"}]' >/dev/null
    kubectl -n $NS rollout status deploy/task-api --timeout=300s >/dev/null
  fi
}

case "$BATTERY" in
  noite1) bash experiments/run-noite1.sh ;;
  noite2) bash experiments/run-noite2.sh ;;
  c1|c4|c5)
    prepare
    case "$BATTERY" in
      c1) CONFIGS=${ARG:-failfast:false:keepalive} SEED=20261105 FAULT=outage COUNT_TASKS=1 \
            bash experiments/run-c1-randomizado.sh ;;
      c4) CONFIGS="${ARG:-breaker}:false:keepalive" SEED=20261106 FAULT=pause COUNT_TASKS=1 \
            bash experiments/run-c1-randomizado.sh ;;
      c5) GOOD_IMAGE=$IMG_A BROKEN_IMAGE=$IMG_BROKEN METHOD=imperativo MONITOR=1 \
            bash experiments/run-broken-rollback.sh ;;
    esac
    status=$?
    restore
    echo "resultados em $OUT"
    exit $status ;;
  *) echo "bateria desconhecida: $BATTERY" >&2; exit 2 ;;
esac

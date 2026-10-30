#!/usr/bin/env bash
# Cenário 3: tempo de recuperação (TTR) de um rollback, medido até a nova versão estar
# respondendo em /version (e não apenas até o comando retornar).
# Uso:
#   METHOD=imperativo ./experiments/measure-rollback.sh          (kubectl rollout undo)
#   METHOD=gitops MANIFESTS_DIR=../task-api-manifests ./experiments/measure-rollback.sh  (git revert + push)
set -euo pipefail
NS=${NS:-task-api}
METHOD=${METHOD:-imperativo}
BASE_URL=${BASE_URL:-http://localhost:8080}
OUT=${OUT:-experiments/results}
mkdir -p "$OUT"

before=$(curl -s "$BASE_URL/version")
t0=$(date +%s.%N)
case "$METHOD" in
  imperativo)
    kubectl -n "$NS" rollout undo deploy/task-api ;;
  gitops)
    git -C "$MANIFESTS_DIR" revert --no-edit HEAD
    git -C "$MANIFESTS_DIR" push origin main
    # Sem webhook o ArgoCD só percebe no próximo polling (padrão: 180 s); com REFRESH=1 forçamos o refresh
    [ "${REFRESH:-0}" = 1 ] && argocd app get task-api-app --refresh >/dev/null ;;
esac
t_cmd=$(date +%s.%N)
kubectl -n "$NS" rollout status deploy/task-api --timeout=600s
t_rollout=$(date +%s.%N)
# Espera todas as respostas virem da versão anterior
until [ "$(curl -s "$BASE_URL/version")" != "$before" ]; do sleep 0.2; done
t_served=$(date +%s.%N)
echo "$METHOD,$t0,$t_cmd,$t_rollout,$t_served" | tee -a "$OUT/rollback.csv"

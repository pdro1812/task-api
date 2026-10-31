#!/usr/bin/env bash
# Cenário 3: tempo de recuperação (TTR) de um rollback, medido até a nova versão estar
# respondendo em /version (e não apenas até o comando retornar).
# Uso:
#   METHOD=imperativo ./experiments/measure-rollback.sh          (kubectl rollout undo)
#   METHOD=gitops MANIFESTS_DIR=../task-api-manifests ./experiments/measure-rollback.sh  (git revert + push)
#   Variantes GitOps: padrão = polling do ArgoCD; REFRESH=1 = refresh manual logo após o push;
#   WEBHOOK=1 = envia ao argocd-server o payload de push do GitHub (WEBHOOK_URL, ex.: via port-forward).
#   BRANCH escolhe o branch acompanhado pelo ArgoCD (padrão: main). LABEL nomeia a variante no CSV.
set -euo pipefail
NS=${NS:-task-api}
METHOD=${METHOD:-imperativo}
BASE_URL=${BASE_URL:-http://localhost:8080}
OUT=${OUT:-experiments/results}
mkdir -p "$OUT"

before=$(curl -s "$BASE_URL/version")
img() { kubectl -n "$NS" get deploy/task-api -o jsonpath='{.spec.template.spec.containers[0].image}'; }
img_before=$(img)
t0=$(date +%s.%N)
case "$METHOD" in
  imperativo)
    kubectl -n "$NS" rollout undo deploy/task-api ;;
  gitops)
    git -C "$MANIFESTS_DIR" revert --no-edit HEAD
    git -C "$MANIFESTS_DIR" push -q origin "HEAD:${BRANCH:-main}"
    # Sem webhook o ArgoCD só percebe no próximo polling; REFRESH=1 força o refresh (equivale a argocd app get --refresh)
    if [ "${REFRESH:-0}" = 1 ]; then
      kubectl -n argocd annotate application task-api-app argocd.argoproj.io/refresh=normal --overwrite >/dev/null
    fi
    if [ "${WEBHOOK:-0}" = 1 ]; then
      sha=$(git -C "$MANIFESTS_DIR" rev-parse HEAD)
      curl -sk -o /dev/null -X POST "$WEBHOOK_URL" -H 'Content-Type: application/json' -H 'X-GitHub-Event: push' \
        -d "{\"ref\":\"refs/heads/${BRANCH:-main}\",\"before\":\"0000000000000000000000000000000000000000\",\"after\":\"$sha\",\"repository\":{\"html_url\":\"https://github.com/pdro1812/task-api-manifests\",\"default_branch\":\"main\"},\"commits\":[{\"id\":\"$sha\",\"modified\":[\"3-api.yaml\"],\"added\":[],\"removed\":[]}]}"
    fi
    true ;;
esac
t_cmd=$(date +%s.%N)
# No GitOps o Deployment só muda quando o ArgoCD sincroniza: espera a troca de imagem antes do rollout status
[ "$METHOD" = gitops ] && until [ "$(img)" != "$img_before" ]; do sleep 0.2; done
kubectl -n "$NS" rollout status deploy/task-api --timeout=600s
t_rollout=$(date +%s.%N)
# Espera todas as respostas virem da versão anterior
until v=$(curl -s "$BASE_URL/version") && [ -n "$v" ] && [ "$v" != "$before" ]; do sleep 0.2; done
t_served=$(date +%s.%N)
echo "${LABEL:-$METHOD},$t0,$t_cmd,$t_rollout,$t_served" | tee -a "$OUT/rollback.csv"

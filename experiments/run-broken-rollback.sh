#!/usr/bin/env bash
# Cenário: rollback de uma versão quebrada sob carga (imagem cujo /ready sempre responde 503).
# Por rodada: carga constante; em T=DEPLOY_AT a versão quebrada é implantada; o operador detecta a falha quando o
# rollout fica DETECT segundos sem concluir; então faz o rollback e mede até o Deployment estabilizar (nenhum Pod
# da versão quebrada). Um medidor independente consulta /version a cada 100 ms.
#   METHOD=imperativo (padrão): kubectl set image / kubectl rollout undo
#   METHOD=gitops: commit da imagem quebrada + push; rollback por git revert + push (BRANCH, MANIFESTS_DIR);
#     cada push é seguido de refresh do Argo CD (anotação), como no C3 com refresh manual
# Uso: GOOD_IMAGE=... BROKEN_IMAGE=... BASE_URL=http://IP:30080 RUNS=10 ./experiments/run-broken-rollback.sh
set -euo pipefail
NS=${NS:-task-api}
RUNS=${RUNS:-10}
METHOD=${METHOD:-imperativo}
DEPLOY_AT=${DEPLOY_AT:-30}
DETECT=${DETECT:-60}
DURATION=${DURATION:-150}
OUT=${OUT:-experiments/results}
GOOD_IMAGE=${GOOD_IMAGE:?defina GOOD_IMAGE}
BROKEN_IMAGE=${BROKEN_IMAGE:?defina BROKEN_IMAGE}
BASE_URL=${BASE_URL:?defina BASE_URL}
mkdir -p "$OUT"
[ "${MONITOR:-0}" = 1 ] && source "$(dirname "$0")/monitor.sh"

img() { kubectl -n "$NS" get deploy/task-api -o jsonpath='{.spec.template.spec.containers[0].image}'; }
refresh() { kubectl -n argocd annotate application task-api-app argocd.argoproj.io/refresh=normal --overwrite >/dev/null; }
git_push() { git -C "$MANIFESTS_DIR" push -q origin "HEAD:${BRANCH:?defina BRANCH}"; refresh; }

for i in $(seq "${START:-1}" "$RUNS"); do
  base="$OUT/quebrada-$METHOD-$i"
  echo "== rodada $i (versão quebrada, $METHOD)"
  if [ "$METHOD" = imperativo ]; then
    kubectl -n "$NS" set image deploy/task-api task-api="$GOOD_IMAGE" >/dev/null
  else
    [ "$(img)" = "$GOOD_IMAGE" ] || { echo "ERRO: o Git não está na versão boa ($(img))"; exit 1; }
  fi
  kubectl -n "$NS" rollout status deploy/task-api --timeout=180s
  sleep 5
  [ "${MONITOR:-0}" = 1 ] && monitor_start "$base"
  python3 "$(dirname "$0")/poll-version.py" "$BASE_URL" "$base.versions" 0.1 &
  POLL=$!
  k6 run -q -e DURATION="${DURATION}s" --out csv="$base.csv" experiments/k6/carga-constante.js &
  K6=$!
  sleep "$DEPLOY_AT"
  date +%s.%N > "$base.deploy"
  if [ "$METHOD" = imperativo ]; then
    kubectl -n "$NS" set image deploy/task-api task-api="$BROKEN_IMAGE" >/dev/null
  else
    sed -i "s|image: $GOOD_IMAGE\$|image: $BROKEN_IMAGE|" "$MANIFESTS_DIR/3-api.yaml"
    git -C "$MANIFESTS_DIR" commit -qam "exp(v2): versão quebrada (rodada $i)"
    git_push
    until [ "$(img)" = "$BROKEN_IMAGE" ]; do sleep 0.2; done
  fi
  date +%s.%N > "$base.applied"
  if kubectl -n "$NS" rollout status deploy/task-api --timeout="${DETECT}s"; then
    echo "AVISO: o rollout da versão quebrada concluiu (não deveria)" | tee "$base.aviso"
  fi
  date +%s.%N > "$base.detect"
  if [ "$METHOD" = imperativo ]; then
    kubectl -n "$NS" rollout undo deploy/task-api >/dev/null
  else
    git -C "$MANIFESTS_DIR" revert --no-edit HEAD >/dev/null
    git_push
  fi
  date +%s.%N > "$base.undo"
  [ "$METHOD" = gitops ] && until [ "$(img)" = "$GOOD_IMAGE" ]; do sleep 0.2; done
  date +%s.%N > "$base.reverted"
  kubectl -n "$NS" rollout status deploy/task-api --timeout=180s
  # Estável = nenhum Pod da versão quebrada restante
  until [ -z "$(kubectl -n "$NS" get pods -l app=task-api -o jsonpath="{range .items[?(@.spec.containers[0].image=='$BROKEN_IMAGE')]}{.metadata.name}{end}")" ]; do sleep 0.2; done
  date +%s.%N > "$base.done"
  wait "$K6" || true
  kill "$POLL"; wait "$POLL" 2>/dev/null || true
  [ "${MONITOR:-0}" = 1 ] && monitor_stop
  kubectl -n "$NS" get pods -o wide > "$base.pods"
  kubectl -n "$NS" rollout history deploy/task-api > "$base.history"
  sleep 15
done

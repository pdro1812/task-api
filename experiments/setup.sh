#!/usr/bin/env bash
# Prepara o ambiente dos experimentos. Idempotente: pode ser executado de novo sobre um cluster existente.
#   1. confere pré-requisitos e versões (experiments/versions.env)
#   2. cria o cluster kind CLUSTER (se ainda não existir) com a imagem de nó fixada por digest
#   3. constrói as imagens da API (versões A e B, com BUILD_SHA diferentes, e a versão quebrada) e as carrega nos nós
#   4. instala o Sealed Secrets (manifesto versionado no repositório de manifestos) e o Argo CD (URL fixa da versão)
#   5. aplica os manifestos da aplicação, a menos que o Argo CD já os gerencie (Application task-api-app)
# Uso (na raiz do task-api): MANIFESTS_DIR=../task-api-manifests ./experiments/setup.sh
#   GITOPS=1 também registra o Application do repositório de manifestos no Argo CD (exige um fork com permissão
#   de push para os cenários GitOps; ver experiments/README.md).
set -euo pipefail
cd "$(dirname "$0")/.."
source experiments/versions.env
CLUSTER=${CLUSTER:-tcc}
NS=task-api
MANIFESTS_DIR=$(cd "${MANIFESTS_DIR:-../task-api-manifests}" && pwd)
step() { echo "== $*"; }
warn() { echo "AVISO: $*" >&2; }

step "pré-requisitos"
for t in docker kind kubectl k6 git python3 curl; do
  command -v "$t" >/dev/null || { echo "falta a ferramenta: $t" >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "sem acesso ao Docker (o usuário está no grupo docker?)" >&2; exit 1; }
kind version | grep -q "$KIND_VERSION" || warn "kind diferente de $KIND_VERSION: $(kind version)"
k6 version | grep -q "$K6_VERSION" || warn "k6 diferente de $K6_VERSION: $(k6 version | head -1)"
python3 -c 'import matplotlib, scipy' 2>/dev/null || warn "para a análise: pip install -r experiments/requirements.txt"
for f in 1-redis.yaml 2-config.yaml 3-api.yaml sealed-secrets; do
  [ -e "$MANIFESTS_DIR/$f" ] || { echo "MANIFESTS_DIR sem $f: $MANIFESTS_DIR" >&2; exit 1; }
done

step "cluster kind '$CLUSTER'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "já existe; reutilizando"
else
  kind create cluster --name "$CLUSTER" --config experiments/kind-cluster.yaml
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null

step "imagens da API (build local) carregadas nos nós"
SHA=$(git rev-parse --short HEAD)
IMG_A=${IMG_A:-task-api:repro-a}
IMG_B=${IMG_B:-task-api:repro-b}
IMG_BROKEN=${IMG_BROKEN:-task-api:repro-quebrada}
docker build -q --build-arg BUILD_SHA="$SHA" -t "$IMG_A" . >/dev/null
docker build -q --build-arg BUILD_SHA="$SHA-b" -t "$IMG_B" . >/dev/null
docker build -q --build-arg BASE="$IMG_A" -t "$IMG_BROKEN" experiments/imagem-quebrada >/dev/null
kind load docker-image --name "$CLUSTER" "$IMG_A" "$IMG_B" "$IMG_BROKEN" >/dev/null
echo "$IMG_A, $IMG_B e $IMG_BROKEN (BUILD_SHA=$SHA, $SHA-b, quebrada)"

step "Sealed Secrets $SEALED_SECRETS_VERSION"
kubectl apply -f "$MANIFESTS_DIR"/sealed-secrets/controller-*.yaml >/dev/null
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=300s >/dev/null

step "Argo CD $ARGOCD_VERSION"
kubectl get ns argocd >/dev/null 2>&1 || kubectl create ns argocd >/dev/null
kubectl apply -n argocd --server-side --force-conflicts -f "$ARGOCD_INSTALL_URL" >/dev/null
for d in argocd-repo-server argocd-server; do kubectl -n argocd rollout status "deploy/$d" --timeout=300s >/dev/null; done
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s >/dev/null

step "aplicação"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null
if kubectl -n argocd get application task-api-app >/dev/null 2>&1; then
  echo "gerenciada pelo Argo CD (task-api-app); manifestos não reaplicados"
else
  # Num cluster novo, a chave do controller é outra: o SealedSecret versionado não decifra. Gera-se uma senha local.
  if ! kubectl -n "$NS" get secret task-api-secret >/dev/null 2>&1; then
    kubectl -n "$NS" create secret generic task-api-secret \
      --from-literal=REDIS_PASSWORD="$(head -c 24 /dev/urandom | base64)" >/dev/null
    echo "senha do Redis gerada localmente (Secret task-api-secret)"
  fi
  kubectl apply -f "$MANIFESTS_DIR/2-config.yaml" -f "$MANIFESTS_DIR/1-redis.yaml" -f "$MANIFESTS_DIR/3-api.yaml" >/dev/null
  kubectl -n "$NS" set image deploy/task-api task-api="$IMG_A" >/dev/null
  kubectl -n "$NS" patch deploy/task-api --type=json \
    -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >/dev/null
  if [ "${GITOPS:-0}" = 1 ]; then
    kubectl apply -f "$MANIFESTS_DIR/argocd-app.yaml" -f "$MANIFESTS_DIR/argocd-sealed-secrets.yaml" >/dev/null
    echo "Application do Argo CD registrado (repositório em argocd-app.yaml)"
  fi
fi
kubectl -n "$NS" rollout status deploy/redis --timeout=300s >/dev/null
kubectl -n "$NS" rollout status deploy/task-api --timeout=300s >/dev/null
kubectl -n "$NS" get pods -o wide
step "pronto. Experimentos: ./experiments/run.sh (ver experiments/README.md)"

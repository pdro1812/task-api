# Task API: resiliência em Kubernetes com GitOps

API de tarefas em Node.js (Express 5) com Redis, usada no artigo sobre resiliência de microsserviços em Kubernetes com
GitOps. O tratamento de falhas do Redis é configurável (`baseline`, `failfast`, `breaker`), e o repositório inclui os
scripts, os dados e a análise dos experimentos.

## Os dois repositórios

O projeto segue o modelo GitOps e por isso está dividido em dois repositórios. **Para reproduzir os experimentos são
necessários os dois**, clonados lado a lado:

| Repositório | Conteúdo |
|---|---|
| `task-api` (este) | código da API, testes, `Dockerfile`, CI (GitHub Actions), scripts dos experimentos (`experiments/`) e dados brutos (`experiments/dados/`) |
| `task-api-manifests` | manifestos Kubernetes da aplicação e do Redis, `SealedSecret`, controller do Sealed Secrets e os `Application` do Argo CD |

```
pasta-de-trabalho/
├── task-api/
└── task-api-manifests/
```

O fluxo em produção é: um push na `main` deste repositório dispara a CI, que testa, publica a imagem no Docker Hub e
grava a nova tag em `task-api-manifests`; o Argo CD, dentro do cluster, sincroniza a partir desse repositório. A CI não
precisa de credenciais do cluster. Para reproduzir os experimentos não é preciso a CI nem as credenciais dela.

## Rodar só a API (Docker)

```bash
docker network create task-api-net
docker run -d --name redis --network task-api-net redis:7-alpine --requirepass segredo
docker build -t task-api:local .
docker run -d --name task-api --network task-api-net -p 3000:3000 \
  -e REDIS_HOST=redis -e REDIS_PASSWORD=segredo -e RESILIENCE_MODE=failfast task-api:local
curl -X POST localhost:3000/tasks -H 'Content-Type: application/json' -d '{"description":"teste"}'
curl localhost:3000/tasks
```

Endpoints: `GET/POST /tasks`, `/health` (liveness), `/ready` (readiness), `/version` e `/metrics` (Prometheus).
Testes: `npm ci && npm test` (os testes que usam o Redis leem `REDIS_TEST_HOST` e `REDIS_TEST_PORT`).

| Variável | Padrão | Efeito |
|---|---|---|
| `RESILIENCE_MODE` | `failfast` | `baseline` (fila offline do cliente Redis), `failfast` (503 imediato) ou `breaker` (failfast + circuit breaker) |
| `READINESS_DEPENDS_ON_REDIS` | `false` | se `true`, `/ready` falha quando o Redis está indisponível |
| `REDIS_COMMAND_TIMEOUT_MS` | `500` | timeout por comando no modo `breaker` |
| `BREAKER_FAILURE_THRESHOLD` / `BREAKER_COOLDOWN_MS` | `5` / `5000` | falhas para abrir o circuito e espera até testar de novo |
| `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`, `APP_PORT` | `localhost`, `6379`, —, `3000` | conexão e porta |

## Reproduzir os experimentos sem GitOps (C1, C2, C4 e C5 imperativo)

Pré-requisitos: Docker, kind v0.30.0, kubectl, k6 v2.3.0, git e Python 3.12+ (versões em
`experiments/versions.env`).

```bash
cd task-api
MANIFESTS_DIR=../task-api-manifests ./experiments/setup.sh   # cluster kind, imagens, Sealed Secrets, Argo CD e app
./experiments/run.sh c1 failfast:false:keepalive              # uma configuração do C1 (RUNS=1 para uma rodada só)
./experiments/run.sh noite1                                   # C1 completo + C4 (~7 h)
```

Sem um `Application` registrado, o `setup.sh` aplica os manifestos de `task-api-manifests` diretamente com
`kubectl apply`, e o Argo CD fica instalado, mas sem nada para sincronizar. Num cluster novo, o `SealedSecret`
versionado não decifra, porque foi selado com a chave do cluster original; o `setup.sh` cria então uma senha local
para o Redis. As rodadas avulsas (`c1`, `c4`, `c5`) restauram o cluster com `kubectl`. Já `noite1` e `noite2`
terminam reaplicando o `argocd-app.yaml` da `main` de `task-api-manifests`, e a partir daí o Argo CD passa a sincronizar
o cluster com esse repositório, apenas lendo dele. Os comandos estão detalhados em
[`experiments/README.md`](experiments/README.md).

## Reproduzir o fluxo GitOps (C3 e C5 GitOps)

Os cenários GitOps fazem commits, reverts e pushes no repositório de manifestos, e o Argo CD busca as mudanças numa
URL Git. Como o revisor não pode fazer push no repositório original, é preciso usar um fork:

1. Faça um fork de `task-api-manifests` e clone o fork ao lado deste repositório.
2. No fork, troque `repoURL` em `argocd-app.yaml` e `argocd-sealed-secrets.yaml` pela URL do fork e faça push.
3. Rode `GITOPS=1 MANIFESTS_DIR=../task-api-manifests ./experiments/setup.sh`, que registra os `Application` no Argo CD.
4. Crie no fork o branch `experimento-v2` com a configuração do experimento (imagens locais, Service NodePort 30080 e
   `targetRevision: experimento-v2` em `argocd-app.yaml`) e rode `./experiments/run.sh noite2`.

## Dados e análise

Os dados brutos das baterias usadas no artigo estão em `experiments/dados/bateria-v2.tar.zst`. A extração e a análise
estão descritas em [`experiments/dados/README.md`](experiments/dados/README.md).

# Experimentos do artigo

Scripts para reproduzir os cenários avaliados. Todos geram arquivos em `experiments/results/` (ignorado pelo git).

## Ambiente

```bash
kind create cluster --name tcc --config experiments/kind-cluster.yaml
# instalar ArgoCD e aplicar argocd-app.yaml do repositório de manifestos
kubectl -n task-api port-forward svc/task-api-service 8080:80
```

Anote no artigo: CPU/RAM da máquina host, versões do kind, Kubernetes, ArgoCD, k6, Node.js e Redis.

## Cenários

| # | Cenário | Script | Variável independente | Métricas |
|---|---------|--------|-----------------------|----------|
| C1 | Redis indisponível | `run-redis-outage.sh` (ou `run-c1-randomizado.sh`) | `RESILIENCE_MODE` = baseline, failfast, breaker; `READINESS_DEPENDS_ON_REDIS`; cliente com keep-alive × conexão nova (`NO_REUSE=1`) | % 503, % sem resposta, latência durante a falha, tempo até voltar a 200 |
| C2 | Rolling update sob carga | `run-rolling-update.sh` | com/sem `preStop` (com/sem `tini` ainda não avaliado) | % sucesso, % sem resposta, p95/p99 |
| C3 | Rollback | `measure-rollback.sh` (`POLLER=1`) | imperativo × GitOps (polling, refresh manual, webhook) | tempo até a 1ª resposta e até 100 % das respostas na versão anterior |
| C4 | Redis pendurado (lento) | `run-redis-outage.sh` com `FAULT=pause` | `RESILIENCE_MODE` | % 503, % sem resposta, p99 durante a falha |
| C5 | Rollback de versão quebrada | `run-broken-rollback.sh` (imagem de `imagem-quebrada/`) | — | erros vistos pelo cliente, tempo do `rollout undo` até estabilizar |

Rode pelo menos 10 rodadas por configuração e reporte média e desvio-padrão:

```bash
python3 experiments/analyze.py experiments/results/*.csv
```

Para a refação do C1 em ordem aleatória, com monitores (EndpointSlices, CPU) e VUs suficientes:

```bash
CONFIGS="failfast:true:noreuse breaker:true:noreuse" RUNS=10 OUT=experiments/results/v2 \
  BASE_URL=http://<IP do nó>:30080 ./experiments/run-c1-randomizado.sh
```

## Opções adicionais

- `carga-constante.js`: `PRE_VUS`/`MAX_VUS` (VUs pré-alocados/máximos; use `PRE_VUS=300` quando houver timeouts, para o k6 não descartar iterações) e `NO_REUSE=1` (uma conexão TCP nova por requisição, para observar o efeito da readiness sobre clientes novos).
- `run-redis-outage.sh`: `START=<n>` retoma a partir da rodada n.
- `measure-rollback.sh` (GitOps): `BRANCH` (branch acompanhado pelo ArgoCD), `REFRESH=1` (refresh manual via anotação), `WEBHOOK=1` + `WEBHOOK_URL` (envia o payload de push do GitHub ao `argocd-server`) e `LABEL` (nome da variante no CSV).
- Gere o tráfego pelo Service (NodePort ou Ingress), não por `kubectl port-forward`: o port-forward fixa um pod e ignora readiness/endpoints.

## Análise

```bash
cd experiments/results
python3 ../final_analysis.py . final      # tabela, Mann-Whitney U e gráficos (300 dpi); requer matplotlib e scipy
python3 ../c1_tempos.py > final/c1_tempos.csv
python3 ../plot_rps.py rodada.png redis-failfast-rdfalse-1.csv   # linha do tempo de uma rodada
```

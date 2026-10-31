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
| 1 | Rolling update sob carga | `run-rolling-update.sh` | com/sem `preStop`, com/sem `tini` | % sucesso, % sem resposta, p95/p99 |
| 2 | Redis indisponível | `run-redis-outage.sh` | `RESILIENCE_MODE` = baseline, failfast, breaker; `READINESS_DEPENDS_ON_REDIS` | % 503, % sem resposta, latência durante a falha, tempo até voltar a 200 |
| 3 | Rollback | `measure-rollback.sh` | imperativo × GitOps (polling, refresh manual, webhook) | tempo até a versão anterior responder |

Rode pelo menos 10 rodadas por configuração e reporte média e desvio-padrão:

```bash
python3 experiments/analyze.py experiments/results/*.csv
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

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

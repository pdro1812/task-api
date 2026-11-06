# Experimentos do artigo

Scripts para reproduzir os cenários avaliados. Todos geram arquivos em `experiments/results/` (ignorado pelo git).

## Reprodução

Pré-requisitos: Docker (usuário com acesso ao daemon), kind v0.30.0, kubectl ≥ 1.34, k6 v2.3.0, git, Python 3.12+ e
um clone do repositório de manifestos ao lado deste (`../task-api-manifests`). As versões e os digests usados nas
baterias v2 estão em `experiments/versions.env`; o ambiente exato de cada bateria está em
`experiments/results/v2/ambiente-*.txt`.

```bash
./experiments/setup.sh                       # cluster kind, imagens, Sealed Secrets, Argo CD e aplicação (idempotente)
pip install -r experiments/requirements.txt  # análise
```

Um ponto de entrada por bateria (`RUNS` rodadas por configuração, padrão 10; resultados em `OUT`):

| Comando | Cenários | Duração (RUNS=10) |
|---|---|---|
| `./experiments/run.sh noite1` | C1 (10 configurações, ordem sorteada) + C4 (3 modos) | ~7 h |
| `./experiments/run.sh noite2` | C2 (com/sem preStop) + C3 (imperativo e GitOps) + C5 (imperativo e GitOps) | ~3 h |
| `./experiments/run.sh c1 failfast:false:keepalive` | uma configuração do C1 | ~35 min |
| `./experiments/run.sh c4 breaker` | um modo do C4 | ~35 min |
| `./experiments/run.sh c5` | C5 com rollback imperativo | ~35 min |

Os cenários GitOps (noite2) fazem commits e pushes no repositório de manifestos: use um fork, aponte
`argocd-app.yaml` para ele (`GITOPS=1 ./experiments/setup.sh`) e crie o branch `experimento-v2` com a configuração
do experimento (imagens locais, NodePort 30080 e o Application acompanhando o branch). Num cluster novo, a chave do
Sealed Secrets é outra: o `SealedSecret` versionado não decifra, e o `setup.sh` gera uma senha local para o Redis.

Análise (os dados da bateria v2 usados no artigo estão em `experiments/dados/`, ver o README de lá):

```bash
zstd -dc experiments/dados/bateria-v2.tar.zst | tar -xf - -C /tmp
python3 experiments/analysis_v2.py /tmp/bateria-v2 /tmp/analise
```

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

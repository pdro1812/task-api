# RUNBOOK: experimento de service mesh (CCGrid 2027)

Ponto de entrada único: o que está feito, o que falta, os comandos exatos de cada passo e o que mandar de volta para
o Claude. Detalhes de desenho estão no [README.md](README.md); prazos e anonimização, no [SUBMISSAO.md](SUBMISSAO.md).

Convenções:
- Campos `ANOTAR:` são para você preencher durante a execução.
- Comandos rodam em `~/k8s/task-api/experiments/mesh`, salvo indicação.
- `.state` é um link para `/mnt/dados/mesh-state`: discos das VMs, chaves, kubeconfig e logs.
- Scripts com `# STATUS: rascunho, não testado` no topo ainda não rodaram de verdade; o primeiro uso é também o teste.

---

## (a) Status

| | Item | Data |
| --- | --- | --- |
| ✅ | Pacotes do host (libvirt, virt-install, cloud-image-utils) e usuário nos grupos libvirt/kvm | 13/11 |
| ✅ | `.state` em `/mnt/dados` (o `/` tem pouco espaço) | 13/11 |
| ✅ | 4 VMs KVM (`01-vms.sh`): cp 2 vCPU/6 GB, w1–w3 4 vCPU/14 GB; vCPUs fixadas 1:1 nos núcleos P 2–15, QEMU no par 0,1 | 13/11 |
| ✅ | Cluster base (`02-cluster.sh`): k3s v1.37.2, Cilium 1.20.3 (CNI), Prometheus (scrape 5 s) | 13/11 |
| ✅ | Planos de controle e componentes do k3s no nó cp (istiod, Linkerd, cilium-operator, coredns, metrics-server, local-path, Prometheus) | 13/11 |
| ✅ | 25 imagens pré-carregadas nos 4 nós; snapshot `base` regravado com elas; nenhuma rodada baixa imagens | 13/11 19:36 |
| ✅ | 6 configurações validadas (fumaça 200 em echo, Online Boutique e Hotel; plano de dados conferido) | 13/11 |
| ✅ | Waypoints da IA7 fixados (echo→w1, ob→w2, hotel→w3) | 13/11 |
| ✅ | Atualizações automáticas (unattended-upgrades) desligadas nas VMs; kernel das VMs 6.8.0-149 | 13/11 |
| ✅ | Limites de demo (`resources.limits`) e `livenessProbe` removidos das aplicações | 14/11 |
| ✅ | Versões registradas em `.state/versoes-instaladas.txt` (k3s, Cilium, Istio 1.32.0, Linkerd edge-26.11.1, Prometheus chart 29.47.2) | 14/11 |
| ✅ | Piloto de saturação na B (2ª tentativa): echo 14190, ob 1103, hotel 1853 req/s | 14/11 |
| ✅ | Checado: o k6 não é o gargalo no echo (núcleos E a ~53%); o joelho é do cluster (relay do fortio) | 14/11 |
| ✅ | Scripts de análise testados com dados sintéticos (`analysis/gera_sintetico.py`) | 14/11 |
| ✅ | SLOs mantidos (20/500/100 ms); `SAT_echo_B=11352` | 14/11 |
| ⏳ | MeshInsight: a 992 req/s o IS colapsa (vazão máx. do IS no OB ≈ 760, −31%); refazendo a 551 req/s | 14/11 |
| ⬜ | Saturação nas 6 configurações (`CONFIGS=... ./04-saturacao.sh`) | |
| ⬜ | Bateria principal (`05-bateria.sh`), 540 rodadas | |
| ⬜ | Perfil RQ2 (`06-perfil.sh`) | |
| ⬜ | Análise, figuras e modelo (`analysis/`) | |
| ⬜ | Artigo (`paper/`), resumo no EasyChair (24/11) e submissão (01/12) | |

Validação das configurações (13/11):

| Config | O que é | Conferido |
| --- | --- | --- |
| B | sem mesh | — |
| IS | Istio sidecar, mTLS STRICT | `istio-proxy` em todos os pods (2/2, 11/11, 19/19) |
| IA4 | Istio ambient, só ztunnel (L4) | ztunnel e istio-cni nos 4 nós; 32 pods em HBONE |
| IA7 | Istio ambient + waypoint por namespace (L7) | tráfego L7 nos waypoints (`istio_requests_total`) |
| LK | Linkerd, `all-authenticated` | `linkerd-proxy` em todos os pods; conexões com `tls="true"` |
| CI | Cilium com WireGuard + política L7 no Envoy do nó | WireGuard com 3 peers; `l7-all` válida; Envoy recebendo tráfego |

---

## (b) Antes de cada sessão de medição

```bash
docker ps                 # tem que vir vazio
uptime                    # se a máquina reiniciou desde a última sessão, rode o 00-host.sh
./00-host.sh              # pede sudo: governor performance, sem turbo, sem C-states profundos, RAPL legível
df -h / /mnt/dados        # espaço para resultados e para os discos das VMs
cat .state/config-atual   # configuração em que o cluster está
```

Para parar o que concorre com a medição, e religar depois:

| | Parar | Religar |
| --- | --- | --- |
| Stack talhao | `docker compose -p talhao stop` | `docker compose -p talhao start` |
| kind `tcc` | `docker stop tcc-control-plane tcc-worker tcc-worker2` | `docker start tcc-control-plane tcc-worker tcc-worker2` |

- Não use `kind delete cluster`: esse apaga o cluster.
- Feche navegador, IDE e o que mais puder. O k6 usa os núcleos E (16–19), e o host e o QEMU usam o par 0,1.
- Depois de um reboot as VMs ficam desligadas. O `03-config.sh` e o `05-bateria.sh` restauram o snapshot e as ligam
  sozinhos.

---

## (c) Passos que faltam, em ordem

### 1. Piloto de saturação (B)

```bash
./03-config.sh B && ./04-saturacao.sh
```

- **Duração:** ~10 min para a B mais ~40 min para o piloto.
- **O que faz:** para cada app, sobe a taxa 25% a cada passo de 60 s até violar o SLO (p99 acima do SLO, erros
  > 1% ou descartes > 1%).
- **Sucesso:** `.state/saturacao.env` com três valores > 0.
- **Arquivos:** `.state/saturacao.env` e `.state/saturacao-<data>.tsv`.
- **Mandar ao Claude:** o `saturacao.env` e o `.tsv`.

| Tentativa | echo | ob | hotel | Observação |
| --- | --- | --- | --- | --- |
| 1ª (14/11) | 11352 | 0 | 950 | OB falhava a 50 req/s por causa dos limites de demo; descartada |
| 2ª (14/11) | 14190 | 1103 | 1853 | sem limites de demo; `.state/saturacao-20261114-0947.tsv` |

Checado em 14/11: **o k6 não é o gargalo**. A 14190 req/s os núcleos E ficam em ~53% de ocupação, e o relay do
fortio usa ~1,9 núcleo. O problema é que 14190 está bem no fio: o passo passou no piloto (p99 de 19,9 ms), mas em
duas repetições deu 26 ms e depois colapsou (p99 de 1,6 s, VUs no máximo). Com 90% = 12771 req/s a bateria do echo
fica perto do joelho.

**Decisão (14/11): `SAT_echo=11352`**, o passo estável anterior. Gravado em `.state/saturacao.env`; o original
ficou em `.state/saturacao.env.piloto2`. Valores finais: **echo 11352, ob 1103, hotel 1853 req/s**.

Para conferir:
- `dropped_iterations` alto no passo em que o echo quebrou;
- VUs perto de `MAX_VUS=2000`;
- CPU dos núcleos E 16–19 perto de 100% (`mpstat -P 16-19 1` durante um passo).

Se o k6 foi o gargalo, a saturação do echo é do cliente, e não do cluster. Nesse caso, dar mais núcleos ao k6 ou
limitar a taxa do echo.

### 2. Ajuste dos SLOs

- **SLOs atuais:** echo p99 ≤ 20 ms, ob ≤ 500 ms, hotel ≤ 100 ms (`SLO_ECHO_MS`, `SLO_OB_MS`, `SLO_HOTEL_MS`).
- **Critério:** o SLO deve ficar perto do joelho da curva p99 × taxa da B. Exemplo: o ob tem p99 de ~17 ms a 566 req/s,
  então 500 ms é frouxo demais.
- **Se mudar o SLO:** rodar de novo o piloto com `SLO_OB_MS=<novo> ./04-saturacao.sh` (~40 min).
- **SLOs finais (14/11): echo p99 ≤ 20 ms, ob ≤ 500 ms, hotel ≤ 100 ms**, mantidos. Mudá-los não muda as taxas da
  bateria, que vêm da saturação já medida.
- **Mandar ao Claude:** a decisão e o novo `saturacao.env`.

### 3. Reprodução do MeshInsight

```bash
./07-meshinsight.sh /mnt/dados/resultados/meshinsight   # B e IS, 5 rodadas cada no OB a 90% da saturação da B
```

- **Duração:** ~1 h.
- **Sucesso:** `$RESULTS_ROOT/meshinsight/resumo.tsv` com o acréscimo percentual de p50, p99 e CPU do IS sobre a B.
- **Referência:** o MeshInsight (Istio 1.13, OB e Hotel) relata acréscimo de **27–269% na latência e 42–163% na CPU**,
  conforme a configuração, em taxas perto do máximo. Critério: o nosso IS contra a B deve cair nessas faixas. Fora
  delas, reportar e explicar (Istio 1.32, outro hardware, VMs).
- ANOTAR: resultado `________`
- **Mandar ao Claude:** o `resumo.tsv` e o valor publicado.

### 3b. Saturação em cada configuração

Mudança de desenho (14/11): a vazão máxima dentro do SLO passa a ser medida em todas as configurações, e é métrica
do RQ1 por si só. A bateria usa 30/60/90% da **menor** saturação de cada app entre as 6 configurações.

```bash
CONFIGS="IS IA4 IA7 LK CI" ./04-saturacao.sh      # a B já está medida; cada config parte de 30% da saturação da B
```

- **Duração:** ~30–40 min por configuração (preparação mais ~7 passos por app), cerca de **3 h** no total.
- **O que grava:** `SAT_<app>_<cfg>` em `.state/saturacao.env` e o log `.state/saturacao-<cfg>-<data>.tsv`. A última
  taxa aprovada é confirmada com mais um passo; se falhar, recua um passo.
- **Sucesso:** 18 valores `SAT_*_*` (6 configurações × 3 apps), todos > 0.
- **Mandar ao Claude:** o `grep ^SAT_ .state/saturacao.env`.

| App | B | IS | IA4 | IA7 | LK | CI | **mín. (base da bateria)** |
| --- | --- | --- | --- | --- | --- | --- | --- |
| echo | 11352 | ANOTAR | | | | | |
| ob | 1103 | (~760) | | | | | |
| hotel | 1853 | | | | | | |

### 4. Bateria principal

Escolha do destino: a bateria grava ~0,9 MB × (soma das bases das 3 apps), e cada base é a menor saturação entre
as configurações. A projeção cai em relação aos 12,4 GB calculados só com a B; o `05-bateria.sh` mostra o valor ao
começar (ANOTAR: `________`). Ele recusa começar se a projeção passar de 80% do
espaço livre do destino. Testado em 14/11: **recusa tanto `/mnt/dados` quanto `/`**, então é preciso um HD externo
ou liberar espaço.

| Destino | Livre (14/11) |
| --- | --- |
| `experiments/results/mesh` (padrão, no `/`) | 12 GB: não cabe |
| `/mnt/dados/resultados` | 17,8 GB: não passa na checagem de 80% |
| HD NTFS (PROGRAMAS/ARTES, 1,8 TB) | precisa montar (por exemplo pelo gerenciador de arquivos) |

ANOTAR: destino escolhido `RESULTS_ROOT=________`

```bash
./05-bateria.sh <destino>/bateria-1      # mesmo comando para retomar
```

- **Duração:** 540 rodadas × ~4,5 min mais ~15 min por configuração, ≈ **41 h**. Dá para fazer em várias sessões:
  rodar de novo com o mesmo diretório retoma de onde parou.
- **Acompanhar:** `find <destino>/bateria-1 -name meta.json | wc -l` (de 540) e a saída na tela, uma linha por rodada.
- **Sucesso:** 540 `meta.json`; `grep -l erro <destino>/bateria-1/*/*/k6.log` vazio ou explicado.
- **Mandar ao Claude:** o caminho do diretório e o número de rodadas feitas por sessão (tabela abaixo).

| Sessão | Início | Fim | Rodadas | Observações |
| --- | --- | --- | --- | --- |
| 1 | ANOTAR | | | |
| 2 | | | | |
| 3 | | | | |

### 5. Perfil (RQ2)

```bash
./06-perfil.sh <destino>/perfil          # rascunho; 6 configs × echo e ob, a 60% da saturação
```

- **Duração:** ~10 min de preparação por configuração mais 2 × ~2 min de coleta, ≈ 1,5 h.
- **Sucesso:** `<destino>/perfil/<cfg>/<app>/` com `w1.folded`, `w2.folded`, `w3.folded`, os `*-bpftrace.txt` e,
  na CI, os `*-bpf-*.json`.
- ANOTAR: o perf resolveu símbolos do Envoy, do ztunnel e do linkerd-proxy, ou vieram `[unknown]`? `________`
- **Mandar ao Claude:** um `.folded` e um `bpftrace.txt` de exemplo (IS e CI), para ajustar as categorias.

### 6. Análise

```bash
cd analysis
~/.local/bin/uv venv .venv && ~/.local/bin/uv pip install --python .venv/bin/python -r requirements.txt  # já feito em 14/11
.venv/bin/python 10_agregar.py <destino>/bateria-1 --cdf                  # cells.csv e cdf/
.venv/bin/python 20_estatistica.py <destino>/bateria-1/cells.csv          # estatistica.csv e ../paper/tables/*.tex
```

- **Duração:** ~10 a 20 min.
- **Mandar ao Claude:** o `cells.csv` e o `estatistica.csv`.

### 7. Figuras

```bash
.venv/bin/python 30_figuras.py <destino>/bateria-1 --perfil <destino>/perfil   # ../paper/figs/*.pdf
```

- **Conferir:** abrir os PDFs e ver se dá para ler em preto e branco, na largura de uma coluna.

### 8. Modelo (RQ3)

```bash
.venv/bin/python 40_modelo.py <destino>/bateria-1/cells.csv                    # ../paper/tables/modelo.tex
```

- ANOTAR: chamadas RPC por requisição externa de cada app (`SALTOS_PADRAO["R"]` no script), medidas na IS:
  echo `__`, ob `__`, hotel `__`.
- **Sucesso:** erro de previsão do Hotel pequeno (ANOTAR: média `__%`, p99 `__%`).

### 9. Artigo

```bash
sudo apt install -y texlive-publishers     # uma vez: o IEEEtran.cls não está instalado (latexmk e todonotes sim)
cd ../paper && make                        # main.pdf; \todo marcam o que falta
```

- Escrever as seções na ordem do `main.tex`. Os comentários `%` de cada seção dizem o que vai nela.
- Conferir o `refs.bib`: as entradas com `note = {ANOTAR...}` não foram confirmadas.

### 10. Resumo no EasyChair: **24/11 (AoE)**

Ver [SUBMISSAO.md](SUBMISSAO.md). O resumo do `main.tex` precisa estar com os números finais, sem `[X]`, `[Y]`, `[Z]`
e `[E]`.

### 11. Submissão: **01/12 (AoE)**

Checklist final no [SUBMISSAO.md](SUBMISSAO.md).

---

## (d) Calendário

| Data | Dia | Plano |
| --- | --- | --- |
| 14/11 | sáb | Piloto na B; k6 checado; SLOs; MeshInsight; saturação nas outras 5 configurações (~3 h) |
| 15/11 | dom | Testar `06-perfil.sh` numa configuração; montar o HD dos resultados |
| 16/11 | seg | Escrever Background, Related Work e Methodology; conferir o `refs.bib` |
| 17/11 | ter | Folga para correções; começar a bateria à noite, se estiver tudo pronto |
| 18/11 | qua | **Bateria** |
| 19/11 | qui | **Bateria** |
| 20/11 | sex | **Bateria** |
| 21/11 | sáb | **Bateria** (termina; refazer rodadas falhas) |
| 22/11 | dom | Perfil RQ2 (~1,5 h); agregação e estatística |
| 23/11 | seg | Figuras e modelo; números do resumo |
| 24/11 | ter | **Registrar o resumo no EasyChair** (prazo real: fim do dia, horário de Brasília) |
| 25–28/11 | | Escrever Results, Attribution, Model, Decision guide e Threats |
| 29–30/11 | | Revisão, limite de páginas, anonimização, artefato anônimo |
| 01/12 | ter | **Submissão** (prazo real: fim do dia, horário de Brasília) |

---

## (e) Problemas conhecidos e soluções

| Sintoma | Causa | Solução (já nos scripts, salvo indicação) |
| --- | --- | --- |
| `./00-host.sh: No such file or directory` | rodado fora da pasta | `cd ~/k8s/task-api/experiments/mesh` |
| `sem acesso ao libvirt` | grupo libvirt só vale em sessão nova | logout/login (ou `newgrp libvirt` no terminal) |
| Nós NotReady, "cni plugin not initialized" | o cilium-cli detecta o k3s e usa os caminhos dele | `cni.binPath=/opt/cni/bin`, `cni.confPath=/etc/cni/net.d` explícitos (`02-cluster.sh`); Istio CNI idem (`lib/mesh.sh`) |
| Prometheus em CrashLoop | `scrape_timeout` padrão (10 s) maior que o intervalo (5 s) | `scrape_timeout: 4s` |
| Pull de imagem falha com "lookup ...: Try again" | DNS a montante do host intermitente; logo após o revert, o relógio da VM salta | `restore_base` espera o DNS; imagens no snapshot; preload um nó por vez com 10 tentativas |
| Hotel: `./frontend` não existe | a imagem instala os binários em /go/bin | comando sem `./`; imagem fixada em 0.3.5 |
| Hotel 500 no Istio (sidecar ou waypoint) | serviços se chamavam pelo IP do pod (Consul) | registro no Consul pelo nome DNS do Service (`<Serviço>IP` no `config.json`) |
| Hotel 500 aleatório ("produced zero addresses") | pod do Consul recriado perde o catálogo (só em memória) | manifestos ajustados antes do `apply`, sem patch depois |
| relay do echo em CrashLoop | o fortio abre gRPC na 8079 | HTTP de administração na 8088 |
| LK: Online Boutique em CrashLoop (PermissionDenied) | probes gRPC do kubelet sem mTLS, recusados pelo `all-authenticated` | `linkerd_grpc_probes`: só `/grpc.health.v1.Health/` liberado |
| IA7: waypoint sem tráfego | waypoint criado depois que as conexões gRPC já existiam | waypoint criado antes das aplicações |
| Kernel da VM mudou sozinho | unattended-upgrades | desligado no cloud-init e no `02-cluster.sh` |
| OB falha a 50 req/s no piloto | limites de demo (200m de CPU) e liveness matando o pod | sem `limits` e sem `livenessProbe` nas aplicações |
| `versoes-instaladas.txt` zerado | o `00-host.sh` sobrescrevia | agora acrescenta |
| Disco cheio | qcow2 das VMs (~38 GB) e resultados | `df -h`; destino da bateria fora do `/`; o `05-bateria.sh` checa antes |

Onde olhar quando algo der errado:
- Logs: `.state/*.log` e `<bateria>/<config>-config.log`.
- Cluster: `export KUBECONFIG=$PWD/.state/kubeconfig`, depois `kubectl get pods -A`.
- Prometheus: <http://192.168.150.10:30090>.
- Refazer uma configuração do zero: `./03-config.sh <CFG>` (sempre restaura o snapshot base).

ANOTAR problemas novos:

-

---

## (f) Decisões de desenho (registro)

| Decisão | Motivo | Data |
| --- | --- | --- |
| 6 configurações: B, IS, IA4, IA7, LK, CI | cobrem as três famílias (sidecar, ambient L4/L7, eBPF + proxy por nó) e a referência sem mesh | 13/11 |
| Cilium como CNI em todas | só o mesh varia entre configurações | 13/11 |
| mTLS estrito no leste-oeste, entrada em texto puro | compara o custo do mTLS interno sem misturar com TLS na borda | 13/11 |
| k6 em malha aberta (constant-arrival-rate) nos núcleos E | evita coordinated omission; separa cliente e cluster | 13/11 |
| vCPUs fixadas 1:1 nos núcleos P; governor performance, sem turbo nem C-states profundos | reduz variância entre rodadas | 13/11 |
| Planos de controle no nó cp | não disputam CPU com as aplicações nem mudam de nó | 13/11 |
| Aplicações fixadas em nós (rodízio alfabético); waypoints echo→w1, ob→w2, hotel→w3 | mesma posição, e portanto mesmo tráfego entre nós, em todas as configurações | 13/11 |
| Imagens pré-carregadas no snapshot, `imagePullPolicy: IfNotPresent` | sem dependência de rede nem do limite do Docker Hub; tags `latest` congeladas | 13/11 |
| Atualizações automáticas desligadas nas VMs | sem apt em segundo plano e sem troca de kernel durante a bateria | 13/11 |
| Hotel registra serviços pelo nome DNS do Service | tráfego endereçado a Service em todos os meshes | 13/11 |
| Sem `resources.limits` e sem `livenessProbe` nas aplicações | os limites de demo mediam estrangulamento e reinícios, não o mesh | 14/11 |
| `SAT_echo=11352`, e não 14190 | 14190 está no joelho e colapsou numa repetição; o gargalo é o relay do fortio (~1,9 núcleo), não o k6 (núcleos E a ~53%) | 14/11 |
| SLOs mantidos (20/500/100 ms) | as taxas vêm do piloto; o SLO só define o joelho | 14/11 |
| Saturação medida em cada configuração (`SAT_<app>_<cfg>`) | a vazão máxima por mesh é métrica do RQ1 (IS no OB: ≈ 760 contra 1103 da B, −31%) | 14/11 |
| Cargas da bateria = 30/60/90% da **menor** saturação entre as 6 configurações | mesma taxa absoluta para todas, e todas sustentam todos os níveis: a cauda mede o custo do mesh, não colapso por fila (a 90% da B o IS no OB colapsava, p50 de 1,8 s) | 14/11 |
| MeshInsight a 90% da menor saturação entre B e IS | a 90% da B o IS não sustenta a carga, e a comparação percentual perde o sentido | 14/11 |
| 30/60/90% da saturação da B, 10 repetições, ordem aleatória com semente | mesma carga absoluta para todos os meshes; variância medida | 13/11 |

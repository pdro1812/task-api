# Dados brutos da bateria v2

`bateria-v2.tar.zst` (32,7 MB; sha256 `f86e5246cac4f19ee5a6282a95a4991fdf554afe9ac7ee477d55498f2ea8fcce`) contém os dados de todas as rodadas usadas no artigo
(10 rodadas por configuração, coletadas em 05–06/11/2026). Ao extrair, eles ficam em `bateria-v2/`:

| Arquivos | Conteúdo |
|---|---|
| `redis-<modo>-rd<true\|false>[-noreuse]-<n>.*` | C1, Redis indisponível |
| `pausa-<modo>-rdfalse-<n>.*` | C4, Redis pendurado |
| `rolling-<prestop\|noprestop>-<n>.*` | C2, rolling update |
| `rollback.csv`, `rollback-<método>-<n>.*` | C3, rollback (comando, rollout e medidor de `/version`) |
| `quebrada-<imperativo\|gitops>-<n>.*` | C5, versão quebrada |
| `ambiente-*.txt` | versões, digests, commits e sha256 dos scripts de cada execução |
| `noite1.log`, `noite2.log`, `c5-gitops.log`, `run.log`, `ordem-*.txt` | logs e ordem sorteada das rodadas |
| `analise/` | tabelas, testes estatísticos e figuras do artigo |

Por rodada, as extensões são:
- `.csv`: saída do k6.
- `.fail`, `.recover`, `.deploy`, `.done`, `.applied`, `.detect`, `.undo`, `.reverted`: instantes dos eventos, em epoch.
- `.metrics`: `/metrics` de cada Pod, a cada 2 s.
- `.pods-stats`: CPU e memória por contêiner.
- `.docker`: `docker stats` dos nós.
- `.cpu`: CPU do host.
- `.endpoints`: EndpointSlices.
- `.redis`: estado do Pod do Redis.
- `.tasks`: tarefas antes e depois da falha.
- `.pods`: estado final dos Pods.
- `.versions`: medidor de `/version`.

O formato de cada arquivo está descrito em `experiments/monitor.sh` e nos scripts `run-*.sh`.

Os arquivos de texto foram anonimizados antes da compactação: nome de usuário e caminhos pessoais aparecem como
`ANON-USER` e `/home/user`. As rodadas interrompidas e refeitas não estão incluídas.

```bash
zstd -dc experiments/dados/bateria-v2.tar.zst | tar -xf - -C /tmp
pip install -r experiments/requirements.txt
python3 experiments/analysis_v2.py /tmp/bateria-v2 /tmp/analise   # reproduz bateria-v2/analise/
```

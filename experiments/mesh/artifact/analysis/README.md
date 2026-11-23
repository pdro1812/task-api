# Análise da bateria de service mesh

Scripts em ordem de uso. Todos leem os arquivos que o `05-bateria.sh` grava (formato em `../lib/measure.sh`).

| Script | Entrada | Saída | Status |
| --- | --- | --- | --- |
| `10_agregar.py` | diretório da bateria | `cells.csv` (uma linha por rodada) e, com `--cdf`, `cdf/*.csv` | testado com dados sintéticos (formato real dos arquivos) |
| `20_estatistica.py` | `cells.csv` | `estatistica.csv` e `../paper/tables/<métrica>.tex` | rascunho, testado com dados sintéticos |
| `30_figuras.py` | diretório da bateria (+ `--perfil` do `06-perfil.sh`) | `../paper/figs/*.pdf` | rascunho, testado com dados sintéticos |
| `40_modelo.py` | `cells.csv` | `../paper/tables/modelo.tex` | rascunho, testado com dados sintéticos |
| `gera_sintetico.py` | — | bateria falsa em `/tmp` para testar os scripts | auxiliar |

## Preparar o ambiente (uma vez)

```bash
cd analysis   # a partir da raiz do artefato
# o python3 do sistema não tem pip/venv completos; o uv (em ~/.local/bin) resolve. Já feito em 14/11.
~/.local/bin/uv venv .venv
~/.local/bin/uv pip install --python .venv/bin/python -r requirements.txt
```

## Rodar

```bash
B=<diretório da bateria>                         # ANOTAR: o mesmo passado ao 05-bateria.sh
.venv/bin/python 10_agregar.py "$B" --cdf        # alguns minutos: lê os csv.gz de 540 rodadas
.venv/bin/python 20_estatistica.py "$B/cells.csv"
.venv/bin/python 30_figuras.py "$B" --perfil <diretório do 06-perfil.sh>
.venv/bin/python 40_modelo.py "$B/cells.csv"
```

## Pontos a revisar com os dados reais

- ANOTAR: em `40_modelo.py`, `SALTOS_PADRAO["R"]` (chamadas RPC por requisição externa) é estimativa; medir na IS.
- ANOTAR: em `30_figuras.py`, as `CATEGORIAS` de função do perfil são palpites de nomes; revisar olhando os `.folded`.
- O agregado traz p50, não a média; `40_modelo.py` usa p50 no lugar da média (ver `preparar`).

# Submissão: CCGrid 2027

Artigo: *Sidecars, Ambient, or eBPF? Measuring the Tail-Latency and Resource Cost of Kubernetes Service Meshes*
(fonte em [paper/main.tex](paper/main.tex)).

| Item | Valor |
| --- | --- |
| Evento | IEEE/ACM CCGrid 2027 |
| Track | 5: Performance Modeling, Analysis, and Optimization |
| Sistema | EasyChair (ANOTAR: link da submissão: `________________`) |
| Resumo (registro) | **24/11/2026, AoE** = 25/11/2026 às 08:59 em Brasília/Araguaína (UTC−3) |
| Artigo completo | **01/12/2026, AoE** = 02/12/2026 às 08:59 em Brasília/Araguaína |
| Formato | IEEE conference (IEEEtran), até 10 páginas **incluindo referências** (ANOTAR: confirmar no CFP) |
| Revisão | duplo-cega |

AoE (Anywhere on Earth) é UTC−12: o prazo termina quando o dia acaba no último fuso. Para não arriscar, trate como
prazo real **o fim do dia 24/11 (e 01/12) no horário de Brasília**.

## Antes de tudo: conferir o CFP

- ANOTAR: limite de páginas e se referências contam: `________________`
- ANOTAR: regra sobre uso de IA (declaração exigida? onde?): `________________`
- ANOTAR: exigência de artefato/reprodutibilidade (badge, apêndice): `________________`
- ANOTAR: se o resumo registrado em 24/11 pode ser alterado até 01/12: `________________`

## Registro do resumo (até 24/11)

1. Criar/entrar na conta do EasyChair e escolher a Track 5.
2. Título, resumo (texto do `\begin{abstract}` com os números finais, sem `\todo`), palavras-chave (as do
   `IEEEkeywords`).
3. Autores e afiliações são preenchidos no EasyChair (ficam ocultos dos revisores), não no PDF.
4. ANOTAR: número da submissão: `______`

## Anonimização (checklist)

- [ ] `\author` do `main.tex` continua "Anonymous Author(s)".
- [ ] Nenhum link para o repositório real (GitHub `pdro1812`, nome do usuário, nome da instituição). O artefato vai
      por link anônimo (abaixo).
- [ ] Autocitações na terceira pessoa ("Prior work [n] showed...", nunca "our previous work").
- [ ] Não mencionar o CoTB nem outro evento/trabalho anterior pelo nome.
- [ ] Metadados do PDF limpos: `make anon` (usa `exiftool`) e conferir com `exiftool main.pdf` e `pdfinfo main.pdf`.
- [ ] Nada de nomes de máquina, usuário ou caminhos pessoais em figuras, tabelas ou listagens (`/home/pedro`,
      hostname `pedro`).
- [ ] Agradecimentos e financiamento removidos (voltam na versão final).

## Artefato anônimo

1. Copiar `experiments/mesh` (scripts, análise, `versions.env`, `README.md`) para um repositório separado, sem
   histórico e sem o `.state`.
2. Conferir que não há nomes, e-mails ou caminhos pessoais (`grep -ri pedro`).
3. Publicar em <https://anonymous.4open.science> apontando para esse repositório.
4. ANOTAR: link anônimo: `________________`, e colocar no `\anonrepo` do `main.tex`.
5. Opcional: subir o `cells.csv` e os resumos (não os 15 GB de csv.gz) junto.

## Checklist final antes de enviar (até 01/12)

- [ ] Nenhum `\todo` sobrando: trocar para `\usepackage[disable]{todonotes}` e procurar `ANOTAR` no `.tex` e no
      `.bib`.
- [ ] Todas as entradas do `refs.bib` conferidas (campos `note = {ANOTAR...}` resolvidos e apagados).
- [ ] Números do resumo batem com as tabelas e figuras.
- [ ] 10 páginas ou menos, incluindo referências; fonte e margens do IEEEtran sem alteração.
- [ ] Figuras legíveis em preto e branco e com fontes embutidas (`pdffonts main.pdf` sem "Type 3").
- [ ] Anonimização (lista acima).
- [ ] Declaração de uso de IA, se o CFP exigir.
- [ ] PDF final enviado no EasyChair e o download conferido.
- [ ] ANOTAR: data e hora do envio: `________________`

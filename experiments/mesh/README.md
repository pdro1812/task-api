# Experimento: custo de service meshes em Kubernetes

Testbed do artigo sobre overhead de service mesh (Istio sidecar, Istio Ambient, Linkerd e Cilium). Ele não usa a
task-api: as cargas são um servidor echo (fortio), o Online Boutique e o Hotel Reservation (DeathStarBench).

Roda numa máquina Linux com CPU Intel híbrida (testado para i7-12700K, 64 GB, Ubuntu). O cluster são 4 VMs KVM:

| VM | Papel | CPUs do host | Memória |
| --- | --- | --- | --- |
| — | host e threads do QEMU | par 0 dos núcleos P | — |
| cp (192.168.150.10) | controle k3s + Prometheus | par 1 dos núcleos P | 6 GB |
| w1, w2, w3 (.11 a .13) | nós de trabalho | 2 pares de núcleos P cada | 14 GB cada |
| — | gerador de carga (k6) | núcleos E | — |

Tudo o que é gerado (discos das VMs, chaves, kubeconfig, versões) fica em `experiments/mesh/.state/`, fora do Git.

## Preparação (uma vez)

```bash
sudo apt install -y qemu-kvm libvirt-daemon-system virtinst cloud-image-utils jq
sudo usermod -aG libvirt,kvm $USER        # depois feche e abra o terminal
cd task-api/experiments/mesh
./00-host.sh      # governor performance, sem turbo, sem C-states profundos; confere RAPL e ferramentas
./01-vms.sh       # cria as 4 VMs (~10 min, baixa a imagem do Ubuntu 24.04)
./02-cluster.sh   # k3s + Cilium (CNI) + Prometheus e grava o snapshot "base" (~15 min)
```

`00-host.sh` precisa ser rodado de novo após cada reboot. Para desfazer: `./00-host.sh --restore`.

## Uma configuração

```bash
./03-config.sh B     # sem mesh
./03-config.sh IS    # Istio sidecar
./03-config.sh IA4   # Istio ambient (ztunnel)
./03-config.sh IA7   # Istio ambient + waypoint
./03-config.sh LK    # Linkerd
./03-config.sh CI    # Cilium (WireGuard + Envoy L7)
```

Cada uma restaura o snapshot base (nenhum mesh deixa resíduo), instala o mesh, implanta as três aplicações e termina
com um teste de fumaça que deve responder 200 nos três endereços:

- echo: `http://192.168.150.11:30082/echo`
- Online Boutique: `http://192.168.150.11:30080/`
- Hotel Reservation: `http://192.168.150.11:30081/hotels?...`

Para usar o cluster direto: `export KUBECONFIG=$PWD/.state/kubeconfig`. Prometheus: `http://192.168.150.10:30090`.

## Piloto e bateria

```bash
./03-config.sh B && ./04-saturacao.sh     # maior taxa dentro do SLO sem mesh -> .state/saturacao.env
./05-bateria.sh                           # todas as configurações, 30/60/90% da saturação, 10 rodadas
CONFIGS="B IS" ./05-bateria.sh <dir>      # só algumas configurações; o mesmo <dir> retoma de onde parou
```

Os SLOs do piloto (`SLO_ECHO_MS=20`, `SLO_OB_MS=500`, `SLO_HOTEL_MS=100`) e as taxas iniciais são provisórios:
ajuste depois de olhar a primeira saída. Cada rodada é 1 min de aquecimento + 3 min de medição; a bateria completa
leva cerca de 40 h. Resultados em `experiments/results/mesh/bateria-*/<config>/<app>-<carga>-<rodada>/`:
`k6-summary.json`, `k6-reqs.csv.gz` (cada requisição), `prom-*.json` (CPU e memória por contêiner, CPU por nó),
`meta.json` (energia RAPL em joules) e, por configuração, `idle.json` (potência ociosa) e `pods.txt`.

## Decisões de desenho

- O Cilium é a CNI em todas as configurações; só o mesh muda. Na configuração CI, liga-se a criptografia WireGuard e uma
  regra L7 que leva o tráfego HTTP/gRPC ao Envoy do nó.
- O salto de entrada (k6 de fora do cluster até o pod de borda) é texto puro em todos os meshes; o tráfego leste-oeste
  é cifrado (STRICT no Istio, `all-authenticated` no Linkerd).
- Cada deployment é fixado num nó (rodízio), para que a posição dos pods seja a mesma em todas as configurações.
- Versões vazias em `versions.env` instalam a estável do dia; as instaladas ficam em `.state/versoes-instaladas.txt`.

## Pontos a validar no piloto

Estes scripts ainda não rodaram no hardware final. Os pontos mais prováveis de ajuste:

- caminhos de CNI do k3s usados pelo Cilium e pelo Istio CNI (`/var/lib/rancher/k3s/data/cni` e
  `/var/lib/rancher/k3s/agent/etc/cni/net.d`);
- o modo proxy do fortio (`-M`) no relay do echo;
- os manifestos do Hotel Reservation aplicados no namespace `hotel`.

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
./02-cluster.sh   # k3s + Cilium (CNI) + Prometheus, pré-carrega as imagens (02b) e grava o snapshot "base" (~25 min)
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
- Cada deployment das aplicações é fixado num nó de trabalho (rodízio em ordem alfabética), para que a posição dos pods
  seja a mesma em todas as configurações. Os waypoints da IA7 também são fixados: echo no w1, ob no w2, hotel no w3.
- Os planos de controle ficam no nó cp, com a tolerância ao taint dele: istiod, o controle do Linkerd (destination,
  identity, proxy-injector), o operador do Cilium, o Prometheus e os componentes do k3s (coredns, metrics-server,
  local-path-provisioner, com arquivos `.skip` para que o k3s não os reaplique). Assim não disputam CPU com as
  aplicações nem mudam de nó entre rodadas. Os DaemonSets de plano de dados (cilium, cilium-envoy, ztunnel, istio-cni)
  rodam em todos os nós.
- As imagens de todas as configurações estão no snapshot base (`02b-preload-images.sh`, lista e digests em
  `.state/imagens.txt`) e os manifestos usam `imagePullPolicy: IfNotPresent`: nenhuma rodada baixa imagens.
- As aplicações rodam sem `resources.limits` e sem `livenessProbe` (requests e readiness ficam). Com os limites de
  demonstração do Online Boutique (200m de CPU por serviço), o piloto já falhava a 50 req/s: CPU estrangulada,
  liveness matando o recommendationservice e cascata de timeouts. Sem eles, p99 de 10 a 20 ms até 800 req/s.
- Hotel Reservation: os serviços se registram no Consul com o nome DNS do Service (`<Serviço>IP` no `config.json`,
  por ConfigMap), não com o IP do pod. Assim o tráfego gRPC é endereçado ao Service em todos os meshes.
- Linkerd com `all-authenticated`: os probes gRPC do kubelet (Online Boutique) chegam sem mTLS; só a rota
  `/grpc.health.v1.Health/` é liberada para eles, o resto exige identidade do mesh.
- Versões vazias em `versions.env` instalam a estável do dia; as instaladas ficam em `.state/versoes-instaladas.txt`.

## Pontos a validar no piloto

As seis configurações já passaram no teste de fumaça no hardware final. Ponto que já deu problema:

- caminhos de CNI: `/opt/cni/bin` e `/etc/cni/net.d` (com o flannel desligado, o containerd do k3s procura nos caminhos
  padrão, e não em `/var/lib/rancher/k3s/...`; o cilium-cli usaria os do k3s se não forem passados explicitamente).

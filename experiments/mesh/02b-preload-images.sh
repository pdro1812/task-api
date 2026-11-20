#!/usr/bin/env bash
# Baixa em todos os nós as imagens usadas por todas as configurações (meshes e aplicações), para que o snapshot base
# já as contenha: nenhuma configuração depende da rede ou do limite de pulls do Docker Hub, e o tempo de pull não
# varia entre configurações. Os manifestos usam imagePullPolicy IfNotPresent (lib/apps.sh). Chamado pelo 02-cluster.sh
# antes do snapshot; a lista e os digests ficam em .state/imagens.txt.
source "$(dirname "$0")/lib/common.sh"
source "$MESH_DIR/lib/apps.sh"
source "$MESH_DIR/lib/mesh.sh"
export PATH="$STATE/bin:$PATH"

fetch_sources >/dev/null
istioctl=$(istioctl_bin)
linkerd=$(linkerd_bin)
images=$( {
  echo "$FORTIO_IMAGE"
  grep -oE 'image: *[^ ]+' "$SRC/microservices-demo/release/kubernetes-manifests.yaml" | awk '{print $2}' \
    | grep -vE 'loadgenerator|busybox'
  grep -rhoE 'image: *[^ ]+' "$SRC/DeathStarBench/hotelReservation/kubernetes" | awk '{print $2}' \
    | sed -E "s#deathstarbench/hotel-reservation:latest#deathstarbench/hotel-reservation:$HOTEL_IMAGE_TAG#; s#^hashicorp/consul:latest\$#${HOTEL_CONSUL_IMAGE:-hashicorp/consul:latest}#; s#^jaegertracing/all-in-one:latest\$#${HOTEL_JAEGER_IMAGE:-jaegertracing/all-in-one:latest}#; s#^memcached\$#${HOTEL_MEMCACHED_IMAGE:-memcached}#"
  # istiod e componentes do ambient; proxyv2 é injetado (sidecar) ou criado pelo controlador (waypoint)
  for profile in minimal ambient; do
    "$istioctl" manifest generate --set profile=$profile 2>/dev/null | grep -oE 'image: *"?docker\.io/istio/[^" ]+' \
      | sed -E 's/image: *"?//'
  done
  tag=$("$istioctl" version --remote=false 2>/dev/null | awk '{print $NF}')
  echo "docker.io/istio/proxyv2:$tag" "docker.io/istio/proxyv2:$tag-distroless"
  "$linkerd" install --ignore-cluster 2>/dev/null | grep -oE 'cr\.l5d\.io/linkerd/(controller|proxy):[A-Za-z0-9._-]+'
} | tr ' ' '\n' | grep -v '^$' | sort -u )

echo "$(echo "$images" | wc -l) imagens"
# Um nó por vez e até 10 tentativas por imagem: o DNS a montante do host falha de vez em quando ("Try again")
for vm in "${VMS[@]}"; do
  for img in $images; do
    vssh "$vm" "sudo k3s crictl inspecti -q $img >/dev/null 2>&1 && exit 0
      for t in 1 2 3 4 5 6 7 8 9 10; do sudo k3s crictl pull $img >/dev/null 2>&1 && exit 0; sleep 30; done; exit 1" \
      || die "$vm não baixou $img"
  done
  echo "$vm: $(vssh "$vm" 'sudo k3s crictl images -q | wc -l') imagens no nó"
done

{
  echo "# imagens pré-carregadas em todos os nós ($(date -Is))"
  vssh w1 'sudo k3s crictl images --digests' | awk 'NR > 1 {print $1 ":" $2, $3}'
} > "$STATE/imagens.txt"
record imagens_preload "$(echo "$images" | wc -l) imagens (lista e digests em .state/imagens.txt)"

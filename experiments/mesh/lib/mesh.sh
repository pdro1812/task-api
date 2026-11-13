# Instalação de cada configuração de plano de dados sobre o cluster base (k3s + Cilium CNI).
#   B    sem mesh
#   IS   Istio sidecar (Envoy por pod), mTLS STRICT
#   IA4  Istio ambient, só ztunnel (L4 por nó), mTLS STRICT
#   IA7  Istio ambient + waypoint por namespace (L7 compartilhado), mTLS STRICT
#   LK   Linkerd (linkerd2-proxy por pod), mTLS sempre ligado
#   CI   Cilium service mesh: WireGuard entre nós + regra L7 que envia o tráfego HTTP/gRPC ao Envoy do nó
# Em todos, o salto de entrada (k6 de fora do cluster -> pod "edge") é texto puro; o tráfego leste-oeste é cifrado.
APP_NS=(echo ob hotel)
GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-v1.3.0}
K3S_CNI=(--set values.cni.cniConfDir=/var/lib/rancher/k3s/agent/etc/cni/net.d --set values.cni.cniBinDir=/var/lib/rancher/k3s/data/cni)

istioctl_bin() {
  local d
  d=$(ls -d "$STATE"/istio-*/ 2>/dev/null | head -1 || true)
  if [ -z "$d" ]; then
    (cd "$STATE" && curl -fsSL https://istio.io/downloadIstio | ISTIO_VERSION="$ISTIO_VERSION" TARGET_ARCH=x86_64 sh - >/dev/null)
    d=$(ls -d "$STATE"/istio-*/ | head -1)
  fi
  echo "${d}bin/istioctl"
}

linkerd_bin() {
  if [ ! -x "$HOME/.linkerd2/bin/linkerd" ]; then
    curl -fsSL "https://run.linkerd.io/install-$LINKERD_CHANNEL" | sh >/dev/null
  fi
  echo "$HOME/.linkerd2/bin/linkerd"
}

gateway_api_crds() {
  kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 || \
    kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml" >/dev/null
}

create_namespaces() {
  local cfg=$1
  for ns in "${APP_NS[@]}"; do
    kubectl create ns "$ns" >/dev/null 2>&1 || true
    case $cfg in
      IS) kubectl label ns "$ns" istio-injection=enabled --overwrite >/dev/null ;;
      IA4|IA7) kubectl label ns "$ns" istio.io/dataplane-mode=ambient --overwrite >/dev/null ;;
      LK) kubectl annotate ns "$ns" linkerd.io/inject=enabled config.linkerd.io/default-inbound-policy=all-authenticated --overwrite >/dev/null ;;
    esac
  done
}

install_mesh() {
  local cfg=$1 istioctl linkerd
  case $cfg in
    B) ;;
    IS)
      istioctl=$(istioctl_bin)
      "$istioctl" install -y --set profile=minimal >/dev/null
      record istio "$("$istioctl" version --remote=false 2>/dev/null)"
      ;;
    IA4|IA7)
      istioctl=$(istioctl_bin)
      gateway_api_crds
      "$istioctl" install -y --set profile=ambient "${K3S_CNI[@]}" >/dev/null
      record istio "$("$istioctl" version --remote=false 2>/dev/null)"
      ;;
    LK)
      linkerd=$(linkerd_bin)
      gateway_api_crds
      "$linkerd" install --crds | kubectl apply -f - >/dev/null
      "$linkerd" install | kubectl apply -f - >/dev/null
      "$linkerd" check --wait 10m >/dev/null
      record linkerd "$("$linkerd" version --client --short)"
      ;;
    CI)
      cilium upgrade --reuse-values --set encryption.enabled=true --set encryption.type=wireguard --set l7Proxy=true
      kubectl -n kube-system rollout restart ds/cilium >/dev/null
      kubectl -n kube-system rollout status ds/cilium --timeout=10m >/dev/null
      record cilium_encryption "$(kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status 2>/dev/null | head -1)"
      cilium status --wait --wait-duration 10m >/dev/null
      ;;
    *) die "configuração desconhecida: $cfg (use B, IS, IA4, IA7, LK ou CI)" ;;
  esac
}

# Políticas aplicadas depois que as aplicações existem (dependem das portas e do rótulo edge=true)
apply_policies() {
  local cfg=$1 istioctl
  for ns in "${APP_NS[@]}"; do
    case $cfg in
      IS|IA4|IA7)
        kubectl apply -f - >/dev/null <<YAML
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: strict, namespace: $ns}
spec: {mtls: {mode: STRICT}}
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: edge-permissive, namespace: $ns}
spec:
  selector: {matchLabels: {edge: "true"}}
  mtls: {mode: PERMISSIVE}
YAML
        if [ "$cfg" = IA7 ]; then
          istioctl=$(istioctl_bin)
          "$istioctl" waypoint apply -n "$ns" --enroll-namespace --wait >/dev/null
        fi
        ;;
      LK)
        # o pod de entrada aceita a carga sem mTLS, vinda de fora do mesh
        for d in $(kubectl -n "$ns" get deploy -o json | jq -r '.items[] | select(.spec.template.metadata.labels.edge=="true") | .metadata.name'); do
          kubectl -n "$ns" patch deploy "$d" --type=merge \
            -p '{"spec":{"template":{"metadata":{"annotations":{"config.linkerd.io/default-inbound-policy":"all-unauthenticated"}}}}}' >/dev/null
        done
        ;;
      CI)
        local l7 l4
        l7=$(app_ports "$ns" | awk '{printf "%s{port: \"%s\", protocol: TCP}", (NR>1?", ":""), $1}')
        l4=$(for p in $DATASTORE_PORTS; do echo "$p"; done | awk '{printf "%s{port: \"%s\", protocol: TCP}", (NR>1?", ":""), $1}')
        kubectl apply -f - >/dev/null <<YAML
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: l7-all, namespace: $ns}
spec:
  endpointSelector: {}
  ingress:
  - fromEntities: [all]
    toPorts: [{ports: [$l4]}]
  - fromEntities: [all]
    toPorts: [{ports: [$l7], rules: {http: [{}]}}]
YAML
        ;;
    esac
  done
}

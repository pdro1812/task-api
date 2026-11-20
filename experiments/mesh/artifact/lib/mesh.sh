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
K3S_CNI=(--set values.cni.cniConfDir=/etc/cni/net.d --set values.cni.cniBinDir=/opt/cni/bin)
# Planos de controle no nó cp (não disputam CPU com as aplicações nem mudam de nó entre rodadas)
CP_SELECTOR_KEY=node-role.kubernetes.io/control-plane
LINKERD_CP=(--set-string "nodeSelector.node-role\\.kubernetes\\.io/control-plane=true"
  --set "tolerations[0].key=$CP_SELECTOR_KEY" --set "tolerations[0].operator=Exists" --set "tolerations[0].effect=NoSchedule")
# Waypoint de cada namespace (IA7), fixado num nó de trabalho
declare -A WAYPOINT_NODE=([echo]=w1 [ob]=w2 [hotel]=w3)

istio_cp_overlay() {
  cat > "$STATE/istio-cp.yaml" <<YAML
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  components:
    pilot:
      k8s:
        nodeSelector: {$CP_SELECTOR_KEY: "true"}
        tolerations: [{key: $CP_SELECTOR_KEY, operator: Exists, effect: NoSchedule}]
YAML
  echo "$STATE/istio-cp.yaml"
}

# Waypoint com a mesma definição do "istioctl waypoint apply", mais um ConfigMap de parâmetros que fixa o nó
apply_waypoint() {
  local ns=$1
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ConfigMap
metadata: {name: waypoint-params, namespace: $ns}
data:
  deployment: |
    spec:
      template:
        spec:
          nodeSelector: {kubernetes.io/hostname: ${WAYPOINT_NODE[$ns]}}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: $ns
  labels: {istio.io/waypoint-for: service}
spec:
  gatewayClassName: istio-waypoint
  infrastructure:
    parametersRef: {group: "", kind: ConfigMap, name: waypoint-params}
  listeners: [{name: mesh, port: 15008, protocol: HBONE}]
YAML
  kubectl label ns "$ns" istio.io/use-waypoint=waypoint --overwrite >/dev/null
  kubectl -n "$ns" wait --for=condition=Programmed gateway/waypoint --timeout=5m >/dev/null
  kubectl -n "$ns" rollout status deploy/waypoint --timeout=5m >/dev/null
}

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
      IA4) kubectl label ns "$ns" istio.io/dataplane-mode=ambient --overwrite >/dev/null ;;
      IA7)
        kubectl label ns "$ns" istio.io/dataplane-mode=ambient --overwrite >/dev/null
        # O waypoint nasce antes das aplicações: conexões gRPC abertas antes dele não passariam por ele.
        apply_waypoint "$ns"
        ;;
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
      "$istioctl" install -y --set profile=minimal -f "$(istio_cp_overlay)" >/dev/null
      record istio "$("$istioctl" version --remote=false 2>/dev/null)"
      ;;
    IA4|IA7)
      istioctl=$(istioctl_bin)
      gateway_api_crds
      "$istioctl" install -y --set profile=ambient -f "$(istio_cp_overlay)" "${K3S_CNI[@]}" >/dev/null
      record istio "$("$istioctl" version --remote=false 2>/dev/null)"
      ;;
    LK)
      linkerd=$(linkerd_bin)
      gateway_api_crds
      "$linkerd" install --crds | kubectl apply -f - >/dev/null
      "$linkerd" install "${LINKERD_CP[@]}" | kubectl apply -f - >/dev/null
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
  local cfg=$1
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
        ;;
      LK)
        linkerd_grpc_probes "$ns"
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

# Com default-inbound-policy=all-authenticated, o proxy do Linkerd só libera sem mTLS os probes HTTP do kubelet; os
# probes gRPC nativos (Online Boutique) seriam recusados. Para cada porta com probe gRPC: um Server, uma rota só para
# o serviço de health liberada a qualquer origem e uma rota para o resto que exige identidade mTLS do mesh.
linkerd_grpc_probes() {
  local ns=$1 name port
  kubectl apply -f - >/dev/null <<YAML
apiVersion: policy.linkerd.io/v1alpha1
kind: NetworkAuthentication
metadata: {name: kubelet-probes, namespace: $ns}
spec: {networks: [{cidr: 0.0.0.0/0}]}
---
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata: {name: meshed, namespace: $ns}
spec: {identities: ["*"]}
YAML
  kubectl -n "$ns" get deploy -o json | jq -r '.items[] | .metadata.name as $n | .spec.template.spec.containers[]
      | select(.readinessProbe.grpc != null) | "\($n) \(.readinessProbe.grpc.port)"' | while read -r name port; do
    kubectl apply -f - >/dev/null <<YAML
apiVersion: policy.linkerd.io/v1beta3
kind: Server
metadata: {name: $name-grpc, namespace: $ns}
spec: {podSelector: {matchLabels: {app: $name}}, port: $port, proxyProtocol: HTTP/2}
---
apiVersion: policy.linkerd.io/v1beta3
kind: HTTPRoute
metadata: {name: $name-health, namespace: $ns}
spec:
  parentRefs: [{group: policy.linkerd.io, kind: Server, name: $name-grpc}]
  rules: [{matches: [{path: {type: PathPrefix, value: /grpc.health.v1.Health/}}]}]
---
apiVersion: policy.linkerd.io/v1beta3
kind: HTTPRoute
metadata: {name: $name-all, namespace: $ns}
spec:
  parentRefs: [{group: policy.linkerd.io, kind: Server, name: $name-grpc}]
  rules: [{matches: [{path: {type: PathPrefix, value: /}}]}]
---
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata: {name: $name-health, namespace: $ns}
spec:
  targetRef: {group: policy.linkerd.io, kind: HTTPRoute, name: $name-health}
  requiredAuthenticationRefs: [{group: policy.linkerd.io, kind: NetworkAuthentication, name: kubelet-probes}]
---
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata: {name: $name-all, namespace: $ns}
spec:
  targetRef: {group: policy.linkerd.io, kind: HTTPRoute, name: $name-all}
  requiredAuthenticationRefs: [{group: policy.linkerd.io, kind: MeshTLSAuthentication, name: meshed}]
YAML
  done
}

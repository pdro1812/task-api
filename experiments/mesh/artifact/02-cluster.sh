#!/usr/bin/env bash
# Instala o k3s nas VMs, o Cilium como CNI (o mesmo em todas as configurações, para que só o mesh varie) e o
# Prometheus no nó de controle. No fim, grava o snapshot "base" das VMs, restaurado antes de cada configuração.
# Pré-requisito: ./01-vms.sh. Ferramentas do host (helm, cilium-cli) vão para .state/bin.
source "$(dirname "$0")/lib/common.sh"
source "$MESH_DIR/lib/snapshot.sh"
BIN="$STATE/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
CP_IP=${VM_IP[cp]}

step "ferramentas do host: kubectl, helm, cilium-cli"
command -v kubectl >/dev/null || die "falta kubectl"
if ! command -v helm >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | HELM_INSTALL_DIR="$BIN" USE_SUDO=false bash
fi
if [ ! -x "$BIN/cilium" ]; then
  curl -fsSL https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz | tar -xz -C "$BIN" cilium
fi

K3S_ENV="INSTALL_K3S_CHANNEL=stable"
[ -n "$K3S_VERSION" ] && K3S_ENV="INSTALL_K3S_VERSION=$K3S_VERSION"

step "k3s no nó de controle ($CP_IP)"
if ! vssh cp 'systemctl is-active --quiet k3s'; then
  vssh cp "curl -sfL https://get.k3s.io | $K3S_ENV sh -s - server \
    --flannel-backend=none --disable-network-policy --disable=traefik,servicelb \
    --node-ip=$CP_IP --tls-san=$CP_IP --write-kubeconfig-mode=644 \
    --node-taint node-role.kubernetes.io/control-plane=true:NoSchedule"
fi
TOKEN=$(vssh cp 'sudo cat /var/lib/rancher/k3s/server/node-token')
vssh cp 'cat /etc/rancher/k3s/k3s.yaml' | sed "s/127.0.0.1/$CP_IP/" > "$KUBECONFIG"
chmod 600 "$KUBECONFIG"

for vm in w1 w2 w3; do
  step "k3s agent em $vm"
  if ! vssh "$vm" 'systemctl is-active --quiet k3s-agent'; then
    vssh "$vm" "curl -sfL https://get.k3s.io | $K3S_ENV K3S_URL=https://$CP_IP:6443 K3S_TOKEN=$TOKEN sh -s - agent \
      --node-ip=${VM_IP[$vm]}"
  fi
done
record k3s "$(vssh cp 'k3s --version | head -1')"

step "Cilium (CNI, sem recursos de mesh)"
# operador no nó cp (o chart já tolera todos os taints); mantido nos valores do Helm para sobreviver ao upgrade da CI
CILIUM_CP=(--set-string "operator.nodeSelector.kubernetes\\.io/os=linux"
  --set-string "operator.nodeSelector.node-role\\.kubernetes\\.io/control-plane=true")
if ! kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
  ver_arg=(); [ -n "$CILIUM_VERSION" ] && ver_arg=(--version "$CILIUM_VERSION")
  # cni.exclusive=false e socketLB.hostNamespaceOnly=true: exigidos para o Istio (sidecar e ambient) e o Linkerd
  # funcionarem sobre o Cilium. Caminhos de CNI explícitos: o cilium-cli detecta o k3s e usaria /var/lib/rancher/k3s/...,
  # mas com o flannel desligado o containerd do k3s procura nos caminhos padrão.
  cilium install "${ver_arg[@]}" \
    --set ipam.mode=kubernetes --set kubeProxyReplacement=false --set operator.replicas=1 \
    --set cni.exclusive=false --set socketLB.hostNamespaceOnly=true \
    --set cni.binPath=/opt/cni/bin --set cni.confPath=/etc/cni/net.d "${CILIUM_CP[@]}"
else
  cilium upgrade --reuse-values "${CILIUM_CP[@]}" >/dev/null
fi
cilium status --wait --wait-duration 10m
kubectl wait --for=condition=Ready nodes --all --timeout=300s
record cilium "$(cilium version 2>/dev/null | grep -i 'running' | head -1)"

step "Prometheus no nó de controle (scrape a cada 5 s, NodePort 30090)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
cat > "$STATE/prometheus-values.yaml" <<YAML
alertmanager: {enabled: false}
prometheus-pushgateway: {enabled: false}
server:
  global: {scrape_interval: 5s, scrape_timeout: 4s, evaluation_interval: 5s}
  retention: 30d
  persistentVolume: {enabled: false}
  nodeSelector: {node-role.kubernetes.io/control-plane: "true"}
  tolerations: [{key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}]
  service: {type: NodePort, nodePort: 30090}
kube-state-metrics:
  nodeSelector: {node-role.kubernetes.io/control-plane: "true"}
  tolerations: [{key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}]
prometheus-node-exporter:
  tolerations: [{operator: Exists}]
YAML
helm upgrade --install prometheus prometheus-community/prometheus -n monitoring --create-namespace \
  -f "$STATE/prometheus-values.yaml" --wait --timeout 10m >/dev/null
record prometheus_chart "$(helm -n monitoring list -o json | jq -r '.[0].chart')"

step "componentes do k3s no nó cp (coredns, metrics-server, local-path-provisioner)"
# O k3s reaplica os próprios manifestos a cada partida (o revert do snapshot é uma partida): um arquivo .skip faz o
# k3s deixar de gerenciá-los, e o nodeSelector aplicado aqui permanece.
vssh cp 'sudo sh -c "cd /var/lib/rancher/k3s/server/manifests && for f in coredns.yaml local-storage.yaml metrics-server/*.yaml; do
  touch \$f.skip; done"'
for d in coredns metrics-server local-path-provisioner; do
  kubectl -n kube-system patch deploy "$d" --type=merge -p '{"spec":{"template":{"spec":{
    "nodeSelector":{"node-role.kubernetes.io/control-plane":"true"},
    "tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},
                   {"key":"CriticalAddonsOnly","operator":"Exists"}]}}}}' >/dev/null
  kubectl -n kube-system rollout status deploy "$d" --timeout=5m >/dev/null
done

kubectl get nodes -o wide
kubectl get pods -A --field-selector spec.nodeName=cp -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name
step "sem apt em segundo plano nas VMs"
for vm in "${VMS[@]}"; do
  vssh "$vm" 'sudo systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1'
done
record vm_kernel "$(vssh cp uname -r)"
step "imagens de todas as configurações em todos os nós"
"$MESH_DIR/02b-preload-images.sh"
step "gravando snapshot base das VMs"
snapshot_base
step "cluster pronto. Prometheus: http://$CP_IP:30090"

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
if ! kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
  ver_arg=(); [ -n "$CILIUM_VERSION" ] && ver_arg=(--version "$CILIUM_VERSION")
  # cni.exclusive=false e socketLB.hostNamespaceOnly=true: exigidos para o Istio (sidecar e ambient) e o Linkerd
  # funcionarem sobre o Cilium. Caminhos de CNI do k3s.
  cilium install "${ver_arg[@]}" \
    --set ipam.mode=kubernetes --set kubeProxyReplacement=false --set operator.replicas=1 \
    --set cni.exclusive=false --set socketLB.hostNamespaceOnly=true \
    --set cni.binPath=/var/lib/rancher/k3s/data/cni --set cni.confPath=/var/lib/rancher/k3s/agent/etc/cni/net.d
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
  global: {scrape_interval: 5s, evaluation_interval: 5s}
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

kubectl get nodes -o wide
step "gravando snapshot base das VMs"
snapshot_base
step "cluster pronto. Prometheus: http://$CP_IP:30090"

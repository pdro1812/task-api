# Snapshots das VMs: o estado "base" (k3s + Cilium como CNI + Prometheus, sem mesh) é restaurado antes de cada
# configuração, para que nenhum mesh deixe resíduo no cluster da configuração seguinte.
vms_shutdown() {
  for vm in "${VMS[@]}"; do virsh shutdown "mesh-$vm" >/dev/null 2>&1 || true; done
  for vm in "${VMS[@]}"; do
    for _ in $(seq 1 90); do [ "$(virsh domstate "mesh-$vm")" = "shut off" ] && break; sleep 2; done
    [ "$(virsh domstate "mesh-$vm")" = "shut off" ] || virsh destroy "mesh-$vm" >/dev/null
  done
}
vms_start() {
  for vm in "${VMS[@]}"; do virsh start "mesh-$vm" >/dev/null 2>&1 || true; done
  for vm in "${VMS[@]}"; do wait_ssh "$vm"; done
  for _ in $(seq 1 60); do
    kubectl get nodes >/dev/null 2>&1 && kubectl wait --for=condition=Ready nodes --all --timeout=10s >/dev/null 2>&1 && break
    sleep 5
  done
  kubectl wait --for=condition=Ready nodes --all --timeout=300s >/dev/null
}
snapshot_base() {
  vms_shutdown
  for vm in "${VMS[@]}"; do
    virsh snapshot-delete "mesh-$vm" base >/dev/null 2>&1 || true
    virsh snapshot-create-as "mesh-$vm" base --description "k3s + cilium + prometheus, sem mesh" >/dev/null
  done
  vms_start
}
restore_base() {
  vms_shutdown
  for vm in "${VMS[@]}"; do virsh snapshot-revert "mesh-$vm" base >/dev/null; done
  vms_start
  kubectl -n kube-system rollout status ds/cilium --timeout=300s >/dev/null
}

#!/usr/bin/env bash
# Cria as 4 VMs do cluster (KVM/libvirt + cloud-init), cada uma presa a núcleos P exclusivos.
#   par 0 dos núcleos P: host e threads do QEMU | par 1: cp (2 vCPU, 6 GB) | pares 2-3, 4-5, 6-7: w1, w2, w3 (4 vCPU, 14 GB)
#   núcleos E: ficam livres para o gerador de carga (k6), fora das VMs
# Idempotente: VMs que já existem são mantidas. Apagar tudo: ./01-vms.sh --destroy
source "$(dirname "$0")/lib/common.sh"
POOL="$STATE/disks"
mkdir -p "$POOL"

if [ "${1:-}" = "--destroy" ]; then
  for vm in "${VMS[@]}"; do
    virsh destroy "mesh-$vm" 2>/dev/null || true
    virsh undefine "mesh-$vm" --snapshots-metadata 2>/dev/null || true
  done
  virsh net-destroy "$NET_NAME" 2>/dev/null || true
  virsh net-undefine "$NET_NAME" 2>/dev/null || true
  rm -rf "$POOL"
  exit 0
fi

mapfile -t PAIRS < <(p_core_pairs)
declare -A VM_CPUS=([cp]="${PAIRS[1]}" [w1]="${PAIRS[2]},${PAIRS[3]}" [w2]="${PAIRS[4]},${PAIRS[5]}" [w3]="${PAIRS[6]},${PAIRS[7]}")
declare -A VM_MEM=([cp]=6144 [w1]=14336 [w2]=14336 [w3]=14336)
EMU_CPUS="${PAIRS[0]}"

step "chave SSH do experimento"
[ -f "$SSH_KEY" ] || ssh-keygen -q -t ed25519 -N "" -f "$SSH_KEY"

step "rede $NET_NAME ($NET_PREFIX.0/24)"
if ! virsh net-info "$NET_NAME" >/dev/null 2>&1; then
  hosts=""
  for vm in "${VMS[@]}"; do hosts+="<host mac='${VM_MAC[$vm]}' name='$vm' ip='${VM_IP[$vm]}'/>"; done
  cat > "$STATE/net.xml" <<XML
<network>
  <name>$NET_NAME</name>
  <forward mode='nat'/>
  <bridge name='virbr-mesh' stp='off'/>
  <ip address='$NET_PREFIX.1' netmask='255.255.255.0'>
    <dhcp><range start='$NET_PREFIX.100' end='$NET_PREFIX.200'/>$hosts</dhcp>
  </ip>
</network>
XML
  virsh net-define "$STATE/net.xml" >/dev/null
  virsh net-autostart "$NET_NAME" >/dev/null
fi
virsh net-start "$NET_NAME" 2>/dev/null || true

step "imagem Ubuntu"
BASE="$POOL/ubuntu-base.img"
[ -f "$BASE" ] || curl -fL -o "$BASE" "$UBUNTU_IMAGE_URL"
record ubuntu_image_sha256 "$(sha256sum "$BASE" | cut -d' ' -f1)"

for vm in "${VMS[@]}"; do
  name="mesh-$vm"
  if virsh dominfo "$name" >/dev/null 2>&1; then echo "$name já existe"; continue; fi
  step "VM $name (CPUs do host ${VM_CPUS[$vm]}, ${VM_MEM[$vm]} MB)"
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$POOL/$name.qcow2" 40G
  cat > "$STATE/$vm-user-data" <<YAML
#cloud-config
hostname: $vm
users:
  - name: mesh
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: ["$(cat "$SSH_KEY.pub")"]
package_update: true
packages: [curl, jq, bpftrace, bpfcc-tools, linux-tools-generic, sysstat]
runcmd:
  - [sh, -c, "apt-get install -y linux-tools-\$(uname -r) || true"]
  - [sh, -c, "swapoff -a; sed -i '/ swap / s/^/#/' /etc/fstab"]
  - [sh, -c, "echo 'kernel.bpf_stats_enabled=1' > /etc/sysctl.d/90-mesh.conf; sysctl --system"]
YAML
  cloud-localds "$POOL/$name-seed.iso" "$STATE/$vm-user-data"
  ncpu=$(echo "${VM_CPUS[$vm]}" | tr ',' '\n' | wc -l)
  virt-install --name "$name" --memory "${VM_MEM[$vm]}" --vcpus "$ncpu" --cpu host-passthrough \
    --disk "path=$POOL/$name.qcow2,format=qcow2,bus=virtio" --disk "path=$POOL/$name-seed.iso,device=cdrom" \
    --network "network=$NET_NAME,mac=${VM_MAC[$vm]},model=virtio" \
    --os-variant ubuntu24.04 --import --graphics none --noautoconsole >/dev/null
  # vCPU i fica presa a uma única CPU do host; as threads do QEMU ficam no par 0
  i=0
  for c in $(echo "${VM_CPUS[$vm]}" | tr ',' ' '); do
    virsh vcpupin "$name" "$i" "$c" --config --live >/dev/null
    i=$((i + 1))
  done
  virsh emulatorpin "$name" "$EMU_CPUS" --config --live >/dev/null
done

for vm in "${VMS[@]}"; do
  wait_ssh "$vm"
  vssh "$vm" 'cloud-init status --wait >/dev/null; uname -r'
  # Ejeta o ISO do cloud-init: snapshots internos exigem que todos os discos com mídia sejam qcow2
  cd_dev=$(virsh domblklist "mesh-$vm" --details | awk '$2=="cdrom" && $4!="-" {print $3}')
  if [ -n "$cd_dev" ]; then virsh change-media "mesh-$vm" "$cd_dev" --eject --config --live >/dev/null; fi
done
record vm_kernel "$(vssh w1 uname -r)"
step "VMs prontas: ${VMS[*]} (ssh: ssh -i $SSH_KEY mesh@<ip>)"

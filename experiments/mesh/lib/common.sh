# Funções e variáveis comuns aos scripts de experiments/mesh. Carregado com: source "$(dirname "$0")/lib/common.sh"
set -euo pipefail
MESH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STATE="$MESH_DIR/.state"
mkdir -p "$STATE"
source "$MESH_DIR/versions.env"
export LIBVIRT_DEFAULT_URI=qemu:///system
export KUBECONFIG="$STATE/kubeconfig"
NET_NAME=meshnet
NET_PREFIX=192.168.150
VMS=(cp w1 w2 w3)
declare -A VM_IP=([cp]=$NET_PREFIX.10 [w1]=$NET_PREFIX.11 [w2]=$NET_PREFIX.12 [w3]=$NET_PREFIX.13)
declare -A VM_MAC=([cp]=52:54:00:15:00:10 [w1]=52:54:00:15:00:11 [w2]=52:54:00:15:00:12 [w3]=52:54:00:15:00:13)
SSH_KEY="$STATE/id_ed25519"
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
step() { echo "== $*"; }
warn() { echo "AVISO: $*" >&2; }
die() { echo "ERRO: $*" >&2; exit 1; }
vssh() { local vm=$1; shift; ssh "${SSH_OPTS[@]}" "mesh@${VM_IP[$vm]}" "$@"; }
record() { echo "$1=$2" >> "$STATE/versoes-instaladas.txt"; }
# Pares de threads (hyperthreading) dos núcleos P, em ordem, ex.: "0,1" "2,3" ...
p_core_pairs() {
  local cpus
  cpus=$(cat /sys/devices/cpu_core/cpus 2>/dev/null) || die "não achei /sys/devices/cpu_core/cpus (CPU híbrida Intel esperada)"
  for c in $(seq $(echo "$cpus" | cut -d- -f1) $(echo "$cpus" | cut -d- -f2)); do
    cat /sys/devices/system/cpu/cpu$c/topology/thread_siblings_list
  done | sort -t, -k1,1n -u
}
e_cores() { cat /sys/devices/cpu_atom/cpus; }
wait_ssh() {
  local vm=$1
  for _ in $(seq 1 90); do vssh "$vm" true 2>/dev/null && return 0; sleep 2; done
  die "VM $vm não respondeu por SSH em ${VM_IP[$vm]}"
}

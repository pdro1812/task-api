#!/usr/bin/env bash
# Ajusta o host para medições estáveis e confere os pré-requisitos. Reverter: ./00-host.sh --restore
#   - governor "performance" em todas as CPUs, turbo desligado, C-states profundos desligados (como no MeshInsight)
#   - confere RAPL (energia), KVM e as ferramentas usadas pelos outros scripts
# Os ajustes de CPU não sobrevivem a um reboot: rode de novo depois de reiniciar a máquina.
source "$(dirname "$0")/lib/common.sh"

if [ "${1:-}" = "--restore" ]; then
  step "restaurando turbo, governor e C-states"
  echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo powersave | sudo tee "$g" >/dev/null; done
  for s in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do echo 0 | sudo tee "$s" >/dev/null; done
  exit 0
fi

step "ferramentas"
missing=()
for t in virsh virt-install qemu-img cloud-localds curl ssh ssh-keygen k6 python3 git taskset jq kubectl; do
  command -v "$t" >/dev/null || missing+=("$t")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "faltam: ${missing[*]}"
  echo "instale com: sudo apt install -y qemu-kvm libvirt-daemon-system virtinst cloud-image-utils util-linux jq"
  echo "  (k6: ver experiments/versions.env; depois: sudo usermod -aG libvirt,kvm \$USER e abra um terminal novo)"
  exit 1
fi
[ -e /dev/kvm ] || die "/dev/kvm não existe: ative a virtualização (VT-x) na BIOS"
virsh list >/dev/null 2>&1 || die "sem acesso ao libvirt (o usuário está no grupo libvirt?)"

step "topologia da CPU"
echo "pares de threads dos núcleos P: $(p_core_pairs | tr '\n' ' ')"
echo "núcleos E: $(e_cores)"
[ "$(p_core_pairs | wc -l)" -ge 8 ] || die "esperava 8 núcleos P (i7-12700K)"

step "RAPL (energia)"
for z in intel-rapl:0 intel-rapl:0:0; do
  f=/sys/class/powercap/$z
  [ -r "$f/name" ] || die "sem $f"
  e=$(sudo cat "$f/energy_uj") || die "não consegui ler $f/energy_uj"
  echo "$z ($(cat "$f/name")): energy_uj=$e"
done

step "CPU: governor performance, sem turbo, sem C-states profundos"
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee "$g" >/dev/null; done
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null
# Mantém só POLL e C1 (state0 e state1); desliga os estados mais profundos.
for s in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
  n=$(basename "$(dirname "$s")" | tr -dc 0-9)
  [ "$n" -ge 2 ] && echo 1 | sudo tee "$s" >/dev/null
done
# Leitura do RAPL sem sudo durante as baterias (volta ao padrão no reboot)
for z in intel-rapl:0 intel-rapl:0:0; do sudo chmod o+r /sys/class/powercap/$z/energy_uj; done
grep -H . /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor /sys/devices/system/cpu/intel_pstate/no_turbo

{
  echo "# $(date -Is)"
  echo "kernel=$(uname -r)"
  echo "cpu=$(lscpu | sed -n 's/^Model name: *//p')"
} > "$STATE/versoes-instaladas.txt"
step "host pronto"

#!/usr/bin/env bash
# Bateria de energia com o halt-polling do KVM desligado (halt_poll_ns=0). Na bateria principal, o host girava até
# 200 µs em cada vCPU ociosa antes de dormir, o que gasta energia sem aparecer como CPU ocupada nas VMs e favorecia
# as configurações que ocupam mais a CPU. Mesmas taxas, aquecimento e duração da bateria principal; 6 configurações
# x 3 apps x cargas 30 e 90% x 3 repetições = 108 rodadas (~8 h). A potência ociosa é medida em cada configuração
# (idle.json), e a da B serve de base comum na agregação. A latência do artigo continua vindo da bateria principal.
# Uso: ./05b-energia.sh [diretório]   Padrão: /mnt/dados/resultados/energia-hp0
source "$(dirname "$0")/lib/common.sh"
[ "$(cat /sys/module/kvm/parameters/halt_poll_ns)" = 0 ] || \
  die "halt_poll_ns não é 0: rode 'echo 0 | sudo tee /sys/module/kvm/parameters/halt_poll_ns'"
# O KVM copia o parâmetro para a VM quando o QEMU nasce: cada 03-config.sh desliga as VMs, reverte o snapshot e as
# liga de novo (lib/snapshot.sh), então todas as rodadas usam VMs criadas depois da mudança.
CONFIGS="B IS IA4 IA7 LK CI" APPS="echo ob hotel" LOADS="30 90" REPS=3 REQUER_HP0=1 \
  exec "$MESH_DIR/05-bateria.sh" "${1:-/mnt/dados/resultados/energia-hp0}"

#!/usr/bin/env bash
# Prepara uma configuração do experimento: restaura o snapshot base, instala o mesh, implanta as três aplicações,
# aplica as políticas e faz um teste de fumaça. Uso: ./03-config.sh <B|IS|IA4|IA7|LK|CI>
source "$(dirname "$0")/lib/common.sh"
source "$MESH_DIR/lib/snapshot.sh"
source "$MESH_DIR/lib/apps.sh"
source "$MESH_DIR/lib/mesh.sh"
export PATH="$STATE/bin:$PATH"
CFG=${1:?uso: $0 <B|IS|IA4|IA7|LK|CI>}

step "[$CFG] restaurando o snapshot base"
restore_base
step "[$CFG] instalando o mesh"
install_mesh "$CFG"
step "[$CFG] aplicações"
fetch_sources
create_namespaces "$CFG"
deploy_echo
deploy_ob
deploy_hotel
apply_policies "$CFG"
# o Linkerd injeta o proxy na criação do pod; a anotação do pod de entrada exige um rollout
[ "$CFG" = LK ] && for ns in "${APP_NS[@]}"; do kubectl -n "$ns" rollout restart deploy >/dev/null; done
wait_apps
kubectl get pods -A -o wide | grep -E '^(echo|ob|hotel) ' | awk '{print $1, $2, $3, $8}' | column -t
step "[$CFG] teste de fumaça (deve dar 200 nas três)"
smoke_test
echo "$CFG" > "$STATE/config-atual"
step "[$CFG] pronta"

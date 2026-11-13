# Implantação das três cargas: echo (fortio), Online Boutique e Hotel Reservation (DeathStarBench).
# Cada deployment é fixado num nó de trabalho (rodízio em ordem alfabética), para que a posição dos pods,
# e portanto o tráfego entre nós, seja igual em todas as configurações.
SRC="$STATE/src"
DATASTORE_PORTS="6379 27017 11211 8300 8301 8302 8500 8600 5775 5778 6831 6832 9411 14250 14267 14268 16686"

fetch_sources() {
  mkdir -p "$SRC"
  if [ ! -d "$SRC/microservices-demo" ]; then
    git clone -q https://github.com/GoogleCloudPlatform/microservices-demo "$SRC/microservices-demo"
    local ref=${ONLINE_BOUTIQUE_REF:-$(git -C "$SRC/microservices-demo" describe --tags --abbrev=0)}
    git -C "$SRC/microservices-demo" checkout -q "$ref"
  fi
  if [ ! -d "$SRC/DeathStarBench" ]; then
    git clone -q https://github.com/delimitrou/DeathStarBench "$SRC/DeathStarBench"
    [ -n "$DEATHSTARBENCH_REF" ] && git -C "$SRC/DeathStarBench" checkout -q "$DEATHSTARBENCH_REF"
  fi
  record online_boutique "$(git -C "$SRC/microservices-demo" describe --tags --always) $(git -C "$SRC/microservices-demo" rev-parse HEAD)"
  record deathstarbench "$(git -C "$SRC/DeathStarBench" rev-parse HEAD)"
}

pin_round_robin() {
  local ns=$1 i=0 nodes=(w1 w2 w3)
  for d in $(kubectl -n "$ns" get deploy -o name | sort); do
    kubectl -n "$ns" patch "$d" --type=merge \
      -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${nodes[$((i % 3))]}\"}}}}}" >/dev/null
    i=$((i + 1))
  done
}

deploy_echo() {
  kubectl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: echo, namespace: echo}
spec:
  replicas: 1
  selector: {matchLabels: {app: echo}}
  template:
    metadata: {labels: {app: echo}}
    spec:
      nodeSelector: {kubernetes.io/hostname: w3}
      containers:
      - name: fortio
        image: $FORTIO_IMAGE
        args: ["server", "-http-port", "8080"]
        ports: [{containerPort: 8080, name: http}]
---
apiVersion: v1
kind: Service
metadata: {name: echo, namespace: echo}
spec: {selector: {app: echo}, ports: [{name: http, port: 8080, targetPort: 8080}]}
---
# relay: recebe a carga de fora do cluster e repassa ao echo, criando um salto leste-oeste dentro do mesh
apiVersion: apps/v1
kind: Deployment
metadata: {name: relay, namespace: echo}
spec:
  replicas: 1
  selector: {matchLabels: {app: relay}}
  template:
    metadata: {labels: {app: relay, edge: "true"}}
    spec:
      nodeSelector: {kubernetes.io/hostname: w2}
      containers:
      - name: fortio
        image: $FORTIO_IMAGE
        args: ["server", "-http-port", "8079", "-M", "8080 http://echo.echo:8080"]
        ports: [{containerPort: 8080, name: http}, {containerPort: 8079, name: http-admin}]
---
apiVersion: v1
kind: Service
metadata: {name: relay, namespace: echo}
spec:
  type: NodePort
  selector: {app: relay}
  ports: [{name: http, port: 8080, targetPort: 8080, nodePort: 30082}]
YAML
}

deploy_ob() {
  kubectl -n ob apply -f "$SRC/microservices-demo/release/kubernetes-manifests.yaml" >/dev/null
  kubectl -n ob delete deploy loadgenerator --ignore-not-found >/dev/null
  kubectl -n ob patch svc frontend-external --type=merge \
    -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"targetPort":8080,"nodePort":30080}]}}' >/dev/null
  kubectl -n ob patch deploy frontend --type=merge -p '{"spec":{"template":{"metadata":{"labels":{"edge":"true"}}}}}' >/dev/null
  pin_round_robin ob
}

deploy_hotel() {
  kubectl -n hotel apply -R -f "$SRC/DeathStarBench/hotelReservation/kubernetes" >/dev/null
  kubectl -n hotel expose deploy frontend --name=frontend-np --type=NodePort --port=5000 --target-port=5000 >/dev/null 2>&1 || true
  kubectl -n hotel patch svc frontend-np --type=json -p '[{"op":"replace","path":"/spec/ports/0/nodePort","value":30081}]' >/dev/null
  kubectl -n hotel patch deploy frontend --type=merge -p '{"spec":{"template":{"metadata":{"labels":{"edge":"true"}}}}}' >/dev/null
  pin_round_robin hotel
}

# Portas de aplicação (HTTP/gRPC) de um namespace: todas as containerPorts menos as de bancos e infraestrutura
app_ports() {
  local ns=$1
  for p in $( { kubectl -n "$ns" get deploy -o jsonpath='{..containerPort}'; echo; \
               kubectl -n "$ns" get svc -o jsonpath='{.items[*].spec.ports[*].targetPort}'; } | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nu); do
    case " $DATASTORE_PORTS " in *" $p "*) ;; *) echo "$p" ;; esac
  done
}

wait_apps() {
  for ns in echo ob hotel; do
    kubectl -n "$ns" wait --for=condition=Available deploy --all --timeout=15m >/dev/null
  done
}

smoke_test() {
  local ip=${VM_IP[w1]}
  for url in "http://$ip:30082/echo" "http://$ip:30080/" "http://$ip:30081/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194"; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)
    echo "$code $url"
    [ "$code" = 200 ] || warn "resposta $code em $url"
  done
}

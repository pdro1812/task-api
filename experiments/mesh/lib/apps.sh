# Implantação das três cargas: echo (fortio), Online Boutique e Hotel Reservation (DeathStarBench).
# Cada deployment é fixado num nó de trabalho (rodízio em ordem alfabética, ver apply_pinned), para que a posição
# dos pods, e portanto o tráfego entre nós, seja igual em todas as configurações.
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

# Aplica manifestos (stdin) no namespace $1 já ajustados, sem patches depois da criação (um patch no modelo do pod
# recriaria o pod, e o Consul do Hotel perderia os registros, que ficam só em memória):
#   - cada deployment fixado num nó de trabalho, em rodízio pela ordem alfabética dos nomes;
#   - imagePullPolicy IfNotPresent em todos os contêineres: as imagens já estão no snapshot base (02b-preload-images.sh);
#   - sem limits de CPU/memória nem livenessProbe: os valores de demonstração dos manifestos (200m de CPU por serviço
#     no Online Boutique) estrangulam as aplicações, e o liveness reinicia o pod sobrecarregado, o que vira cascata de
#     timeouts; a saturação passaria a medir esses artefatos, não o cluster (requests e readiness ficam);
#   - o filtro jq opcional $2 faz os ajustes próprios de cada aplicação (antes do rodízio).
apply_pinned() {
  local ns=$1 extra=${2:-.}
  kubectl -n "$ns" create --dry-run=client -o json -f - \
    | jq -s '{apiVersion: "v1", kind: "List", items: map(if .kind == "List" then .items[] else . end)}
          | '"$extra"'
          | (.items | map(select(.kind == "Deployment") | .metadata.name) | sort) as $deps
          | .items |= map(if .kind == "Deployment" then
                .metadata.name as $n
                | .spec.template.spec.nodeSelector = {"kubernetes.io/hostname": (["w1", "w2", "w3"][($deps | index($n)) % 3])}
                | .spec.template.spec.containers[].imagePullPolicy = "IfNotPresent"
                | del(.spec.template.spec.containers[].resources.limits, .spec.template.spec.containers[].livenessProbe)
                | if .spec.template.spec.initContainers then .spec.template.spec.initContainers[].imagePullPolicy = "IfNotPresent" else . end
              else . end)' \
    | kubectl -n "$ns" apply -f - >/dev/null
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
        imagePullPolicy: IfNotPresent
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
        imagePullPolicy: IfNotPresent
        # só o proxy (-M) na 8080 e o HTTP de administração na 8088; o fortio abre gRPC na 8079 por padrão
        args: ["server", "-http-port", "8088", "-grpc-port", "disabled", "-redirect-port", "disabled",
               "-tcp-port", "disabled", "-udp-port", "disabled", "-M", "8080 http://echo.echo:8080"]
        ports: [{containerPort: 8080, name: http}, {containerPort: 8088, name: http-admin}]
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
  # sem o loadgenerator (a carga vem do k6); frontend é o pod de entrada
  apply_pinned ob '.items |= map(select(.metadata.name != "loadgenerator")
      | if .kind == "Deployment" and .metadata.name == "frontend" then .spec.template.metadata.labels.edge = "true" else . end
      | if .kind == "Service" and .metadata.name == "frontend-external" then
          .spec.type = "NodePort" | .spec.ports = [{name: "http", port: 80, targetPort: 8080, nodePort: 30080}] else . end)' \
    < "$SRC/microservices-demo/release/kubernetes-manifests.yaml"
}

deploy_hotel() {
  # Por padrão cada serviço se registra no Consul com o IP do pod, e as chamadas gRPC vão direto ao pod, por fora
  # dos Services. Os meshes tratam mal esse caminho (o sidecar do Istio manda texto puro, o waypoint não o vê). Com
  # <Serviço>IP no config.json, o registro leva o nome DNS do Service e o tráfego é endereçado ao Service.
  jq '. + {FrontendIP: "frontend.hotel.svc.cluster.local", GeoIP: "geo.hotel.svc.cluster.local",
           ProfileIP: "profile.hotel.svc.cluster.local", RateIP: "rate.hotel.svc.cluster.local",
           RecommendIP: "recommendation.hotel.svc.cluster.local", ReserveIP: "reservation.hotel.svc.cluster.local",
           SearchIP: "search.hotel.svc.cluster.local", UserIP: "user.hotel.svc.cluster.local"}' \
    "$SRC/DeathStarBench/hotelReservation/config.json" > "$STATE/hotel-config.json"
  kubectl -n hotel create configmap hotel-config --from-file=config.json="$STATE/hotel-config.json" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # Os manifestos chamam "./frontend" etc., mas a imagem publicada instala os binários em /go/bin (no PATH):
  # tira o "./" do comando e fixa a tag da imagem.
  local f
  for f in $(find "$SRC/DeathStarBench/hotelReservation/kubernetes" -name '*.yaml' | sort); do cat "$f"; echo; echo ---; done \
    | sed -E 's#^( +- )\./([a-z]+)$#\1\2#; s#deathstarbench/hotel-reservation:latest#deathstarbench/hotel-reservation:'"$HOTEL_IMAGE_TAG"'#; s#hashicorp/consul:latest#'"${HOTEL_CONSUL_IMAGE:-hashicorp/consul:latest}"'#; s#jaegertracing/all-in-one:latest#'"${HOTEL_JAEGER_IMAGE:-jaegertracing/all-in-one:latest}"'#; s#(image: )memcached$#\1'"${HOTEL_MEMCACHED_IMAGE:-memcached}"'#' \
    | apply_pinned hotel '.items |= map(if .kind == "Deployment" and (.spec.template.spec.containers[0].image | startswith("deathstarbench/hotel-reservation:")) then
          .spec.template.spec.volumes = [{name: "hotel-config", configMap: {name: "hotel-config"}}]
          | .spec.template.spec.containers[0].volumeMounts = [{name: "hotel-config", mountPath: "/workspace/config.json", subPath: "config.json"}]
          | if .metadata.name == "frontend" then .spec.template.metadata.labels.edge = "true" else . end
        else . end)'
  kubectl -n hotel apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata: {name: frontend-np, namespace: hotel}
spec:
  type: NodePort
  selector: {io.kompose.service: frontend}
  ports: [{port: 5000, targetPort: 5000, nodePort: 30081}]
YAML
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
  local ip=${VM_IP[w1]} fail=0
  for url in "http://$ip:30082/echo" "http://$ip:30080/" "http://$ip:30081/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194"; do
    # até ~1 min: logo depois do deploy um serviço (ex.: cartservice, .NET) pode ainda recusar conexões
    for _ in $(seq 1 12); do
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)
      [ "$code" = 200 ] && break; sleep 5
    done
    echo "$code $url"
    [ "$code" = 200 ] || { warn "resposta $code em $url"; fail=1; }
  done
  return $fail
}

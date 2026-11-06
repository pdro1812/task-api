# Base fixada pelo digest usado nas baterias v2 (experiments/versions.env)
FROM node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914

# Instala o tini (init system para containers)
# Isso garante que os sinais do Kubernetes (SIGTERM) cheguem no Node.js
RUN apk add --no-cache tini

WORKDIR /app

COPY package*.json ./ 

# Define NODE_ENV para otimizar a performance do Express
ENV NODE_ENV=production

# Commit da imagem, exposto em /version para medir quando a nova versão passou a responder
ARG BUILD_SHA=dev
ENV BUILD_SHA=$BUILD_SHA

RUN npm ci --omit=dev

COPY . .

USER node 

EXPOSE 3000

# Usa o tini como entrypoint
ENTRYPOINT ["/sbin/tini", "--"]

CMD [ "node", "index.js" ]
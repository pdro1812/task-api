FROM node:20-alpine

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
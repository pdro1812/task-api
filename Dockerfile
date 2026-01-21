FROM node:20-alpine

# Instala o tini (init system para containers)
# Isso garante que os sinais do Kubernetes (SIGTERM) cheguem no Node.js
RUN apk add --no-cache tini

WORKDIR /app

COPY package*.json ./ 

# Define NODE_ENV para otimizar a performance do Express
ENV NODE_ENV=production

RUN npm ci --only=production

COPY . .

USER node 

EXPOSE 3000

# Usa o tini como entrypoint
ENTRYPOINT ["/sbin/tini", "--"]

CMD [ "node", "index.js" ]
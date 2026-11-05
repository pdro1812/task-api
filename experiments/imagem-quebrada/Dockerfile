# Versão "quebrada" para o experimento de rollback: igual à imagem base, mas /ready sempre responde 503,
# então o Pod nunca fica Ready e o rolling update trava.
# Uso: docker build --build-arg BASE=task-api:exp-<sha> -t task-api:exp-quebrada experiments/imagem-quebrada
ARG BASE
FROM ${BASE}
USER root
RUN grep -q "app.get('/ready', (req, res) => {" app.js \
 && sed -i "s|app.get('/ready', (req, res) => {|app.get('/ready', (req, res) => { return res.status(503).json({ status: 'NOT READY', motivo: 'imagem quebrada (experimento)' });|" app.js
ENV BUILD_SHA=quebrada
USER node

const { createApp, loadConfig } = require('./app');

const config = loadConfig();
const { app, redisClient } = createApp({ config });

// Eventos de Monitoramento
redisClient.on('error', (err) => console.error('Erro no Redis:', err.message));
redisClient.on('connect', () => console.log('Conectado ao Redis'));
redisClient.on('reconnecting', () => console.log('Tentando reconectar ao Redis...'));

// Inicialização Assíncrona do Redis
(async () => {
    try {
        await redisClient.connect();
    } catch (e) {
        console.error('Falha inicial na conexão com Redis (o retry vai assumir daqui)');
    }
})();

// --- INICIALIZAÇÃO DO SERVIDOR COM GRACEFUL SHUTDOWN ---

const server = app.listen(config.port, () => {
    console.log(`Task API ${config.version} rodando na porta ${config.port} (modo ${config.mode})`);
    console.log(`Redis alvo: ${config.redisHost}:${config.redisPort}`);
});

// Função para encerrar graciosamente
function gracefulShutdown(signal) {
    console.log(`${signal} recebido. Iniciando graceful shutdown...`);

    // Se travar no desligamento, força o encerramento após 10s
    setTimeout(() => {
        console.error('Forçando encerramento após timeout...');
        process.exit(1);
    }, 10000).unref();

    // 1. Para de receber novas requisições
    server.close(async () => {
        console.log('Servidor HTTP fechado (novas conexões recusadas).');

        // 2. Fecha conexão com Redis (quit espera comandos pendentes; destroy se não estiver conectado)
        try {
            if (redisClient.isReady) {
                await redisClient.quit();
                console.log('Conexão Redis fechada com sucesso.');
            } else if (redisClient.isOpen) {
                redisClient.destroy();
            }
        } catch (err) {
            console.error('Erro ao fechar Redis:', err);
        }

        console.log('Aplicação encerrada.');
        process.exit(0);
    });
}

// Captura sinais do SO e do Kubernetes
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

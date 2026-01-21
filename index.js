const express = require('express');
const { createClient } = require('redis');

const app = express();
app.use(express.json());

const PORT = process.env.APP_PORT || 3000;
const REDIS_HOST = process.env.REDIS_HOST || 'localhost';
const REDIS_PORT = process.env.REDIS_PORT || 6379;
const REDIS_PASSWORD = process.env.REDIS_PASSWORD || undefined;
const VERSION = process.env.APP_VERSION || '1.0.0'; // Ajustei para APP_VERSION para bater com o ConfigMap

// Configuração do Cliente Redis com estratégia de reconexão
const redisClient = createClient({
    socket: {
        host: REDIS_HOST,
        port: REDIS_PORT,
        connectTimeout: 2000,
        // Tenta reconectar a cada 1 segundo indefinidamente
        reconnectStrategy: (retries) => {
            console.log(`Tentativa de reconexão #${retries}`);
            return 1000;
        }
    },
    password: REDIS_PASSWORD,
});

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

// --- ENDPOINTS DE CONFIABILIDADE (PROBES) ---

// Liveness Probe: O processo está rodando?
app.get('/health', (req, res) => {
    res.status(200).json({ status: 'UP', version: VERSION, timestamp: new Date() });
});

// Readiness Probe: O app consegue processar dados? (Depende do Redis)
app.get('/ready', (req, res) => {
    if (redisClient.isOpen) {
        res.status(200).json({ status: 'READY', redis: 'CONNECTED' });
    } else {
        // Retorna 503 para o K8s remover este pod do Service
        res.status(503).json({ status: 'NOT READY', redis: 'DISCONNECTED' });
    }
});

app.get('/version', (req, res) => {
    res.json({ version: VERSION });
});

// --- REGRAS DE NEGÓCIO ---

// GET /tasks - Lista tarefas
app.get('/tasks', async (req, res) => {
    if (!redisClient.isOpen) return res.status(503).json({ error: 'Database unavailable' });

    try {
        const tasks = await redisClient.lRange('tasks', 0, -1);
        const parsedTasks = tasks.map(t => JSON.parse(t));
        res.json(parsedTasks);
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

// POST /tasks - Cria tarefa
app.post('/tasks', async (req, res) => {
    if (!redisClient.isOpen) return res.status(503).json({ error: 'Database unavailable' });

    const { description } = req.body;
    if (!description) return res.status(400).json({ error: 'Description is required' });

    const task = {
        id: Date.now(),
        description,
        createdAt: new Date()
    };

    try {
        await redisClient.rPush('tasks', JSON.stringify(task));
        res.status(201).json(task);
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

// --- INICIALIZAÇÃO DO SERVIDOR COM GRACEFUL SHUTDOWN ---

const server = app.listen(PORT, () => {
    console.log(`Task API ${VERSION} rodando na porta ${PORT}`);
    console.log(`Redis alvo: ${REDIS_HOST}:${REDIS_PORT}`);
});

// Função para encerrar graciosamente
async function gracefulShutdown(signal) {
    console.log(`${signal} recebido. Iniciando graceful shutdown...`);

    // 1. Para de receber novas requisições
    server.close(async () => {
        console.log('Servidor HTTP fechado (novas conexões recusadas).');

        // 2. Fecha conexão com Redis (espera comandos pendentes terminarem)
        if (redisClient.isOpen) {
            try {
                await redisClient.quit();
                console.log('Conexão Redis fechada com sucesso.');
            } catch (err) {
                console.error('Erro ao fechar Redis:', err);
            }
        }

        console.log('Aplicação encerrada.');
        process.exit(0);
    });

    // Se travar no desligamento, força o encerramento após 10s
    setTimeout(() => {
        console.error('Forçando encerramento após timeout...');
        process.exit(1);
    }, 10000);
}

// Captura sinais do SO e do Kubernetes
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));
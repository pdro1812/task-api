const express = require('express');
const { createClient } = require('redis');
const promClient = require('prom-client');
const { ClientClosedError, ClientOfflineError, SocketClosedUnexpectedlyError } = require('@redis/client/dist/lib/errors');

// Modos de resiliência avaliados no artigo:
//  - baseline: comportamento original (checa isOpen e enfileira comandos enquanto o Redis está fora)
//  - failfast: checa isReady, desabilita a fila offline e responde 503 imediatamente
//  - breaker:  failfast + circuit breaker com timeout por comando
const MODES = ['baseline', 'failfast', 'breaker'];

function loadConfig(env = process.env) {
    const mode = env.RESILIENCE_MODE || 'failfast';
    if (!MODES.includes(mode)) throw new Error(`RESILIENCE_MODE inválido: ${mode}`);
    return {
        port: Number(env.APP_PORT || 3000),
        redisHost: env.REDIS_HOST || 'localhost',
        redisPort: Number(env.REDIS_PORT || 6379),
        redisPassword: env.REDIS_PASSWORD || undefined,
        version: env.APP_VERSION || '1.0.0',
        build: env.BUILD_SHA || 'dev',
        mode,
        // Se true, o Readiness Probe falha quando o Redis cai (todos os Pods saem do Service)
        readinessDependsOnRedis: (env.READINESS_DEPENDS_ON_REDIS || 'false') === 'true',
        commandTimeoutMs: Number(env.REDIS_COMMAND_TIMEOUT_MS || 500),
        breakerFailureThreshold: Number(env.BREAKER_FAILURE_THRESHOLD || 5),
        breakerCooldownMs: Number(env.BREAKER_COOLDOWN_MS || 5000),
    };
}

// Circuit breaker mínimo: CLOSED -> OPEN após N falhas seguidas, OPEN -> HALF_OPEN após o cooldown
class CircuitBreaker {
    constructor({ failureThreshold, cooldownMs, onStateChange = () => {} }) {
        this.failureThreshold = failureThreshold;
        this.cooldownMs = cooldownMs;
        this.onStateChange = onStateChange;
        this.failures = 0;
        this.openedAt = 0;
        this.setState('CLOSED');
    }

    setState(state) {
        this.state = state;
        this.onStateChange(state);
    }

    canRequest() {
        if (this.state === 'OPEN' && Date.now() - this.openedAt >= this.cooldownMs) {
            this.setState('HALF_OPEN');
        }
        return this.state !== 'OPEN';
    }

    success() {
        this.failures = 0;
        if (this.state !== 'CLOSED') this.setState('CLOSED');
    }

    failure() {
        this.failures += 1;
        if (this.state === 'HALF_OPEN' || this.failures >= this.failureThreshold) {
            this.openedAt = Date.now();
            this.setState('OPEN');
        }
    }
}

class UnavailableError extends Error {}

// Erros que indicam indisponibilidade do Redis (viram 503) e não falha da aplicação (500)
const isUnavailable = (err) => [UnavailableError, ClientClosedError, ClientOfflineError, SocketClosedUnexpectedlyError]
    .some(cls => err instanceof cls);

function withTimeout(promise, ms) {
    let timer;
    const timeout = new Promise((_, reject) => {
        timer = setTimeout(() => reject(new UnavailableError(`Redis não respondeu em ${ms}ms`)), ms);
    });
    return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function createRedisClient(config) {
    const failFast = config.mode !== 'baseline';
    return createClient({
        socket: {
            host: config.redisHost,
            port: config.redisPort,
            connectTimeout: 2000,
            // Tenta reconectar a cada 1 segundo indefinidamente
            reconnectStrategy: () => 1000,
        },
        password: config.redisPassword,
        // No modo baseline os comandos ficam retidos na fila até o Redis voltar (gera os timeouts do cliente)
        disableOfflineQueue: failFast,
    });
}

function createApp({ config = loadConfig(), redisClient = createRedisClient(config), register = new promClient.Registry() } = {}) {
    const app = express();
    app.use(express.json());

    // --- OBSERVABILIDADE (Prometheus) ---
    promClient.collectDefaultMetrics({ register });
    const httpRequests = new promClient.Counter({
        name: 'http_requests_total',
        help: 'Total de requisições HTTP',
        labelNames: ['method', 'route', 'status'],
        registers: [register],
    });
    const httpDuration = new promClient.Histogram({
        name: 'http_request_duration_seconds',
        help: 'Latência das requisições HTTP',
        labelNames: ['method', 'route', 'status'],
        buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
        registers: [register],
    });
    const redisUp = new promClient.Gauge({
        name: 'redis_up',
        help: '1 se o cliente Redis está pronto para receber comandos',
        registers: [register],
        collect() { this.set(redisClient.isReady ? 1 : 0); },
    });
    const breakerState = new promClient.Gauge({
        name: 'circuit_breaker_open',
        help: '0 = CLOSED, 0.5 = HALF_OPEN, 1 = OPEN',
        registers: [register],
    });
    void redisUp;

    const breaker = new CircuitBreaker({
        failureThreshold: config.breakerFailureThreshold,
        cooldownMs: config.breakerCooldownMs,
        onStateChange: (s) => breakerState.set({ CLOSED: 0, HALF_OPEN: 0.5, OPEN: 1 }[s]),
    });

    app.use((req, res, next) => {
        const end = httpDuration.startTimer();
        res.on('finish', () => {
            const labels = { method: req.method, route: req.route ? req.route.path : 'other', status: res.statusCode };
            httpRequests.inc(labels);
            end(labels);
        });
        next();
    });

    // O Redis está utilizável? baseline mantém o critério original (isOpen), que segue true durante a reconexão
    const redisAvailable = () => (config.mode === 'baseline' ? redisClient.isOpen : redisClient.isReady);

    // Executa um comando no Redis aplicando a política de resiliência do modo configurado
    async function runRedis(fn) {
        if (!redisAvailable()) throw new UnavailableError('Database unavailable');
        if (config.mode !== 'breaker') return fn();

        if (!breaker.canRequest()) throw new UnavailableError('Circuit breaker aberto');
        try {
            const result = await withTimeout(fn(), config.commandTimeoutMs);
            breaker.success();
            return result;
        } catch (err) {
            breaker.failure();
            throw isUnavailable(err) ? err : new UnavailableError(err.message);
        }
    }

    function handleError(res, error) {
        if (isUnavailable(error)) return res.status(503).json({ error: error.message });
        res.status(500).json({ error: error.message });
    }

    // --- ENDPOINTS DE CONFIABILIDADE (PROBES) ---

    // Liveness Probe: O processo está rodando?
    app.get('/health', (req, res) => {
        res.status(200).json({ status: 'UP', version: config.version, mode: config.mode, timestamp: new Date() });
    });

    // Readiness Probe: o Pod deve receber tráfego?
    app.get('/ready', (req, res) => {
        const redis = redisAvailable() ? 'CONNECTED' : 'DISCONNECTED';
        if (config.readinessDependsOnRedis && redis === 'DISCONNECTED') {
            // Retorna 503 para o K8s remover este pod do Service
            return res.status(503).json({ status: 'NOT READY', redis });
        }
        res.status(200).json({ status: 'READY', redis });
    });

    app.get('/version', (req, res) => {
        res.json({ version: config.version, build: config.build, mode: config.mode });
    });

    app.get('/metrics', async (req, res) => {
        res.set('Content-Type', register.contentType);
        res.end(await register.metrics());
    });

    // --- REGRAS DE NEGÓCIO ---

    // GET /tasks - Lista tarefas
    app.get('/tasks', async (req, res) => {
        try {
            const tasks = await runRedis(() => redisClient.lRange('tasks', 0, -1));
            res.json(tasks.map(t => JSON.parse(t)));
        } catch (error) {
            handleError(res, error);
        }
    });

    // POST /tasks - Cria tarefa
    app.post('/tasks', async (req, res) => {
        const { description } = req.body || {};
        if (!description) return res.status(400).json({ error: 'Description is required' });

        const task = {
            id: Date.now(),
            description,
            createdAt: new Date()
        };

        try {
            await runRedis(() => redisClient.rPush('tasks', JSON.stringify(task)));
            res.status(201).json(task);
        } catch (error) {
            handleError(res, error);
        }
    });

    return { app, redisClient, breaker, config };
}

module.exports = { createApp, createRedisClient, loadConfig, CircuitBreaker };

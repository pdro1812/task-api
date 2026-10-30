const { test, describe, before, after } = require('node:test');
const assert = require('node:assert');
const { createApp, loadConfig, CircuitBreaker } = require('../app');

// Os testes com Redis disponível usam REDIS_TEST_HOST/REDIS_TEST_PORT (no CI, um service container)
const REDIS_HOST = process.env.REDIS_TEST_HOST || 'localhost';
const REDIS_PORT = process.env.REDIS_TEST_PORT || '6379';
const DEAD_PORT = '1'; // nenhuma instância escuta aqui: simula o Redis fora do ar

async function start(env) {
    const config = loadConfig({ REDIS_HOST, REDIS_PORT, ...env });
    const ctx = createApp({ config });
    ctx.redisClient.on('error', () => {});
    // connect() só resolve quando conecta (o retry é infinito), então não esperamos quando o Redis está fora
    const connecting = ctx.redisClient.connect().catch(() => {});
    if (config.redisPort !== Number(DEAD_PORT)) await connecting;
    await new Promise(r => { ctx.server = ctx.app.listen(0, r); });
    ctx.url = `http://127.0.0.1:${ctx.server.address().port}`;
    return ctx;
}

async function stop(ctx) {
    ctx.server.close();
    if (ctx.redisClient.isReady) await ctx.redisClient.quit();
    else if (ctx.redisClient.isOpen) ctx.redisClient.destroy();
}

async function timed(url, opts) {
    const t0 = performance.now();
    const res = await fetch(url, { signal: AbortSignal.timeout(3000), ...opts });
    return { res, ms: performance.now() - t0 };
}

describe('com Redis disponível', () => {
    let ctx;
    before(async () => { ctx = await start({ RESILIENCE_MODE: 'failfast' }); });
    after(() => stop(ctx));

    test('/health e /ready respondem 200', async () => {
        assert.strictEqual((await fetch(`${ctx.url}/health`)).status, 200);
        assert.strictEqual((await fetch(`${ctx.url}/ready`)).status, 200);
    });

    test('POST e GET /tasks persistem no Redis', async () => {
        const post = await fetch(`${ctx.url}/tasks`, {
            method: 'POST', headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ description: 'teste' }),
        });
        assert.strictEqual(post.status, 201);
        const tasks = await (await fetch(`${ctx.url}/tasks`)).json();
        assert.ok(tasks.some(t => t.description === 'teste'));
    });

    test('POST sem description retorna 400', async () => {
        const res = await fetch(`${ctx.url}/tasks`, {
            method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}',
        });
        assert.strictEqual(res.status, 400);
    });

    test('/metrics expõe métricas no formato Prometheus', async () => {
        const body = await (await fetch(`${ctx.url}/metrics`)).text();
        assert.match(body, /http_requests_total/);
        assert.match(body, /redis_up 1/);
    });
});

describe('com Redis indisponível', () => {
    for (const mode of ['failfast', 'breaker']) {
        test(`modo ${mode}: /tasks responde 503 rápido (fail-fast)`, async () => {
            const ctx = await start({ RESILIENCE_MODE: mode, REDIS_PORT: DEAD_PORT });
            try {
                const { res, ms } = await timed(`${ctx.url}/tasks`);
                assert.strictEqual(res.status, 503);
                assert.ok(ms < 500, `levou ${ms}ms`);
            } finally { await stop(ctx); }
        });
    }

    test('readiness só falha quando READINESS_DEPENDS_ON_REDIS=true', async () => {
        const a = await start({ REDIS_PORT: DEAD_PORT });
        const b = await start({ REDIS_PORT: DEAD_PORT, READINESS_DEPENDS_ON_REDIS: 'true' });
        try {
            assert.strictEqual((await fetch(`${a.url}/ready`)).status, 200);
            assert.strictEqual((await fetch(`${b.url}/ready`)).status, 503);
            assert.strictEqual((await fetch(`${b.url}/health`)).status, 200);
        } finally { await stop(a); await stop(b); }
    });
});

describe('CircuitBreaker', () => {
    test('abre após N falhas, vai para HALF_OPEN após o cooldown e fecha no sucesso', async () => {
        const cb = new CircuitBreaker({ failureThreshold: 2, cooldownMs: 50 });
        cb.failure();
        assert.strictEqual(cb.state, 'CLOSED');
        cb.failure();
        assert.strictEqual(cb.state, 'OPEN');
        assert.strictEqual(cb.canRequest(), false);
        await new Promise(r => setTimeout(r, 60));
        assert.strictEqual(cb.canRequest(), true);
        assert.strictEqual(cb.state, 'HALF_OPEN');
        cb.success();
        assert.strictEqual(cb.state, 'CLOSED');
    });

    test('falha em HALF_OPEN reabre o circuito', async () => {
        const cb = new CircuitBreaker({ failureThreshold: 5, cooldownMs: 10 });
        for (let i = 0; i < 5; i++) cb.failure();
        await new Promise(r => setTimeout(r, 20));
        cb.canRequest();
        cb.failure();
        assert.strictEqual(cb.state, 'OPEN');
    });
});

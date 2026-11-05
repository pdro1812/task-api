// Carga constante contra a Task API (usada nos cenários de rolling update e queda do Redis).
// Uso: k6 run -e BASE_URL=http://localhost:8080 -e RATE=50 -e DURATION=120s \
//        --out csv=results/<cenario>-<rodada>.csv experiments/k6/carga-constante.js
import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
    scenarios: {
        constante: {
            executor: 'constant-arrival-rate',
            rate: Number(__ENV.RATE || 50),
            timeUnit: '1s',
            duration: __ENV.DURATION || '120s',
            preAllocatedVUs: Number(__ENV.PRE_VUS || 50),
            maxVUs: Number(__ENV.MAX_VUS || 500),
        },
    },
    // NO_REUSE=1: cada requisição abre uma conexão TCP nova (cliente sem keep-alive)
    noConnectionReuse: __ENV.NO_REUSE === '1',
    summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
    // O timeout do cliente fica explícito para que "requisição retida" seja mensurável
    const res = http.get(`${BASE_URL}/tasks`, { timeout: __ENV.TIMEOUT || '5s', tags: { name: 'GET /tasks' } });
    check(res, {
        'status 200': (r) => r.status === 200,
        'status 503 (fail-fast)': (r) => r.status === 503,
        'sem resposta (timeout/conexão)': (r) => r.status === 0,
    });
}

// Opções comuns: carga em malha aberta (constant-arrival-rate), para que a cauda não seja escondida por
// coordinated omission. RATE em req/s, DURATION como "180s".
export function options() {
    return {
        scenarios: {
            carga: {
                executor: 'constant-arrival-rate',
                rate: Number(__ENV.RATE || 100),
                timeUnit: '1s',
                duration: __ENV.DURATION || '180s',
                preAllocatedVUs: Number(__ENV.PRE_VUS || 200),
                maxVUs: Number(__ENV.MAX_VUS || 2000),
            },
        },
        discardResponseBodies: true,
        summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(99)', 'p(99.9)', 'max'],
    };
}
export const BASE = __ENV.BASE_URL;
export const TIMEOUT = __ENV.TIMEOUT || '10s';
// Resumo em JSON no arquivo SUMMARY (formato do handleSummary: métricas em .metrics.<nome>.values)
export function handleSummary(data) {
    return __ENV.SUMMARY ? { [__ENV.SUMMARY]: JSON.stringify(data) } : {};
}

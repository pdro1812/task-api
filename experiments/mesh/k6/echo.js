// Microbenchmark: k6 -> relay (fortio, pod de borda) -> echo. Corpo de resposta de PAYLOAD bytes.
import http from 'k6/http';
import { check } from 'k6';
import { options as opts, BASE, TIMEOUT } from './common.js';
export const options = opts();
export { handleSummary } from './common.js';
const SIZE = __ENV.PAYLOAD || '1024';
export default function () {
    const r = http.get(`${BASE}/echo?size=${SIZE}`, { timeout: TIMEOUT, tags: { name: 'echo' } });
    check(r, { '200': (x) => x.status === 200 });
}

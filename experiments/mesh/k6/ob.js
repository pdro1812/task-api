// Online Boutique: navegação típica (página inicial, produto, troca de moeda, carrinho).
import http from 'k6/http';
import { check } from 'k6';
import { options as opts, BASE, TIMEOUT } from './common.js';
export const options = opts();
export { handleSummary } from './common.js';
const PRODUCTS = ['0PUK6V6EV0', '1YMWWN1N4O', '2ZYFJ3GM2N', '66VCHSJNUP', '6E92ZMYYFZ',
                  '9SIQT8TOJO', 'L9ECAV7KIM', 'LS4PSXUNUM', 'OLJCESPC7Z'];
const pick = (a) => a[Math.floor(Math.random() * a.length)];
export default function () {
    const p = Math.random();
    let r;
    if (p < 0.3) {
        r = http.get(`${BASE}/`, { timeout: TIMEOUT, tags: { name: 'home' } });
    } else if (p < 0.8) {
        r = http.get(`${BASE}/product/${pick(PRODUCTS)}`, { timeout: TIMEOUT, tags: { name: 'product' } });
    } else if (p < 0.9) {
        r = http.post(`${BASE}/setCurrency`, { currency_code: pick(['EUR', 'USD', 'JPY', 'CAD']) },
                      { timeout: TIMEOUT, redirects: 0, tags: { name: 'currency' } });
    } else {
        r = http.get(`${BASE}/cart`, { timeout: TIMEOUT, tags: { name: 'cart' } });
    }
    check(r, { 'ok': (x) => x.status === 200 || x.status === 302 });
}

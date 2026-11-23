// Hotel Reservation: mistura do DeathStarBench (60% busca, 39% recomendação, 0,5% login, 0,5% reserva).
import http from 'k6/http';
import { check } from 'k6';
import { options as opts, BASE, TIMEOUT } from './common.js';
export const options = opts();
export { handleSummary } from './common.js';
const rnd = (a, b) => a + Math.random() * (b - a);
const pad = (n) => String(n).padStart(2, '0');
function user() {
    const id = Math.floor(Math.random() * 500);
    return { username: `Cornell_${id}`, password: String(id).repeat(10) };
}
export default function () {
    const p = Math.random();
    const lat = (38.0235 + rnd(-0.25, 0.25)).toFixed(4);
    const lon = (-122.095 + rnd(-0.25, 0.25)).toFixed(4);
    const d = 9 + Math.floor(Math.random() * 14);
    const inDate = `2015-04-${pad(d)}`, outDate = `2015-04-${pad(d + 1 + Math.floor(Math.random() * 5))}`;
    let r;
    if (p < 0.6) {
        r = http.get(`${BASE}/hotels?inDate=${inDate}&outDate=${outDate}&lat=${lat}&lon=${lon}`,
                     { timeout: TIMEOUT, tags: { name: 'search' } });
    } else if (p < 0.99) {
        const req = ['dis', 'rate', 'price'][Math.floor(Math.random() * 3)];
        r = http.get(`${BASE}/recommendations?require=${req}&lat=${lat}&lon=${lon}`,
                     { timeout: TIMEOUT, tags: { name: 'recommend' } });
    } else if (p < 0.995) {
        const u = user();
        r = http.post(`${BASE}/user?username=${u.username}&password=${u.password}`, null,
                      { timeout: TIMEOUT, tags: { name: 'login' } });
    } else {
        const u = user();
        const hotel = 1 + Math.floor(Math.random() * 80);
        r = http.post(`${BASE}/reservation?inDate=${inDate}&outDate=${outDate}&lat=${lat}&lon=${lon}` +
                      `&hotelId=${hotel}&customerName=${u.username}&username=${u.username}&password=${u.password}&number=1`,
                      null, { timeout: TIMEOUT, tags: { name: 'reserve' } });
    }
    check(r, { '200': (x) => x.status === 200 });
}

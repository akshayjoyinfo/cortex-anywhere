// k6 smoke against dev after deploy. Targets from docs/02-nfr.md.
// Run: k6 run -e BASE=https://app.dev.cortex.example -e TOKEN=... tests/perf/smoke.js
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  vus: 10,
  duration: '1m',
  thresholds: { http_req_duration: ['p(95)<300'], http_req_failed: ['rate<0.01'] },
};

export default function () {
  const res = http.get(`${__ENV.BASE}/api/whoami`, { headers: { Authorization: `Bearer ${__ENV.TOKEN}` } });
  check(res, { 'status 200': (r) => r.status === 200 });
}

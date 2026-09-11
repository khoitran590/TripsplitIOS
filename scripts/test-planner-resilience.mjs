// Node 24 can run the production TypeScript with type stripping. No network or keys.
import assert from 'node:assert/strict';
let handler;
const env = { SUPABASE_URL: 'https://test.invalid', SUPABASE_ANON_KEY: 'test',
  SUPABASE_SERVICE_ROLE_KEY: 'test', ANTHROPIC_API_KEY: 'test', GEMINI_API_KEY: 'test' };
globalThis.Deno = { env: { get: key => env[key] }, serve: value => { handler = value; } };
await import('../supabase/functions/suggest-itinerary/index.ts');
const plan = { destinationArea: 'Paris, France', days: [{ title: 'Paris', stops: [
  { kind: 'activity', name: 'Louvre', area: 'Paris', time: '09:00', notes: '', cost: 20 }
] }] };
let mode, calls;
globalThis.fetch = async (url, options) => {
  assert.ok(options.signal instanceof AbortSignal, 'Every upstream request needs a deadline');
  calls.push(url);
  if (mode === 'auth-timeout' || (mode === 'providers-timeout' && !url.startsWith(env.SUPABASE_URL))) {
    throw new DOMException('Simulated timeout', 'TimeoutError');
  }
  if (url.endsWith('/user')) return Response.json({ id: 'user' });
  if (url.endsWith('/has_ai_consent') || url.endsWith('/complete_ai_usage')) return Response.json(true);
  if (url.endsWith('/reserve_ai_usage')) return Response.json({ allowed: true, reservation_id: 'reservation', reservationId: 'reservation' });
  if (url.includes('anthropic.com')) throw new DOMException('Simulated timeout', 'TimeoutError');
  return Response.json({ candidates: [{ content: { parts: [{ text: JSON.stringify(plan) }] } }] });
};
for (const [scenario, status] of [['auth-timeout', 503], ['fallback-success', 200], ['providers-timeout', 504]]) {
  mode = scenario; calls = [];
  const response = await handler(new Request('https://test.invalid/planner', {
    method: 'POST', headers: { Authorization: 'Bearer test', 'Content-Type': 'application/json' },
    body: JSON.stringify({ location: 'Paris', days: 1, currency: 'EUR' })
  }));
  assert.equal(response.status, status, scenario);
  const body = await response.json();
  if (status === 200) assert.equal(body.days[0].stops[0].name, 'Louvre');
  else assert.equal(typeof body.error, 'string');
  if (scenario === 'auth-timeout') assert.equal(calls.length, 1);
  console.log(`PASS ${scenario}`);
}

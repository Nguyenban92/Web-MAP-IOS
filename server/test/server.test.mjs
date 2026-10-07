import test from 'node:test';
import assert from 'node:assert/strict';
import { createApp, parsePublisherKeys } from '../server.mjs';
const key = 'test-only-long-admin-key-123456789';
async function fixture(t, opts = {}) {
  const app = createApp({ adminKey: key, publicURL: 'https://map.example.com', ...opts });
  await new Promise(resolve => app.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { app.close(resolve); app.closeAllConnections(); }));
  const base = `http://127.0.0.1:${app.address().port}`;
  const call = (path, method = 'GET', auth = '', data, type = 'application/json') => fetch(base + path, { method, headers: { Authorization: `Bearer ${auth}`, 'Content-Type': type }, body: data });
  const create = async (password = '') => { const r = await call('/api/rooms', 'POST', key, JSON.stringify({ password })); assert.equal(r.status, 201); return r.json(); };
  const view = async (room, password = '') => { const r = await call(`/api/rooms/${room.id}/access`, 'POST', room.viewerURL.split('#')[1].split('.')[1], JSON.stringify({ password })); return r; };
  return { call, create, view };
}
test('create requires admin; protected viewer, independent rooms, close revokes access', async t => {
  const { call, create, view } = await fixture(t);
  assert.equal((await call('/api/rooms', 'POST', 'wrong', '{}')).status, 401);
  const r = await create('secret'), other = await create();
  assert.equal((await view(r, 'wrong')).status, 403);
  const access = await (await view(r, 'secret')).json();
  const path = `/api/rooms/${r.id}/frame`;
  assert.equal((await call(path, 'GET', r.publishToken)).status, 401);
  assert.equal((await call(path, 'GET', access.token)).status, 204);
  assert.equal((await call(`/api/rooms/${other.id}/frame`, 'GET', access.token)).status, 401);
  assert.equal((await call(path, 'POST', r.publishToken, 'no', 'image/jpeg')).status, 400);
  const jpeg = Buffer.from([255,216,0,1,255,217]);
  assert.equal((await call(path, 'POST', r.publishToken, jpeg, 'image/jpeg')).status, 204);
  const frame = await call(path, 'GET', access.token);
  assert.equal(frame.status, 200); assert.equal(frame.headers.get('cache-control'), 'no-store');
  assert.deepEqual(Buffer.from(await frame.arrayBuffer()), jpeg);
  assert.equal((await call(`/api/rooms/${r.id}`, 'DELETE', other.publishToken)).status, 401);
  assert.equal((await call(`/api/rooms/${r.id}`, 'DELETE', r.publishToken)).status, 204);
  assert.equal((await call(path, 'GET', access.token)).status, 404);
  assert.equal((await call(path, 'POST', r.publishToken, jpeg, 'image/jpeg')).status, 404);
});
test('active room has no fixed lifetime, stale publisher expires after three minutes, startup grace expires', async t => {
  let clock = 100000;
  const { call, create, view } = await fixture(t, { now: () => clock });
  const r = await create();
  const access = await (await view(r)).json();
  const path = `/api/rooms/${r.id}/frame`;
  assert.equal((await call(path, 'POST', r.publishToken, Buffer.from([255,216,255,217]), 'image/jpeg')).status, 204);
  clock += 10001;
  assert.equal((await call(path, 'GET', access.token)).status, 204);
  // A room can remain live well beyond the old two-hour cap while the
  // publisher continues to heartbeat.
  assert.equal((await call(`/api/rooms/${r.id}/rtc?slot=0`, 'GET', r.publishToken)).status, 200);
  for (let i = 0; i < 130; i++) {
    clock += 60 * 1000;
    assert.equal((await call(`/api/rooms/${r.id}/rtc?slot=0`, 'GET', r.publishToken)).status, 200);
  }
  clock += 180001;
  assert.equal((await call(path, 'GET', access.token)).status, 404);
  const neverStarted = await create(); clock += 600001;
  assert.equal((await view(neverStarted)).status, 404);
});
test('payload limits, MIME and web headers', async t => {
  const { call, create } = await fixture(t);
  const r = await create();
  const p = `/api/rooms/${r.id}/frame`;
  assert.equal((await call(p, 'POST', r.publishToken, '{}')).status, 415);
  assert.equal((await call(p, 'POST', r.publishToken, Buffer.alloc(512*1024+1), 'image/jpeg')).status, 413);
  const page = await call('/'); assert.equal(page.status, 200);
  assert.match(page.headers.get('content-security-policy'), /frame-ancestors 'none'/);
  assert.equal((await call('/../server.mjs')).status, 404);
});
test('separate publisher keys create isolated single active rooms', async t => {
  const alice = 'alice-private-publisher-key-123456', bob = 'bob-private-publisher-key-12345678';
  const { call } = await fixture(t, { publisherKeys: `alice=${alice};bob=${bob}` });
  const make = auth => call('/api/rooms', 'POST', auth, JSON.stringify({ password: '' }));
  const first = await make(alice); assert.equal(first.status, 201);
  const room = await first.json();
  assert.equal((await make(alice)).status, 409);
  assert.equal((await make(bob)).status, 201);
  assert.equal((await make(key)).status, 201); // master ADMIN_KEY remains valid
  assert.equal((await call(`/api/rooms/${room.id}`, 'DELETE', room.publishToken)).status, 204);
  assert.equal((await make(alice)).status, 201);
  assert.throws(() => parsePublisherKeys('bad=x'), /at least 24/);
  assert.throws(() => parsePublisherKeys(`same=${alice};same=${bob}`), /duplicate/);
});

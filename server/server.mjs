import { createRTC } from './rtc.mjs';
import http from 'node:http';
import { randomBytes, scrypt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const derive = promisify(scrypt);
const token = () => randomBytes(24).toString('base64url');
const same = (a, b) => typeof a === 'string' && typeof b === 'string' && Buffer.byteLength(a) === Buffer.byteLength(b) && timingSafeEqual(Buffer.from(a), Buffer.from(b));
const bearer = req => req.headers.authorization?.replace(/^Bearer /, '') || '';
const fail = (status, message) => Object.assign(new Error(message), { status });
async function body(req, max) {
  const chunks = []; let size = 0;
  for await (const chunk of req) { size += chunk.length; if (size > max) throw fail(413, 'Payload too large'); chunks.push(chunk); }
  return Buffer.concat(chunks);
}
export function createApp({ adminKey, publicURL, now = Date.now, roomTTL = 7200000, lease = 90000, startupLease = 600000, iceServers, turnURLs, turnSecret } = {}) {
  if (!adminKey || adminKey.length < 24) throw Error('ADMIN_KEY must contain at least 24 characters');
  const base = new URL(publicURL);
  if (base.protocol !== 'https:' || base.pathname !== '/' || base.search || base.hash || base.username || base.password) throw Error('PUBLIC_URL must be an HTTPS origin');
  const rooms = new Map(), rates = new Map(), pairs = new Map();
  const assets = new Map([
    ['/', ['index.html', 'text/html; charset=utf-8']],
    ['/viewer.js', ['viewer.js', 'text/javascript; charset=utf-8']],
    ['/style.css', ['style.css', 'text/css; charset=utf-8']]
  ]);
  function expired(room) { const publisher=Math.max(0,...(room.rtcSlots||[]).map(x=>x.publisherAt||0));return now()-room.created>roomTTL||(Math.max(room.lastFrame,publisher)?now()-Math.max(room.lastFrame,publisher)>lease:now()-room.created>startupLease); }
  function cleanup() {
    for (const [id, r] of rooms) {
      if (expired(r)) rooms.delete(id);
      else if (now() - r.lastFrame > 10000) r.frame = null;
    }
    for (const [key, value] of pairs) if (now() > value.until || !rooms.has(value.id)) pairs.delete(key);
    for (const [key, value] of rates) if (now() >= value.until) rates.delete(key);
  }
  const interval = setInterval(cleanup, 5000); interval.unref();
  function limited(key, cap, period) {
    if (!rates.has(key) && rates.size >= 10000) throw fail(503, 'Busy');
    let r = rates.get(key);
    if (!r || now() >= r.until) { r = { count: 0, until: now() + period }; rates.set(key, r); }
    if (++r.count > cap) throw fail(429, 'Too many attempts');
  }
  const rtc = createRTC({now,fail,limited,iceServers,turnURLs,turnSecret});
  const server = http.createServer(async (req, res) => {
    const send = (status, value) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(value ? JSON.stringify(value) : undefined); };
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Content-Security-Policy', "default-src 'self'; img-src 'self' blob:; script-src 'self'; style-src 'self'; connect-src 'self'; media-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
    try {
      const path = new URL(req.url, 'http://localhost').pathname;
      if (req.method === 'GET' && assets.has(path)) {
        const [name, type] = assets.get(path); res.setHeader('Content-Type', type);
        res.end(await readFile(new URL(`public/${name}`, import.meta.url))); return;
      }
      if (path === '/health' && req.method === 'GET') { send(200, { ok: true }); return; }
      if (path === '/api/rooms' && req.method === 'POST') {
        limited('create:' + req.socket.remoteAddress, 20, 60000);
        if (!same(bearer(req), adminKey)) throw fail(401, 'Unauthorized');
        cleanup(); if (rooms.size >= 25) throw fail(503, 'Room limit reached');
        let input; try { input = JSON.parse((await body(req, 2048)).toString()); } catch (e) { throw e.status ? e : fail(400, 'Invalid JSON'); }
        if (typeof input?.password !== 'string' || input.password.length > 128) throw fail(400, 'Invalid password');
        const salt = randomBytes(16);
        const hash = input.password ? await derive(input.password, salt, 32) : null;
        const id = randomBytes(6).toString('hex').toUpperCase();
        const publishToken = token(), viewToken = token();
        rooms.set(id, { publishToken, viewToken, salt, hash, created: now(), lastFrame: 0, frame: null, seq: 0, grants: new Set() });
        send(201, { id, publishToken, viewerURL: `${base.origin}/#${id}.${viewToken}` }); return;
      }
      if (path === '/api/pair' && req.method === 'POST') {
        limited('pair:' + req.socket.remoteAddress, 60, 60000);
        const key = bearer(req), pair = pairs.get(key);
        if (!pair || now() > pair.until) { pairs.delete(key); throw fail(404, 'Pair expired'); }
        const r = rooms.get(pair.id);
        if (!r || expired(r)) { pairs.delete(key); throw fail(404, 'Room closed'); }
        pairs.delete(key); r.paired = true;
        send(200, pair.config); return;
      }
      const match = /^\/api\/rooms\/([A-F0-9]{12})(?:\/(frame|access|pair|status|rtc))?$/.exec(path);
      if (!match) throw fail(404, 'Not found');
      const [, id, action] = match;
      const room = rooms.get(id);
      if (!room || expired(room)) { rooms.delete(id); throw fail(404, 'Room closed'); }
      if (action === 'rtc') {
        const key = bearer(req);
        if (!same(key,room.publishToken) && !room.grants.has(key)) throw fail(401,'Unauthorized');
        let input;
        if (req.method === 'POST') {
          try { input = JSON.parse((await body(req, 70000)).toString()); } catch(e) { throw e.status ? e : fail(400,'Invalid JSON'); }
        }
        if (rooms.get(id)!==room || expired(room)) throw fail(404,'Room closed');
        const slot = new URL(req.url, 'http://localhost').searchParams.get('slot');
        send(200,rtc(room,id,key,req.method,input,slot));return;
      }
      if (action === 'status' && req.method === 'GET') {
        if (!same(bearer(req), room.publishToken)) throw fail(401, 'Unauthorized');
        const slots=room.rtcSlots||[], viewers=slots.filter(x=>x.viewer&&now()-x.viewerAt<25000).length, live=slots.filter(x=>x.answer&&now()-x.publisherAt<15000).length;
        send(200, { paired: !!room.paired, live: live>0, viewer: viewers>0, viewers, liveViewers:live, maxViewers:4, publisherOnline:slots.some(x=>x.publisherAt&&now()-x.publisherAt<15000) }); return;
      }
      if (action === 'pair' && req.method === 'POST') {
        if (!same(bearer(req), room.publishToken)) throw fail(401, 'Unauthorized');
        limited('pair-create:' + id, 10, 60000);
        let c; try { c = JSON.parse((await body(req, 4096)).toString()); } catch(e) { throw e.status ? e : fail(400,'Invalid JSON'); }
        const v = c?.crop;
        if (!v || !['x','y','width','height','referenceAspect'].every(k => Number.isFinite(v[k])) ||
            v.x < 0 || v.y < 0 || v.width < 0.02 || v.height < 0.02 || v.x + v.width > 1.001 || v.y + v.height > 1.001 ||
            v.referenceAspect <= 0 || !Number.isFinite(c.fps) || c.fps < 1 || c.fps > 60 ||
            !Number.isFinite(c.quality) || c.quality < 0.3 || c.quality > 0.9) throw fail(400,'Invalid crop or quality');
        if (rooms.get(id) !== room || expired(room)) throw fail(404,'Room closed');
        for (const [k,p] of pairs) if (p.id === id) pairs.delete(k);
        const key = token();
        const config = { server: base.origin, room: { id, publishToken: room.publishToken, viewerURL: `${base.origin}/#${id}.${room.viewToken}` }, crop: v, fps: c.fps, quality: c.quality, enabled: true };
        pairs.set(key, { id, config, until: now() + 90000 }); room.paired = false;
        send(201, { pairURL: `${base.origin}/#pair.${key}` }); return;
      }
      if (!action && req.method === 'DELETE') {
        if (!same(bearer(req), room.publishToken)) throw fail(401, 'Unauthorized');
        rooms.delete(id); send(204); return;
      }
      if (action === 'access' && req.method === 'POST') {
        limited('access:' + id, 40, 60000);
        if (!same(bearer(req), room.viewToken)) throw fail(401, 'Invalid viewing link');
        let input; try { input = JSON.parse((await body(req, 2048)).toString()); } catch (e) { throw e.status ? e : fail(400, 'Invalid JSON'); }
        if (typeof input?.password !== 'string' || input.password.length > 128) throw fail(400, 'Invalid password');
        if (room.hash) {
          const candidate = await derive(input.password, room.salt, 32);
          if (!timingSafeEqual(candidate, room.hash)) throw fail(403, 'Password required or incorrect');
        }
        if (rooms.get(id)!==room || expired(room)) throw fail(404,'Room closed');
        if (room.grants.size >= 100) throw fail(429, 'Viewer limit reached');
        const session = token(); room.grants.add(session); send(200, { token: session }); return;
      }
      if (action === 'frame' && req.method === 'POST') {
        if (!same(bearer(req), room.publishToken)) throw fail(401, 'Unauthorized');
        limited('frame:' + id, 15, 1000);
        if (req.headers['content-type'] !== 'image/jpeg') throw fail(415, 'JPEG required');
        const data = await body(req, 512 * 1024);
        if (data.length < 4 || data[0] !== 0xff || data[1] !== 0xd8 || data.at(-2) !== 0xff || data.at(-1) !== 0xd9) throw fail(400, 'Invalid JPEG');
        // Recheck after the await: a concurrent close must not revive the room.
        if (rooms.get(id) !== room || expired(room)) throw fail(404, 'Room closed');
        room.frame = data; room.lastFrame = now(); room.seq++;
        send(204); return;
      }
      if (action === 'frame' && req.method === 'GET') {
        if (!room.grants.has(bearer(req))) throw fail(401, 'Unauthorized');
        limited('get:' + id + ':' + bearer(req), 15, 1000);
        if (!room.frame || now() - room.lastFrame > 10000) { send(204); return; }
        res.setHeader('X-Frame-Sequence', String(room.seq));
        res.setHeader('X-Frame-Age', String(now() - room.lastFrame));
        res.setHeader('Content-Type', 'image/jpeg'); res.end(room.frame); return;
      }
      throw fail(405, 'Method not allowed');
    } catch (e) {
      if (!res.headersSent && !res.destroyed) send(e.status || 500, { error: e.status ? e.message : 'Server error' });
    }
  });
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  server.on('close', () => clearInterval(interval));
  return server;
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const app = createApp({ adminKey: process.env.ADMIN_KEY, publicURL: process.env.PUBLIC_URL, iceServers: process.env.ICE_SERVERS_JSON ? JSON.parse(process.env.ICE_SERVERS_JSON) : undefined, turnURLs: process.env.TURN_URLS?.split(',').filter(Boolean), turnSecret: process.env.TURN_SECRET });
  app.listen(Number(process.env.PORT || 8080), '0.0.0.0', () => console.log('NB Web Map listening'));
}

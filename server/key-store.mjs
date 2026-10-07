import { randomBytes, timingSafeEqual } from 'node:crypto';

const safeEqual = (a, b) => typeof a === 'string' && typeof b === 'string' &&
  Buffer.byteLength(a) === Buffer.byteLength(b) && timingSafeEqual(Buffer.from(a), Buffer.from(b));
const validDate = value => value === '' || /^\d{4}-\d{2}-\d{2}$/.test(value) && !Number.isNaN(Date.parse(`${value}T00:00:00Z`));

export function createKeyStore({ url, secret, now = Date.now, fetchImpl = fetch } = {}) {
  if (!url) return null;
  const endpoint = new URL(url);
  if (endpoint.protocol !== 'https:') throw Error('KEY_STORE_URL must use HTTPS');
  if (!secret || secret.length < 24) throw Error('KEY_STORE_SECRET must contain at least 24 characters');
  let cache = null, cacheUntil = 0;

  async function request(action, payload = {}) {
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 8000);
    try {
      const response = await fetchImpl(endpoint, {
        method: 'POST', redirect: 'follow', signal: controller.signal,
        headers: { 'Content-Type': 'text/plain;charset=utf-8' },
        body: JSON.stringify({ secret, action, payload })
      });
      const value = await response.json().catch(() => ({}));
      if (!response.ok || value.ok !== true) throw Error(value.error || `Key store HTTP ${response.status}`);
      return value;
    } finally { clearTimeout(timer); }
  }
  async function list(force = false) {
    if (!force && cache && now() < cacheUntil) return cache;
    const value = await request('list');
    cache = Array.isArray(value.keys) ? value.keys : [];
    cacheUntil = now() + 15000;
    return cache;
  }
  const expires = date => date && now() > Date.parse(`${date}T23:59:59+07:00`);
  return {
    async list(force = false) { return list(force); },
    async authorize(key) {
      const item = (await list()).find(x => x.enabled === true && !expires(x.expiresAt) && safeEqual(x.key, key));
      return item ? { id: `sheet:${item.id}`, admin: false, record: item } : null;
    },
    async create({ name, note = '', expiresAt = '' }) {
      name = String(name || '').trim(); note = String(note || '').trim(); expiresAt = String(expiresAt || '').trim();
      if (!name || name.length > 80 || note.length > 200 || !validDate(expiresAt)) throw Object.assign(new Error('Invalid key details'), { status: 400 });
      const payload = { id: randomBytes(8).toString('hex'), name, note, expiresAt, enabled: true, key: `NB-${randomBytes(24).toString('base64url')}` };
      const value = await request('create', payload); cache = null; return value.key;
    },
    async update(id, changes) {
      id = String(id || ''); if (!/^[a-f0-9]{16}$/.test(id)) throw Object.assign(new Error('Invalid key id'), { status: 400 });
      const payload = { id };
      if ('name' in changes) { payload.name = String(changes.name).trim(); if (!payload.name || payload.name.length > 80) throw Object.assign(new Error('Invalid name'), { status: 400 }); }
      if ('note' in changes) { payload.note = String(changes.note).trim(); if (payload.note.length > 200) throw Object.assign(new Error('Invalid note'), { status: 400 }); }
      if ('expiresAt' in changes) { payload.expiresAt = String(changes.expiresAt).trim(); if (!validDate(payload.expiresAt)) throw Object.assign(new Error('Invalid expiry date'), { status: 400 }); }
      if ('enabled' in changes) payload.enabled = changes.enabled === true;
      const value = await request('update', payload); cache = null; return value.key;
    },
    async remove(id) {
      id = String(id || ''); if (!/^[a-f0-9]{16}$/.test(id)) throw Object.assign(new Error('Invalid key id'), { status: 400 });
      await request('delete', { id }); cache = null;
    }
  };
}

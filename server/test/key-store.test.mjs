import test from 'node:test';
import assert from 'node:assert/strict';
import { createKeyStore } from '../key-store.mjs';

test('managed key store handles active, disabled and expired keys', async () => {
  let keys = [
    {id:'1111111111111111',name:'Active',key:'NB-active-key-123456789012345678',enabled:true,expiresAt:'2030-01-01'},
    {id:'2222222222222222',name:'Disabled',key:'NB-disabled-key-1234567890123456',enabled:false,expiresAt:''},
    {id:'3333333333333333',name:'Expired',key:'NB-expired-key-12345678901234567',enabled:true,expiresAt:'2020-01-01'}
  ];
  const fetchImpl = async (_url, options) => {
    const request = JSON.parse(options.body);
    return { ok:true, json:async()=> request.action==='list' ? {ok:true,keys} : {ok:true,key:request.payload} };
  };
  const store = createKeyStore({url:'https://script.google.com/macros/s/test/exec',secret:'store-secret-123456789012345678',now:()=>1700000000000,fetchImpl});
  assert.equal((await store.authorize(keys[0].key)).id,'sheet:1111111111111111');
  assert.equal(await store.authorize(keys[1].key),null);
  assert.equal(await store.authorize(keys[2].key),null);
  const created=await store.create({name:'New',note:'Test',expiresAt:''});
  assert.match(created.key,/^NB-/);
});

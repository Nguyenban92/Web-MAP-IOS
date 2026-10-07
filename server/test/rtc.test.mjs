import test from 'node:test';
import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import {createRTC} from '../rtc.mjs';
function setup(options={}){
 let clock=100000;const room={publishToken:'publisher',grants:new Set(['viewer','other'])};
 const rtc=createRTC({now:()=>clock,fail:(status,message)=>Object.assign(new Error(message),{status}),limited:()=>{},...options});
 const call=(key='publisher',body)=>rtc(room,'room',key,body?'POST':'GET',body);
 return {call,room,advance:n=>clock+=n};
}
const fails=(f,status)=>assert.throws(f,e=>e.status===status);
test('RTC role authorization, single viewer and isolated credentials',()=>{
 const {call}=setup();fails(()=>call('unknown'),401);fails(()=>call('viewer'),409);
 const s=call('viewer',{op:'join'});assert.equal(s.viewer,true);
 fails(()=>call('other',{op:'join'}),409);fails(()=>call('other'),409);
 fails(()=>call('viewer',{op:'offer',epoch:s.epoch,sdp:'v=0\r\n'}),403);
 fails(()=>call('publisher',{op:'answer',epoch:s.epoch,sdp:'v=0\r\n'}),403);
 assert.equal(call('other',{op:'leave'}).closed,true);assert.equal(call().viewer,true);
 call('viewer',{op:'leave'});assert.equal(call().viewer,false);
});
test('RTC SDP idempotency, stale generations and directional ICE candidates',()=>{
 const {call}=setup();const {epoch}=call('viewer',{op:'join'});
 fails(()=>call('viewer',{op:'answer',epoch,sdp:'v=0 answer'}),409);
 call('publisher',{op:'offer',epoch,sdp:'v=0 offer'});call('publisher',{op:'offer',epoch,sdp:'v=0 offer'});
 fails(()=>call('publisher',{op:'offer',epoch,sdp:'v=0 changed'}),409);
 call('viewer',{op:'answer',epoch,sdp:'v=0 answer'});
 const candidate={sdp:'candidate:1 1 udp 123 127.0.0.1 1234 typ host',sdpMid:'0',sdpMLineIndex:0};
 call('publisher',{op:'candidate',epoch,candidate});call('publisher',{op:'candidate',epoch,candidate});
 assert.equal(call('viewer').candidates.length,1);assert.equal(call().candidates.length,0);
 const next=call('publisher',{op:'reset'});assert.ok(next.epoch>epoch);assert.equal(next.answer,null);assert.equal(call('viewer').candidates.length,0);
 fails(()=>call('viewer',{op:'candidate',epoch,candidate}),409);
 fails(()=>call('publisher',{op:'offer',epoch:next.epoch,sdp:'x'.repeat(65537)}),400);
});
test('RTC expired viewer lease clears video state and permits replacement',()=>{
 const {call,advance}=setup();const {epoch}=call('viewer',{op:'join'});
 call('publisher',{op:'offer',epoch,sdp:'v=0 offer'});advance(25001);
 const next=call('other',{op:'join'});assert.ok(next.epoch>epoch);assert.equal(next.offer,null);
 fails(()=>call('viewer'),409);assert.equal(next.publisherOnline,false);
 assert.equal(call().publisherOnline,true);
});
test('RTC TURN credentials are temporary HMAC credentials without secret disclosure',()=>{
 const secret='private-turn-secret';const {call,advance}=setup({turnURLs:['turn:relay.example.com:3478'],turnSecret:secret});
 const s=call();assert.equal(s.relayAvailable,true);const ice=s.iceServers.at(-1);
 assert.equal(ice.credential,createHmac('sha1',secret).update(ice.username).digest('base64'));
 assert.ok(!JSON.stringify(s).includes(secret));advance(1000);assert.notEqual(call().iceServers.at(-1).username,ice.username);
});
test('RTC validates and bounds candidate storage',()=>{
 const {call}=setup();const {epoch}=call('viewer',{op:'join'});
 fails(()=>call('publisher',{op:'candidate',epoch,candidate:{sdp:'bad',sdpMid:null,sdpMLineIndex:0}}),400);
 for(let i=0;i<64;i++)call('publisher',{op:'candidate',epoch,candidate:{sdp:'candidate:'+i,sdpMid:null,sdpMLineIndex:0}});
 fails(()=>call('publisher',{op:'candidate',epoch,candidate:{sdp:'candidate:overflow',sdpMid:null,sdpMLineIndex:0}}),429);
});
import {createApp} from '../server.mjs';
test('RTC HTTP route, heartbeat lease, room isolation and revocation',async t=>{
 let clock=100000;const key='a'.repeat(32);
 const app=createApp({adminKey:key,publicURL:'https://map.example.com',now:()=>clock});
 await new Promise(r=>app.listen(0,'127.0.0.1',r));t.after(()=>new Promise(r=>{app.close(r);app.closeAllConnections()}));
 const base='http://127.0.0.1:'+app.address().port;
 const call=(path,auth,body,method=body?'POST':'GET')=>fetch(base+path,{method,headers:{Authorization:'Bearer '+auth,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});
 const room=await (await call('/api/rooms',key,{password:''})).json();
 const other=await (await call('/api/rooms',key,{password:''})).json();
 const path='/api/rooms/'+room.id;
 const token=(await (await call(path+'/access',room.viewerURL.split('.').at(-1),{password:''})).json()).token;
 assert.ok(token);assert.equal((await call('/api/rooms/'+other.id+'/rtc',token)).status,401);
 const join=await call(path+'/rtc',token,{op:'join'});assert.equal(join.status,200);const s=await join.json();
 assert.equal((await call(path+'/rtc',room.publishToken,{op:'offer',epoch:s.epoch,sdp:'v=0 test'})).status,200);
 for(let i=0;i<12;i++){clock+=60000;assert.equal((await call(path+'/rtc',room.publishToken)).status,200)}
 assert.equal((await call(path,room.publishToken,undefined,'DELETE')).status,204);
 assert.equal((await call(path+'/rtc',token)).status,404);
});

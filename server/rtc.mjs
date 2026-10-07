import { createHmac } from 'node:crypto';
export function createRTC({ now, fail, limited, iceServers = [{urls:['stun:stun.l.google.com:19302']}], turnURLs = [], turnSecret = '', maxViewers = 4 }) {
  if (!Array.isArray(iceServers) || !Array.isArray(turnURLs)) throw new Error('Invalid ICE configuration');
  iceServers=iceServers.map(e=>{const urls=[].concat(e.urls||[]);if(!urls.length||!urls.every(u=>typeof u==='string'&&/^(stun|stuns|turn|turns):/.test(u)))throw new Error('Invalid ICE URL');return{...e,urls};});
  if(Boolean(turnSecret)!==Boolean(turnURLs.length)||!turnURLs.every(u=>typeof u==='string'&&/^turns?:/.test(u)))throw new Error('TURN_URLS and TURN_SECRET must be configured together');
  const fresh=()=>({epoch:0,viewer:null,viewerAt:0,publisherAt:0,offer:null,answer:null,publisherCandidates:[],viewerCandidates:[]});
  const reset=r=>{r.epoch++;r.offer=null;r.answer=null;r.publisherCandidates=[];r.viewerCandidates=[];};
  const ice=(id,slot)=>{const list=structuredClone(iceServers);if(turnSecret&&turnURLs.length){const username=`${Math.floor(now()/1000)+9000}:${id}:${slot}`;list.push({urls:turnURLs,username,credential:createHmac('sha1',turnSecret).update(username).digest('base64')});}return list;};
  function select(room,key,publisher,requested,joining){
    room.rtcSlots||=Array.from({length:maxViewers},fresh);room.viewerSlots||=new Map();
    room.rtcSlots.forEach(r=>{if(r.viewer&&now()-r.viewerAt>25000){room.viewerSlots.delete(r.viewer);r.viewer=null;reset(r);}});
    let slot=publisher && (requested===undefined||requested===null) ? 0 : Number(requested);
    if(!publisher){const assigned=room.viewerSlots.get(key);if(assigned!==undefined)slot=assigned;else if(joining){slot=room.rtcSlots.findIndex(r=>!r.viewer);if(slot<0)throw fail(409,'Room already has four viewers');room.viewerSlots.set(key,slot);}else throw fail(409,'Join first');}
    if(!Number.isInteger(slot)||slot<0||slot>=maxViewers)throw fail(400,'Invalid viewer slot');return{r:room.rtcSlots[slot],slot};
  }
  return function rtc(room,id,key,method,input,requestedSlot){
    const publisher=key===room.publishToken;if(!publisher&&!room.grants.has(key))throw fail(401,'Unauthorized');
    const {r,slot}=select(room,key,publisher,requestedSlot,method==='POST'&&input?.op==='join');limited(`rtc:${id}:${slot}:${publisher?'publisher':key}`,240,60000);
    if(method==='POST'){
      if(!input||typeof input!=='object')throw fail(400,'Invalid signal');const op=input.op;
      if(op==='join'&&!publisher){if(r.viewer&&r.viewer!==key)throw fail(409,'Viewer slot occupied');if(!r.viewer){r.viewer=key;reset(r);}r.viewerAt=now();}
      else if(op==='leave'&&!publisher){if(r.viewer===key){r.viewer=null;room.viewerSlots.delete(key);reset(r);}return{closed:true,slot};}
      else{if(!publisher&&r.viewer!==key)throw fail(409,'Join first');if(op==='reset'&&publisher){limited(`reset:${id}:${slot}`,12,60000);reset(r);}else{
        if(!Number.isSafeInteger(input.epoch)||input.epoch!==r.epoch)throw fail(409,'Stale generation');
        if(op==='offer'||op==='answer'){if((op==='offer')!==publisher)throw fail(403,'Wrong role');if(!r.viewer)throw fail(409,'No viewer');if(typeof input.sdp!=='string'||input.sdp.length>65536||!input.sdp.startsWith('v=0'))throw fail(400,'Invalid SDP');if(op==='answer'&&!r.offer)throw fail(409,'Offer first');if(r[op]&&r[op]!==input.sdp)throw fail(409,'Description already set');r[op]=input.sdp;}
        else if(op==='candidate'){const c=input.candidate;if(!c||typeof c.sdp!=='string'||c.sdp.length>4096||!c.sdp.startsWith('candidate:')||!Number.isInteger(c.sdpMLineIndex)||c.sdpMLineIndex<0||c.sdpMLineIndex>16||!(c.sdpMid===null||typeof c.sdpMid==='string'&&c.sdpMid.length<64))throw fail(400,'Invalid candidate');const list=publisher?r.publisherCandidates:r.viewerCandidates;if(!list.some(x=>x.sdp===c.sdp&&x.sdpMid===c.sdpMid&&x.sdpMLineIndex===c.sdpMLineIndex)){if(list.length>=64)throw fail(429,'Candidate limit');list.push(c);}}
        else throw fail(400,'Unknown signal');}}
    }else if(method!=='GET')throw fail(405,'Method not allowed');
    if(publisher)r.publisherAt=now();else{if(r.viewer!==key)throw fail(409,'Join first');r.viewerAt=now();}
    return{slot,epoch:r.epoch,viewer:!!r.viewer,publisherOnline:now()-r.publisherAt<15000&&r.publisherAt>0,offer:r.offer,answer:r.answer,candidates:publisher?r.viewerCandidates:r.publisherCandidates,iceServers:ice(id,slot),relayAvailable:!!turnSecret&&turnURLs.length>0||iceServers.some(s=>[].concat(s.urls).some(u=>/^turns?:/.test(u)))};
  };
}

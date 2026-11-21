import { createHmac } from 'node:crypto';

const CLOUDFLARE_KEY_ID = process.env.CLOUDFLARE_TURN_KEY_ID || '8dd1bf47f60db94223b0a9774980150c';
const CLOUDFLARE_API_TOKEN = process.env.CLOUDFLARE_TURN_API_TOKEN || '1644015cc3c5c988f7039f27b8cb86d733e6dd6d88623b9af15eef9a0acd3927';

let dynamicCloudflareICE = null;
let lastCloudflareFetch = 0;
let cloudflareFetching = false;

async function refreshCloudflareCredentials(fetchImpl = fetch) {
  if (!CLOUDFLARE_KEY_ID || !CLOUDFLARE_API_TOKEN || cloudflareFetching) return;
  cloudflareFetching = true;
  try {
    const res = await fetchImpl(`https://rtc.live.cloudflare.com/v1/turn/keys/${CLOUDFLARE_KEY_ID}/credentials/generate-ice-servers`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${CLOUDFLARE_API_TOKEN}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ ttl: 86400 })
    });
    const data = await res.json().catch(() => ({}));
    if (Array.isArray(data.iceServers) && data.iceServers.length > 0) {
      dynamicCloudflareICE = [
        { urls: ['stun:stun.cloudflare.com:3478', 'stun:stun.cloudflare.com:443', 'stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'] },
        ...data.iceServers
      ];
      lastCloudflareFetch = Date.now();
    }
  } catch {
    // Fall back to static credentials if offline
  } finally {
    cloudflareFetching = false;
  }
}

// Initial fetch if in live server environment
if (typeof process !== 'undefined' && process.env?.NODE_ENV !== 'test') {
  refreshCloudflareCredentials().catch(() => {});
}

const DEFAULT_ICE_SERVERS = [
  {
    urls: [
      'stun:stun.cloudflare.com:3478',
      'stun:stun.cloudflare.com:443',
      'stun:stun.l.google.com:19302',
      'stun:stun1.l.google.com:19302'
    ]
  },
  {
    urls: [
      'turn:turn.cloudflare.com:3478?transport=udp',
      'turn:turn.cloudflare.com:3478?transport=tcp',
      'turns:turn.cloudflare.com:5349?transport=tcp',
      'turn:turn.cloudflare.com:443?transport=udp',
      'turn:turn.cloudflare.com:80?transport=tcp',
      'turns:turn.cloudflare.com:443?transport=tcp'
    ],
    username: 'g0dcb5cdfe6c271e7567ea86329aceea18930ca5151a7c9d2690a8af1aca7faf',
    credential: '4bf67e65e9f8c52bff12ecd7943c650ad109a1ae265c5b233e04f7c3556381dc'
  }
];

export function createRTC({ now, fail, limited, iceServers = DEFAULT_ICE_SERVERS, turnURLs = [], turnSecret = '', maxViewers = 6, fetchImpl = fetch }) {
  if (!Array.isArray(iceServers) || !Array.isArray(turnURLs)) throw new Error('Invalid ICE configuration');
  iceServers=iceServers.map(e=>{const urls=[].concat(e.urls||[]);if(!urls.length||!urls.every(u=>typeof u==='string'&&/^(stun|stuns|turn|turns):/.test(u)))throw new Error('Invalid ICE URL');return{...e,urls};});
  if(Boolean(turnSecret)!==Boolean(turnURLs.length)||!turnURLs.every(u=>typeof u==='string'&&/^turns?:/.test(u)))throw new Error('TURN_URLS and TURN_SECRET must be configured together');
  const isDefaultICE = iceServers === DEFAULT_ICE_SERVERS;
  const fresh=()=>({epoch:0,viewer:null,viewerName:null,viewerAt:0,publisherAt:0,offer:null,answer:null,publisherCandidates:[],viewerCandidates:[]});
  const reset=r=>{r.epoch++;r.offer=null;r.answer=null;r.publisherCandidates=[];r.viewerCandidates=[];};
  const ice=(id,slot)=>{
    if (isDefaultICE && (!lastCloudflareFetch || Date.now() - lastCloudflareFetch > 12 * 3600 * 1000)) {
      refreshCloudflareCredentials(fetchImpl).catch(() => {});
    }
    const currentBase = (isDefaultICE && dynamicCloudflareICE) ? dynamicCloudflareICE : iceServers;
    const list=structuredClone(currentBase);
    if(turnSecret&&turnURLs.length){
      const username=`${Math.floor(now()/1000)+9000}:${id}:${slot}`;
      list.push({urls:turnURLs,username,credential:createHmac('sha1',turnSecret).update(username).digest('base64')});
    }
    return list;
  };
  function select(room,key,publisher,requested,joining){
    room.rtcSlots||=Array.from({length:maxViewers},fresh);room.viewerSlots||=new Map();
    room.rtcSlots.forEach(r=>{if(r.viewer&&now()-r.viewerAt>25000){room.viewerSlots.delete(r.viewer);r.viewer=null;r.viewerName=null;reset(r);}});
    let slot=publisher && (requested===undefined||requested===null) ? 0 : Number(requested);
    if(!publisher){const assigned=room.viewerSlots.get(key);if(assigned!==undefined)slot=assigned;else if(joining){slot=room.rtcSlots.findIndex(r=>!r.viewer);if(slot<0)throw fail(409,'Room already has six viewers');room.viewerSlots.set(key,slot);}else throw fail(409,'Join first');}
    if(!Number.isInteger(slot)||slot<0||slot>=maxViewers)throw fail(400,'Invalid viewer slot');return{r:room.rtcSlots[slot],slot};
  }
  return function rtc(room,id,key,method,input,requestedSlot){
    const publisher=key===room.publishToken;if(!publisher&&!room.grants.has(key))throw fail(401,'Unauthorized');
    const {r,slot}=select(room,key,publisher,requestedSlot,method==='POST'&&input?.op==='join');limited(`rtc:${id}:${slot}:${publisher?'publisher':key}`,240,60000);
    if(method==='POST'){
      if(!input||typeof input!=='object')throw fail(400,'Invalid signal');const op=input.op;
      if(op==='join'&&!publisher){
        if(r.viewer&&r.viewer!==key)throw fail(409,'Viewer slot occupied');
        if(!r.viewer){r.viewer=key;reset(r);}
        r.viewerAt=now();
        if(typeof input.name==='string'&&input.name.trim())r.viewerName=input.name.trim().slice(0,20);
        else if(!r.viewerName)r.viewerName='Đồng đội '+(slot+1);
      }
      else if(op==='leave'&&!publisher){if(r.viewer===key){r.viewer=null;r.viewerName=null;room.viewerSlots.delete(key);reset(r);}return{closed:true,slot};}
      else if(op==='rename'&&!publisher){
        if(r.viewer!==key)throw fail(409,'Join first');
        if(typeof input.name==='string'&&input.name.trim())r.viewerName=input.name.trim().slice(0,20);
        return{ok:true,name:r.viewerName,slot};
      }
      else{if(!publisher&&r.viewer!==key)throw fail(409,'Join first');if(op==='reset'&&publisher){limited(`reset:${id}:${slot}`,12,60000);reset(r);}else{
        if(!Number.isSafeInteger(input.epoch)||input.epoch!==r.epoch)throw fail(409,'Stale generation');
        if(op==='offer'||op==='answer'){if((op==='offer')!==publisher)throw fail(403,'Wrong role');if(!r.viewer)throw fail(409,'No viewer');if(typeof input.sdp!=='string'||input.sdp.length>65536||!input.sdp.startsWith('v=0'))throw fail(400,'Invalid SDP');if(op==='answer'&&!r.offer)throw fail(409,'Offer first');if(r[op]&&r[op]!==input.sdp)throw fail(409,'Description already set');r[op]=input.sdp;}
        else if(op==='candidate'){const c=input.candidate;if(!c||typeof c.sdp!=='string'||c.sdp.length>4096||!c.sdp.startsWith('candidate:')||!Number.isInteger(c.sdpMLineIndex)||c.sdpMLineIndex<0||c.sdpMLineIndex>16||!(c.sdpMid===null||typeof c.sdpMid==='string'&&c.sdpMid.length<64))throw fail(400,'Invalid candidate');const list=publisher?r.publisherCandidates:r.viewerCandidates;if(!list.some(x=>x.sdp===c.sdp&&x.sdpMid===c.sdpMid&&x.sdpMLineIndex===c.sdpMLineIndex)){if(list.length>=64)throw fail(429,'Candidate limit');list.push(c);}}
        else throw fail(400,'Unknown signal');}}
    }else if(method!=='GET')throw fail(405,'Method not allowed');
    if(publisher)r.publisherAt=now();else{if(r.viewer!==key)throw fail(409,'Join first');r.viewerAt=now();}
    const activeIce = ice(id,slot);
    const pubOnline = (r.publisherAt > 0 && now() - r.publisherAt < 15000) ||
      (Boolean(room.rtcSlots) && room.rtcSlots.some(x => x.publisherAt > 0 && now() - x.publisherAt < 15000)) ||
      (room.lastFrame > 0 && now() - room.lastFrame < 15000);
    const activeViewers = (room.rtcSlots||[]).filter(x=>x.viewer&&now()-x.viewerAt<25000);
    const viewerList = activeViewers.map(x=>({slot:(room.rtcSlots||[]).indexOf(x), name: x.viewerName||('Đồng đội '+((room.rtcSlots||[]).indexOf(x)+1))}));
    return{slot,epoch:r.epoch,viewer:!!r.viewer,publisherOnline:pubOnline,offer:r.offer,answer:r.answer,candidates:publisher?r.viewerCandidates:r.publisherCandidates,iceServers:activeIce,relayAvailable:!!turnSecret&&turnURLs.length>0||activeIce.some(s=>[].concat(s.urls).some(u=>/^turns?:/.test(u))),viewers:activeViewers.length,maxViewers,viewerList};
  };
}

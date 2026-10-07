'use strict';
const $=id=>document.getElementById(id), video=$('map');
const pieces=location.hash.slice(1).split('.');
const valid=pieces.length===2&&/^[A-F0-9]{12}$/.test(pieces[0])&&/^[\w-]{32}$/.test(pieces[1]);
let grant='',peer=null,epoch=-1,remoteReady=false,cursor=0,active=false,generation=0,lastServer=0,latestFrames=-1,lastFrameAt=0;
let answerSDP=null;
let signalQueue=[],sending=false,hasJoined=false;
const message=text=>$('status').textContent=text;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function api(action,body,key=grant,method=body===undefined?'GET':'POST'){
 const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),5000);
 try{
  const r=await fetch(`/api/rooms/${pieces[0]}/${action}`,{method,headers:{Authorization:`Bearer ${key}`,'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),cache:'no-store',signal:controller.signal});
  const data=await r.json().catch(()=>({}));if(!r.ok)throw Object.assign(new Error(data.error||`HTTP ${r.status}`),{status:r.status});return data;
 }finally{clearTimeout(timeout)}
}
function clearPeer(){if(peer){peer.onicecandidate=null;peer.ontrack=null;peer.close()}peer=null;video.srcObject=null;video.hidden=true;$('placeholder').hidden=false;remoteReady=false;answerSDP=null;cursor=0;signalQueue=[];latestFrames=-1;lastFrameAt=0}
function stop(){active=false;generation++;clearPeer();$('join').hidden=false;$('badge').textContent='ĐÃ DỪNG';if(grant&&hasJoined)api('rtc',{op:'leave'}).catch(()=>{});hasJoined=false}
async function flush(){
 if(sending||!signalQueue.length||!active)return;sending=true;
 const item=signalQueue[0],g=generation;
 try{await api('rtc',item);if(g===generation&&signalQueue[0]===item)signalQueue.shift()}
 catch(e){if(g===generation&&[400,403,409,429].includes(e.status)&&signalQueue[0]===item)signalQueue.shift()}
 finally{sending=false}
}
function send(payload){if(signalQueue.length<100)signalQueue.push({...payload,epoch});flush()}
async function apply(state,g){
 if(state.epoch!==epoch){clearPeer();epoch=state.epoch;peer=new RTCPeerConnection({iceServers:state.iceServers,bundlePolicy:'max-bundle'});
  const p=peer;
  p.onicecandidate=e=>{if(peer===p&&e.candidate)send({op:'candidate',candidate:{sdp:e.candidate.candidate,sdpMid:e.candidate.sdpMid,sdpMLineIndex:e.candidate.sdpMLineIndex}})};
  p.ontrack=e=>{if(peer!==p)return;video.srcObject=new MediaStream([e.track]);video.play().catch(()=>message('Bấm vào video để phát.'))};
  p.onconnectionstatechange=()=>{if(peer!==p)return;$('badge').textContent=p.connectionState==='connected'?'TRỰC TIẾP':'ĐANG KẾT NỐI';if(p.connectionState==='failed')message(state.relayAvailable?'Đang khôi phục kết nối…':'Mạng này có thể cần TURN. Chưa có chuyển tiếp trên máy chủ.')};
 }
 const p=peer;
 if(!remoteReady&&state.offer){
  if(!answerSDP){await p.setRemoteDescription({type:'offer',sdp:state.offer});if(g!==generation||peer!==p)return;
  const answer=await p.createAnswer();await p.setLocalDescription(answer);if(g!==generation||peer!==p)return;answerSDP=answer.sdp;}
  // Send answer directly and retry on next polling cycle if the request fails.
  await api('rtc',{op:'answer',epoch,sdp:answerSDP});remoteReady=true;
 }
 if(remoteReady){while(cursor<state.candidates.length){const c=state.candidates[cursor++];await p.addIceCandidate({candidate:c.sdp,sdpMid:c.sdpMid,sdpMLineIndex:c.sdpMLineIndex}).catch(()=>{})}}
}
async function metrics(){
 if(!peer)return;const p=peer,stats=await p.getStats();if(peer!==p)return;
 let inbound,pair;stats.forEach(s=>{if(s.type==='inbound-rtp'&&s.kind==='video')inbound=s;if(s.type==='candidate-pair'&&s.state==='succeeded'&&s.nominated)pair=s});
 if(inbound&&inbound.framesDecoded!==latestFrames&&inbound.framesDecoded>0){latestFrames=inbound.framesDecoded;lastFrameAt=Date.now();video.hidden=false;$('placeholder').hidden=true}
 if(Date.now()-lastFrameAt>3000){video.hidden=true;$('placeholder').hidden=false;$('placeholder').textContent='Đang chờ hình mới…'}
 const relay=pair&&[stats.get(pair.localCandidateId),stats.get(pair.remoteCandidateId)].some(s=>s?.candidateType==='relay');
 $('metrics').textContent=`${inbound?.framesPerSecond||0} fps · ${pair?.currentRoundTripTime!==undefined?Math.round(pair.currentRoundTripTime*1000)+' ms RTT':'RTT —'} · ${pair?(relay?'TURN':'P2P'):'Chưa có đường truyền'}`;
}
$('join').addEventListener('submit',async e=>{
 e.preventDefault();if(!valid){message('Link không hợp lệ. Xin link đầy đủ từ người phát.');return}
 stop();const g=++generation;
 try{
  message('Đang kết nối…');const access=await api('access',{password:$('password').value},pieces[1]);if(g!==generation)return;grant=access.token;
  await api('rtc',{op:'join'});if(g!==generation)return;hasJoined=true;active=true;lastServer=Date.now();epoch=-1;$('join').hidden=true;
  while(active&&g===generation){
   try{const s=await api('rtc');if(g!==generation)break;lastServer=Date.now();await apply(s,g);await flush();await metrics();if(peer?.connectionState==='connected')message('Đang xem video trực tiếp')}
   catch(error){if([401,404].includes(error.status)){stop();message('Phòng đã đóng hoặc hết hạn.');break}if(error.status===409){await api('rtc',{op:'join'}).catch(()=>{})}message('Đang kết nối lại…')}
   if(Date.now()-lastServer>15000){stop();message('Mất máy chủ quá 15 giây. Hãy kết nối lại.');break}
   await sleep(1000);
  }
 }catch(error){message(error.status===409?'Phòng đã có một người xem.':error.status===403?'Sai mật khẩu phòng.':error.message)}
});
$('stop').onclick=()=>{stop();message('Đã dừng xem')};
video.onclick=()=>video.play().catch(()=>{});
$('fullscreen').onclick=()=>{if($('stage').requestFullscreen)$('stage').requestFullscreen().catch(()=>{});else if(video.webkitEnterFullscreen)video.webkitEnterFullscreen()};
$('pip').onclick=async()=>{try{if(video.requestPictureInPicture)await video.requestPictureInPicture();else if(video.webkitSetPresentationMode)video.webkitSetPresentationMode('picture-in-picture');else message('Trình duyệt không hỗ trợ PiP; dùng tab Xem trong app iPhone.')}catch{message('Không mở được PiP. Dùng tab Xem trong app iPhone.')}};
window.addEventListener('pagehide',()=>{stop()});
if(!valid){message('Mở link xem do người phát gửi.');$('join').hidden=true}

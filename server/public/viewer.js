'use strict';
const $ = id => document.getElementById(id), video = $('map');
let currentPieces = null;

function getPieces() {
  let hash = location.hash.slice(1);
  if (!hash && $('roomInput') && $('roomInput').value.trim()) {
    let raw = $('roomInput').value.trim();
    if (raw.includes('#')) raw = raw.split('#')[1];
    hash = raw;
  }
  const parts = hash.split('.');
  if (parts.length === 2 && /^[A-F0-9]{12}$/.test(parts[0]) && /^[\w-]{32}$/.test(parts[1])) {
    return parts;
  }
  return null;
}

let grant = '', peer = null, epoch = -1, remoteReady = false, cursor = 0, active = false, generation = 0, lastServer = 0, latestFrames = -1, lastFrameAt = 0;
let answerSDP = null;
let signalQueue = [], sending = false, hasJoined = false;
let reconnecting = false, connectingSince = 0;

const message = text => {
  const el = $('status');
  if (el) el.textContent = text;
};

const badge = text => {
  const el = $('badge');
  if (el) el.textContent = text;
};

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function api(action, body, key = grant, method = body === undefined ? 'GET' : 'POST') {
  const p = currentPieces || getPieces();
  if (!p) throw new Error('Chưa có mã phòng');
  const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 6000);
  try {
    const r = await fetch(`/api/rooms/${p[0]}/${action}`, {
      method,
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: 'no-store',
      signal: controller.signal
    });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw Object.assign(new Error(data.error || `HTTP ${r.status}`), { status: r.status });
    return data;
  } finally {
    clearTimeout(timeout);
  }
}

function clearPeer() {
  if (peer) {
    peer.onicecandidate = null;
    peer.ontrack = null;
    peer.onconnectionstatechange = null;
    peer.oniceconnectionstatechange = null;
    try { peer.close(); } catch {}
  }
  peer = null;
  video.srcObject = null;
  video.hidden = true;
  if ($('placeholder')) $('placeholder').hidden = false;
  if ($('tapToPlay')) $('tapToPlay').hidden = true;
  remoteReady = false;
  answerSDP = null;
  cursor = 0;
  signalQueue = [];
  latestFrames = -1;
  lastFrameAt = 0;
  connectingSince = 0;
}

function stop() {
  active = false;
  generation++;
  clearPeer();
  $('join').hidden = false;
  badge('ĐÃ DỪNG');
  message('Đã dừng');
  if (grant && hasJoined) api('rtc', { op: 'leave' }).catch(() => {});
  hasJoined = false;
}

async function flush() {
  if (sending || !signalQueue.length || !active) return;
  sending = true;
  const item = signalQueue[0], g = generation;
  try {
    await api('rtc', item);
    if (g === generation && signalQueue[0] === item) signalQueue.shift();
  } catch (e) {
    if (g === generation && [400, 403, 409, 429].includes(e.status) && signalQueue[0] === item) signalQueue.shift();
  } finally {
    sending = false;
  }
}

function send(payload) {
  if (signalQueue.length < 100) signalQueue.push({ ...payload, epoch });
  flush();
}

async function triggerAutoReconnect(reason) {
  if (reconnecting || !active) return;
  reconnecting = true;
  badge('KẾT NỐI LẠI');
  message(reason || 'Đang kết nối lại...');
  clearPeer();
  epoch = -1;
  await sleep(1200);
  try {
    if (active) {
      await api('rtc', { op: 'join' });
      hasJoined = true;
    }
  } catch {}
  reconnecting = false;
}

function updateStatusDisplay(state) {
  if (!active || reconnecting) return;
  if (!state || !state.publisherOnline) {
    badge('CHỜ PHÁT');
    message('Chờ máy phát vào trận...');
    return;
  }
  if (!peer) {
    badge('KẾT NỐI');
    message('Đang kết nối tín hiệu...');
    return;
  }
  const cs = peer.connectionState;
  const ics = peer.iceConnectionState;
  if (cs === 'connected' || ics === 'connected' || ics === 'completed') {
    badge('TRỰC TIẾP');
    message('Đang phát trực tiếp');
  } else if (cs === 'connecting' || ics === 'checking') {
    badge('KẾT NỐI');
    message('Đang kết nối...');
  } else if (cs === 'failed' || ics === 'failed') {
    badge('LỖI MẠNG');
    triggerAutoReconnect('Mất tín hiệu. Đang kết nối lại...');
  } else {
    badge('SẴN SÀNG');
    message('Chờ khung hình...');
  }
}

async function apply(state, g) {
  if (state.epoch !== epoch) {
    clearPeer();
    epoch = state.epoch;
    peer = new RTCPeerConnection({ iceServers: state.iceServers, bundlePolicy: 'max-bundle' });
    const p = peer;
    p.onicecandidate = e => {
      if (peer === p && e.candidate) {
        send({ op: 'candidate', candidate: { sdp: e.candidate.candidate, sdpMid: e.candidate.sdpMid, sdpMLineIndex: e.candidate.sdpMLineIndex } });
      }
    };
    p.ontrack = e => {
      if (peer !== p) return;
      video.srcObject = new MediaStream([e.track]);
      video.hidden = false;
      if ($('placeholder')) $('placeholder').hidden = true;
      const playPromise = video.play();
      if (playPromise !== undefined) {
        playPromise.catch(() => {
          if ($('tapToPlay')) $('tapToPlay').hidden = false;
          message('Chạm nút để phát video.');
        });
      }
    };
    p.onconnectionstatechange = () => {
      if (peer !== p) return;
      updateStatusDisplay(state);
      if (p.connectionState === 'failed') {
        triggerAutoReconnect('Mất kết nối. Đang kết nối lại...');
      }
    };
    p.oniceconnectionstatechange = () => {
      if (peer !== p) return;
      if (p.iceConnectionState === 'failed') {
        triggerAutoReconnect('Lỗi đường truyền. Đang kết nối lại...');
      }
    };
  }
  const p = peer;
  if (!remoteReady && state.offer) {
    if (!answerSDP) {
      await p.setRemoteDescription({ type: 'offer', sdp: state.offer });
      if (g !== generation || peer !== p) return;
      const answer = await p.createAnswer();
      await p.setLocalDescription(answer);
      if (g !== generation || peer !== p) return;
      answerSDP = answer.sdp;
    }
    await api('rtc', { op: 'answer', epoch, sdp: answerSDP });
    remoteReady = true;
  }
  if (remoteReady) {
    while (cursor < state.candidates.length) {
      const c = state.candidates[cursor++];
      await p.addIceCandidate({ candidate: c.sdp, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex }).catch(() => {});
    }
  }
}

async function metrics() {
  if (!peer) return;
  const p = peer, stats = await p.getStats();
  if (peer !== p) return;
  let inbound, pair;
  stats.forEach(s => {
    if (s.type === 'inbound-rtp' && s.kind === 'video') inbound = s;
    if (s.type === 'candidate-pair' && s.state === 'succeeded' && s.nominated) pair = s;
  });
  if (inbound && inbound.framesDecoded > 0) {
    if (inbound.framesDecoded !== latestFrames) {
      latestFrames = inbound.framesDecoded;
      lastFrameAt = Date.now();
    }
    video.hidden = false;
    if ($('placeholder')) $('placeholder').hidden = true;
    if ($('tapToPlay')) $('tapToPlay').hidden = true;
  }
  if (lastFrameAt > 0 && Date.now() - lastFrameAt > 4000) {
    video.hidden = true;
    if ($('placeholder')) $('placeholder').hidden = false;
  }
  const fps = Math.round(inbound?.framesPerSecond || 0);
  const rtt = pair?.currentRoundTripTime !== undefined ? `${Math.round(pair.currentRoundTripTime * 1000)}ms` : '--';
  const mode = pair ? ([stats.get(pair.localCandidateId), stats.get(pair.remoteCandidateId)].some(s => s?.candidateType === 'relay') ? 'Relay' : 'P2P') : '';
  const el = $('metrics');
  if (el) {
    el.textContent = mode ? `${fps} FPS · Ping ${rtt} · ${mode}` : `${fps} FPS · Ping ${rtt}`;
  }
}

async function connectWithPassword(pwd = '') {
  const p = currentPieces || getPieces();
  if (!p) {
    message('Chưa có liên kết phòng.');
    return;
  }
  currentPieces = p;
  stop();
  const g = ++generation;
  badge('KẾT NỐI');
  message('Đang kết nối...');
  try {
    const access = await api('access', { password: pwd }, p[1]);
    if (g !== generation) return;
    grant = access.token;
    await api('rtc', { op: 'join' });
    if (g !== generation) return;
    hasJoined = true;
    active = true;
    lastServer = Date.now();
    epoch = -1;
    $('join').hidden = true;

    while (active && g === generation) {
      try {
        const s = await api('rtc');
        if (g !== generation) break;
        lastServer = Date.now();
        await apply(s, g);
        await flush();
        await metrics();
        updateStatusDisplay(s);

        // Auto-reconnect if stuck in connecting > 12s without incoming video frames
        if (s.publisherOnline && peer && (peer.connectionState === 'connecting' || peer.iceConnectionState === 'checking')) {
          if (!connectingSince) connectingSince = Date.now();
          if (Date.now() - connectingSince > 12000 && latestFrames <= 0) {
            connectingSince = 0;
            triggerAutoReconnect('Quá hạn kết nối. Đang kết nối lại...');
          }
        } else if (peer && (peer.connectionState === 'connected' || peer.iceConnectionState === 'connected')) {
          connectingSince = 0;
        }
      } catch (error) {
        if ([401, 404].includes(error.status)) {
          stop();
          badge('PHÒNG ĐÓNG');
          message('Phòng đã đóng.');
          break;
        }
        if (error.status === 409) {
          await api('rtc', { op: 'join' }).catch(() => {});
        }
        message('Đang kết nối lại...');
      }
      if (Date.now() - lastServer > 30000) {
        stop();
        badge('MẤT MẠNG');
        message('Mất kết nối máy chủ.');
        break;
      }
      await sleep(1000);
    }
  } catch (error) {
    if (error.status === 403) {
      $('join').hidden = false;
      badge('MẬT KHẨU');
      message('Phòng yêu cầu mật khẩu.');
    } else if (error.status === 409) {
      badge('PHÒNG ĐẦY');
      message('Phòng đã đủ 4 người xem.');
    } else {
      badge('LỖI');
      message(error.message || 'Lỗi kết nối.');
    }
  }
}

$('join').addEventListener('submit', async e => {
  e.preventDefault();
  await connectWithPassword($('password').value);
});

$('stop').onclick = () => {
  stop();
};

video.onclick = () => {
  video.play().catch(() => {});
  if ($('tapToPlay')) $('tapToPlay').hidden = true;
};

video.onplaying = () => {
  if ($('tapToPlay')) $('tapToPlay').hidden = true;
  video.hidden = false;
  if ($('placeholder')) $('placeholder').hidden = true;
  badge('TRỰC TIẾP');
  message('Đang phát trực tiếp');
};

if ($('tapToPlay')) {
  $('tapToPlay').onclick = () => {
    video.play().catch(() => {});
    $('tapToPlay').hidden = true;
  };
}

$('fullscreen').onclick = () => {
  if ($('stage').requestFullscreen) $('stage').requestFullscreen().catch(() => {});
  else if (video.webkitEnterFullscreen) video.webkitEnterFullscreen();
};

$('pip').onclick = async () => {
  try {
    if (document.pictureInPictureElement) {
      await document.exitPictureInPicture();
    } else if (video.requestPictureInPicture) {
      await video.requestPictureInPicture();
    } else if (video.webkitSetPresentationMode) {
      video.webkitSetPresentationMode('picture-in-picture');
    } else {
      message('Trình duyệt chưa hỗ trợ PiP.');
    }
  } catch (err) {
    message('Không thể mở PiP.');
  }
};

window.addEventListener('pagehide', () => { stop(); });

function updateRoomState() {
  const p = getPieces();
  if (p) {
    currentPieces = p;
    badge('KẾT NỐI');
    message('Đang kết nối...');
    connectWithPassword($('password') ? $('password').value : '');
  } else {
    currentPieces = null;
    $('join').hidden = true;
    badge('CHỜ LINK');
    message('Chưa có liên kết phòng.');
  }
}

window.addEventListener('hashchange', updateRoomState);
updateRoomState();

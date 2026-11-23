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
let mySlot = -1;
let myViewerName = '';
try { myViewerName = localStorage.getItem('aov_viewer_name') || ''; } catch {}

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

function clearPeer(keepLastFrame = false) {
  if (peer) {
    peer.onicecandidate = null;
    peer.ontrack = null;
    peer.onconnectionstatechange = null;
    peer.oniceconnectionstatechange = null;
    try { peer.close(); } catch {}
  }
  peer = null;
  if (!keepLastFrame) {
    video.srcObject = null;
    video.hidden = true;
    if ($('quickPip')) $('quickPip').hidden = true;
    if ($('placeholder')) $('placeholder').hidden = false;
    updatePipUI(false);
  }
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
  if ($('viewerHUD')) $('viewerHUD').hidden = true;
  mySlot = -1;
  knownViewerKeys.clear();
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
      const res = await api('rtc', { op: 'join', name: myViewerName });
      if (typeof res?.slot === 'number') mySlot = res.slot;
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
    clearPeer(true);
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
    if (video.hidden) {
      video.hidden = false;
      if ($('placeholder')) $('placeholder').hidden = true;
    }
    if ($('tapToPlay')) $('tapToPlay').hidden = true;
    if (video.paused) {
      video.play().catch(() => {});
    }
  }
  const peerConnected = peer && (peer.connectionState === 'connected' || peer.iceConnectionState === 'connected' || peer.iceConnectionState === 'completed');
  // Only hide video if connection has been dead for > 20s AND peer is completely disconnected
  if (lastFrameAt > 0 && Date.now() - lastFrameAt > 20000 && !peerConnected) {
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

function escapeHtml(str) {
  return String(str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

const knownViewerKeys = new Set();

function playDing() {
  try {
    const AudioCtx = window.AudioContext || window.webkitAudioContext;
    if (!AudioCtx) return;
    const ctx = new AudioCtx();
    if (ctx.state === 'suspended') ctx.resume();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = 'sine';
    osc.frequency.setValueAtTime(880, ctx.currentTime);
    osc.frequency.exponentialRampToValueAtTime(1320, ctx.currentTime + 0.08);
    gain.gain.setValueAtTime(0.4, ctx.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.01, ctx.currentTime + 0.25);
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start();
    osc.stop(ctx.currentTime + 0.25);
  } catch {}
}

function speakJoined(name) {
  if (!('speechSynthesis' in window) || !name) return;
  try {
    playDing();
    window.speechSynthesis.resume?.();
    const text = `${name.trim()} Lỏ đã vào phòng`;
    const u = new SpeechSynthesisUtterance(text);
    u.lang = 'vi-VN';
    u.rate = 0.95;
    u.pitch = 1.15;
    u.volume = 1.0;
    const voices = window.speechSynthesis.getVoices();
    const vi = voices.find(v => v.lang && v.lang.toLowerCase().replace('_', '-').startsWith('vi'));
    if (vi) u.voice = vi;
    setTimeout(() => {
      window.speechSynthesis.speak(u);
    }, 150);
  } catch (err) {
    console.warn('Speech synthesis error:', err);
  }
}

function announceViewers(viewerList) {
  if (!Array.isArray(viewerList)) return;
  const currentKeys = new Set();
  viewerList.forEach(v => {
    if (!v.name) return;
    const key = `${v.slot}:${v.name.trim()}`;
    currentKeys.add(key);
    if (!knownViewerKeys.has(key)) {
      speakJoined(v.name);
    }
  });
  knownViewerKeys.clear();
  currentKeys.forEach(k => knownViewerKeys.add(k));
}

function updateViewerHUD(state) {
  const hud = $('viewerHUD');
  if (!hud) return;
  if (!active) {
    hud.hidden = true;
    return;
  }
  hud.hidden = false;
  const count = state.viewers || 0;
  const max = state.maxViewers || 6;
  const countLabel = $('viewerCountLabel');
  if (countLabel) countLabel.textContent = `${count}/${max} NGƯỜI XEM`;

  announceViewers(state.viewerList);

  const listEl = $('viewerChipList');
  if (listEl && Array.isArray(state.viewerList)) {
    listEl.innerHTML = state.viewerList.map(v => {
      const isSelf = (v.slot === mySlot);
      const title = isSelf ? ' title="Chạm để đổi tên"' : '';
      return `<span class="viewer-chip${isSelf ? ' self' : ''}" data-slot="${v.slot}"${title}><i class="fa-solid fa-user"></i>${escapeHtml(v.name)}${isSelf ? ' (Bạn)' : ''}</span>`;
    }).join('');

    const selfChip = listEl.querySelector('.viewer-chip.self');
    if (selfChip) {
      selfChip.onclick = async () => {
        const newName = prompt('Nhập tên hiển thị mới:', myViewerName);
        if (newName && newName.trim() && newName.trim() !== myViewerName) {
          const trimmed = newName.trim().slice(0, 20);
          myViewerName = trimmed;
          try { localStorage.setItem('aov_viewer_name', trimmed); } catch {}
          if ($('viewerName')) $('viewerName').value = trimmed;
          await api('rtc', { op: 'rename', name: trimmed }).catch(() => {});
        }
      };
    }
  }
}

async function connectWithPassword(pwd = '', customName = '') {
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

    const nameToSend = customName || ($('viewerName') ? $('viewerName').value.trim() : '') || myViewerName;
    if (nameToSend) {
      myViewerName = nameToSend;
      try { localStorage.setItem('aov_viewer_name', nameToSend); } catch {}
    }
    const joinRes = await api('rtc', { op: 'join', name: nameToSend });
    if (g !== generation) return;
    mySlot = typeof joinRes?.slot === 'number' ? joinRes.slot : -1;
    hasJoined = true;
    active = true;
    lastServer = Date.now();
    epoch = -1;
    $('join').hidden = true;
    if ($('viewerHUD')) $('viewerHUD').hidden = false;

    while (active && g === generation) {
      try {
        const s = await api('rtc');
        if (g !== generation) break;
        lastServer = Date.now();
        await apply(s, g);
        await flush();
        await metrics();
        updateStatusDisplay(s);
        updateViewerHUD(s);

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
          const res = await api('rtc', { op: 'join', name: myViewerName }).catch(() => {});
          if (typeof res?.slot === 'number') mySlot = res.slot;
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
      message('Phòng đã đủ 6 người xem.');
    } else {
      badge('LỖI');
      message(error.message || 'Lỗi kết nối.');
    }
  }
}

$('join').addEventListener('submit', async e => {
  e.preventDefault();
  if ('speechSynthesis' in window) {
    try { window.speechSynthesis.resume?.(); } catch {}
  }
  const nameVal = $('viewerName') ? $('viewerName').value.trim() : '';
  if (!nameVal) {
    if ($('viewerName')) $('viewerName').focus();
    message('Vui lòng nhập tên người xem.');
    return;
  }
  const pwdVal = $('password') ? $('password').value : '';
  await connectWithPassword(pwdVal, nameVal);
});

$('stop').onclick = () => {
  stop();
};

function isPipActive() {
  if (document.pictureInPictureElement) return true;
  if (typeof video.webkitPresentationMode === 'string') {
    return video.webkitPresentationMode === 'picture-in-picture';
  }
  return false;
}

function updatePipUI(active) {
  const pipBtn = $('pip');
  const quickPip = $('quickPip');
  if (pipBtn) {
    pipBtn.innerHTML = active
      ? '<i class="fa-solid fa-compress"></i> ĐÓNG CỬA SỔ'
      : '<i class="fa-solid fa-clone"></i> CỬA SỔ NHỎ (PiP)';
    pipBtn.classList.toggle('pip-active', !!active);
  }
  if (quickPip) {
    quickPip.innerHTML = active
      ? '<i class="fa-solid fa-compress"></i> <span>ĐÓNG CỬA SỔ</span>'
      : '<i class="fa-solid fa-clone"></i> <span>CỬA SỔ NHỎ</span>';
    quickPip.classList.toggle('pip-active', !!active);
  }
}

async function togglePiP() {
  try {
    if ('audioSession' in navigator) {
      try { navigator.audioSession.type = 'playback'; } catch {}
    }
    if ('mediaSession' in navigator) {
      try {
        navigator.mediaSession.metadata = new MediaMetadata({
          title: 'Ma Giáo Live Map AOV',
          artist: 'Radar Trực Tiếp',
          album: 'Live Radar VIP'
        });
      } catch {}
    }

    // 1. WebKit presentation mode (Native iOS Safari on iPhone & iPad)
    if (typeof video.webkitSetPresentationMode === 'function') {
      const mode = video.webkitPresentationMode;
      const target = mode === 'picture-in-picture' ? 'inline' : 'picture-in-picture';
      video.webkitSetPresentationMode(target);
      updatePipUI(target === 'picture-in-picture');
      return;
    }

    // 2. Standard W3C PiP (Chrome, Edge, Android, Desktop Safari)
    if (document.pictureInPictureElement) {
      await document.exitPictureInPicture();
      updatePipUI(false);
    } else if (video.requestPictureInPicture) {
      await video.requestPictureInPicture();
      updatePipUI(true);
    } else {
      message('Trình duyệt chưa hỗ trợ cửa sổ nhỏ PiP.');
    }
  } catch (err) {
    console.warn('PiP error:', err);
    if (typeof video.webkitSetPresentationMode === 'function') {
      try {
        video.webkitSetPresentationMode('picture-in-picture');
        updatePipUI(true);
        return;
      } catch {}
    }
    message('Không thể mở cửa sổ nhỏ. Hãy chạm phát video trước.');
  }
}

video.addEventListener('enterpictureinpicture', () => updatePipUI(true));
video.addEventListener('leavepictureinpicture', () => updatePipUI(false));
if (typeof video.webkitSetPresentationMode === 'function') {
  video.addEventListener('webkitpresentationmodechanged', () => {
    updatePipUI(video.webkitPresentationMode === 'picture-in-picture');
  });
}

video.onclick = () => {
  if (video.paused) {
    video.play().catch(() => {});
    if ($('tapToPlay')) $('tapToPlay').hidden = true;
  } else {
    togglePiP();
  }
};

video.onplaying = () => {
  if ($('tapToPlay')) $('tapToPlay').hidden = true;
  video.hidden = false;
  if ($('quickPip')) $('quickPip').hidden = false;
  if ($('placeholder')) $('placeholder').hidden = true;
  badge('TRỰC TIẾP');
  message('Đang phát trực tiếp');
  updatePipUI(isPipActive());
};

if ($('quickPip')) {
  $('quickPip').onclick = (e) => {
    e.stopPropagation();
    togglePiP();
  };
}

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

$('pip').onclick = () => {
  togglePiP();
};

window.addEventListener('pagehide', () => {
  if (!isPipActive()) {
    stop();
  }
});

function updateRoomState() {
  const p = getPieces();
  if (p) {
    currentPieces = p;
    $('join').hidden = false;
    if ($('viewerName')) {
      $('viewerName').value = myViewerName;
      if (!myViewerName) $('viewerName').focus();
    }
    badge('SẴN SÀNG');
    message('Nhập tên rồi bấm Vào Phòng.');
  } else {
    currentPieces = null;
    $('join').hidden = true;
    if ($('viewerHUD')) $('viewerHUD').hidden = true;
    badge('CHỜ LINK');
    message('Chưa có liên kết phòng.');
  }
}

window.addEventListener('hashchange', updateRoomState);
updateRoomState();

if ('speechSynthesis' in window) {
  try {
    window.speechSynthesis.onvoiceschanged = () => {
      try { window.speechSynthesis.getVoices(); } catch {}
    };
  } catch {}
}

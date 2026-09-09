const state = {
  me: null,
  page: 'chat',
  meetings: [],
  selectedMeeting: null,
  refreshTimer: null,
  recorder: null,
  recordingStream: null,
  recordingChunks: [],
  recordingStartedAt: null,
};

const app = document.querySelector('#app');

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function markdown(text) {
  const lines = escapeHtml(text || '').split('\n');
  let inList = false;
  const out = [];
  for (const raw of lines) {
    const line = raw.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
    if (/^### /.test(line)) { if (inList) { out.push('</ul>'); inList = false; } out.push(`<h4>${line.slice(4)}</h4>`); continue; }
    if (/^## /.test(line)) { if (inList) { out.push('</ul>'); inList = false; } out.push(`<h3>${line.slice(3)}</h3>`); continue; }
    if (/^# /.test(line)) { if (inList) { out.push('</ul>'); inList = false; } out.push(`<h2>${line.slice(2)}</h2>`); continue; }
    if (/^- /.test(line)) { if (!inList) { out.push('<ul>'); inList = true; } out.push(`<li>${line.slice(2)}</li>`); continue; }
    if (inList) { out.push('</ul>'); inList = false; }
    if (line.trim()) out.push(`<p>${line}</p>`);
  }
  if (inList) out.push('</ul>');
  return out.join('');
}

async function api(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (options.method && options.method !== 'GET' && state.me?.csrf) headers.set('X-CSRF-Token', state.me.csrf);
  const response = await fetch(path, {...options, headers});
  if (response.status === 401) {
    state.me = null;
    renderSignedOut();
    throw new Error('Sign in required');
  }
  const contentType = response.headers.get('content-type') || '';
  const body = contentType.includes('application/json') ? await response.json() : await response.text();
  if (!response.ok) throw new Error(body?.detail || body || `HTTP ${response.status}`);
  return body;
}

function duration(seconds) {
  if (seconds == null) return '—';
  const total = Math.round(Number(seconds));
  if (total < 60) return `${total}s`;
  const minutes = Math.floor(total / 60);
  const rem = total % 60;
  return rem ? `${minutes}m ${rem}s` : `${minutes}m`;
}

function prettyDate(value) {
  if (!value) return '—';
  const d = new Date(value);
  return Number.isNaN(d.valueOf()) ? value : d.toLocaleString();
}

function statusPill(status) {
  const safe = escapeHtml(status || 'unknown');
  return `<span class="pill pill-${safe}">${safe}</span>`;
}

function shell(content) {
  const admin = state.me?.is_admin ? `<button class="nav-link ${state.page === 'admin' ? 'active' : ''}" data-page="admin">Admin</button>` : '';
  app.className = 'shell';
  app.innerHTML = `
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-mark">Y</div>
        <div><strong>Yossarian</strong><span>Private AI Runtime</span></div>
      </div>
      <nav>
        <button class="nav-link ${state.page === 'chat' ? 'active' : ''}" data-page="chat">Chat</button>
        <button class="nav-link ${state.page === 'meetings' ? 'active' : ''}" data-page="meetings">Meetings</button>
        <button class="nav-link ${state.page === 'knowledge' ? 'active' : ''}" data-page="knowledge">Knowledge</button>
        ${admin}
      </nav>
      <div class="sidebar-footer">
        <div class="user-name">${escapeHtml(state.me.name)}</div>
        <div class="user-email">${escapeHtml(state.me.email || state.me.sub)}</div>
        <a href="/logout">Sign out</a>
      </div>
    </aside>
    <main class="main">${content}</main>`;

  document.querySelectorAll('[data-page]').forEach(button => {
    button.addEventListener('click', () => navigate(button.dataset.page));
  });
}

function renderSignedOut() {
  clearInterval(state.refreshTimer);
  app.className = 'signed-out';
  app.innerHTML = `
    <div class="login-card">
      <div class="brand brand-login"><div class="brand-mark">Y</div><div><strong>Yossarian</strong><span>Private AI Runtime</span></div></div>
      <h1>Local AI, inspectable by design.</h1>
      <p>A reference implementation for local inference, governed organisational knowledge, meeting memory, and explicitly controlled external tools.</p>
      <a class="primary-button button" href="/login">Sign in with SSO</a>
      <div class="login-note">Development runtime · no cloud inference dependency</div>
    </div>`;
}

async function navigate(page) {
  state.page = page;
  state.selectedMeeting = null;
  clearInterval(state.refreshTimer);
  if (page === 'chat') await renderChat();
  else if (page === 'meetings') await renderMeetings();
  else if (page === 'knowledge') await renderKnowledge();
  else if (page === 'admin') await renderAdmin();
}

async function renderChat() {
  shell(`
    <div class="page-header"><div><h1>Chat</h1><p>Choose a capability boundary before opening the chat client.</p></div></div>
    <section class="chat-mode-grid">
      <article class="card chat-mode-card preferred">
        <div class="chat-mode-heading"><span class="chat-mode-icon" aria-hidden="true">🔒</span><span class="mode-badge">Recommended default</span></div>
        <h2>Private Knowledge</h2>
        <p>Answers from organisational documents that your identity is authorised to retrieve.</p>
        <ul class="capability-list">
          <li><strong>Organisational knowledge:</strong> ACL-aware retrieval</li>
          <li><strong>Inference:</strong> local</li>
          <li><strong>External tools:</strong> blocked by the runtime</li>
        </ul>
        <a class="primary-button button" href="${escapeHtml(state.me.chat_url)}" target="_blank" rel="noopener">Open LibreChat ↗</a>
        <p class="mode-note">Then select <strong>Private Knowledge</strong> in LibreChat. Keep private/RAG conversations on this mode.</p>
      </article>
      <article class="card chat-mode-card">
        <div class="chat-mode-heading"><span class="chat-mode-icon" aria-hidden="true">🌐</span><span id="publicWebState" class="mode-badge neutral">Web search: checking…</span></div>
        <h2>General AI</h2>
        <p>Plain local inference with no organisational retrieval. External tools may be enabled by runtime policy.</p>
        <ul class="capability-list">
          <li><strong>Organisational knowledge:</strong> not retrieved</li>
          <li><strong>Inference:</strong> local</li>
          <li><strong>External tools:</strong> optional and policy-gated</li>
        </ul>
        <a class="secondary-button button" href="${escapeHtml(state.me.chat_url)}" target="_blank" rel="noopener">Open LibreChat ↗</a>
        <p class="mode-note">Then select <strong>General AI</strong> in LibreChat. Do not paste private material into an egress-capable conversation.</p>
      </article>
    </section>
    <section class="trust-boundary-note">
      <strong>Why two modes?</strong> Retrieved documents are untrusted model input. Keeping organisational retrieval separate from external-tool capability reduces the direct prompt-injection → data-egress path.
    </section>`);

  try {
    const data = await api('/api/status');
    const publicWeb = (data.services || []).find(service => service.name === 'Public web');
    const badge = document.querySelector('#publicWebState');
    if (badge && publicWeb) {
      const enabled = publicWeb.state === 'enabled';
      badge.textContent = `Web search: ${enabled ? 'enabled' : 'disabled'}`;
      badge.classList.toggle('enabled', enabled);
      badge.classList.toggle('neutral', !enabled);
    }
  } catch (_) {
    const badge = document.querySelector('#publicWebState');
    if (badge) badge.textContent = 'Web search: status unavailable';
  }
}

async function renderMeetings() {
  shell(`<div class="page-header"><div><h1>Meetings</h1><p>Private transcription, review, and governed publication.</p></div><button id="newMeeting" class="primary-button">+ New meeting</button></div><div id="meetingContent" class="card"><div class="skeleton">Loading meetings…</div></div>`);
  document.querySelector('#newMeeting').addEventListener('click', showNewMeeting);
  await loadMeetings();
  state.refreshTimer = setInterval(async () => {
    if (state.page === 'meetings' && !state.selectedMeeting) await loadMeetings(true);
  }, 4000);
}

async function loadMeetings(silent = false) {
  try {
    const payload = await api('/api/meetings');
    state.meetings = payload.data || [];
    const host = document.querySelector('#meetingContent');
    if (!host) return;
    if (!state.meetings.length) {
      host.innerHTML = `<div class="empty"><h2>No meetings yet</h2><p>Upload a recording or record one directly in the browser.</p><button class="primary-button" id="emptyNew">Create first meeting</button></div>`;
      document.querySelector('#emptyNew').addEventListener('click', showNewMeeting);
      return;
    }
    host.innerHTML = `<div class="meeting-list">${state.meetings.map(job => `
      <button class="meeting-row" data-id="${escapeHtml(job.id)}">
        <div class="meeting-main"><strong>${escapeHtml(job.title)}</strong><span>${prettyDate(job.created_at)}</span></div>
        <div class="meeting-meta"><span>${duration(job.duration_seconds)}</span>${statusPill(job.status)}</div>
      </button>`).join('')}</div>`;
    document.querySelectorAll('.meeting-row').forEach(row => row.addEventListener('click', () => showMeeting(row.dataset.id)));
  } catch (error) {
    if (!silent) document.querySelector('#meetingContent').innerHTML = `<div class="error">${escapeHtml(error.message)}</div>`;
  }
}

function showNewMeeting() {
  clearInterval(state.refreshTimer);
  shell(`
    <div class="page-header"><div><button class="back" id="backMeetings">← Meetings</button><h1>New meeting</h1><p>Upload an existing recording or record now.</p></div></div>
    <div class="two-column">
      <section class="card form-card">
        <label>Title<input id="meetingTitle" value="Meeting" /></label>
        <label>Participants <span class="hint">comma separated</span><input id="meetingParticipants" placeholder="Alex, Sam, Jordan" /></label>
        <label class="check"><input type="checkbox" id="retainAudio" /> Retain source audio after processing</label>
        <div class="divider"></div>
        <label>Upload recording<input type="file" id="audioFile" accept="audio/*,video/*" /></label>
        <button id="uploadMeeting" class="primary-button">Process recording</button>
        <div id="uploadStatus" class="muted"></div>
      </section>
      <section class="card recorder-card">
        <div class="record-orb" id="recordOrb"><span></span></div>
        <h2>Record now</h2>
        <p>Audio stays inside this runtime after it reaches the server.</p>
        <div class="record-time" id="recordTime">00:00</div>
        <button id="recordButton" class="secondary-button">Start recording</button>
        <button id="stopButton" class="primary-button hidden">Stop & process</button>
        <div id="recordStatus" class="muted"></div>
      </section>
    </div>`);
  document.querySelector('#backMeetings').addEventListener('click', () => navigate('meetings'));
  document.querySelector('#uploadMeeting').addEventListener('click', uploadSelectedMeeting);
  setupRecorder();
}

function meetingFormData(file) {
  const form = new FormData();
  form.append('audio', file, file.name || 'meeting.webm');
  form.append('title', document.querySelector('#meetingTitle').value || 'Meeting');
  form.append('participants', document.querySelector('#meetingParticipants').value || '');
  form.append('retain_audio', document.querySelector('#retainAudio').checked ? '1' : '0');
  return form;
}

async function submitMeeting(file, statusNode) {
  statusNode.textContent = 'Uploading…';
  try {
    const job = await api('/api/meetings', {method: 'POST', body: meetingFormData(file)});
    statusNode.textContent = `Queued ${job.id}`;
    await showMeeting(job.id);
  } catch (error) {
    statusNode.textContent = error.message;
    statusNode.classList.add('error-text');
  }
}

async function uploadSelectedMeeting() {
  const input = document.querySelector('#audioFile');
  const status = document.querySelector('#uploadStatus');
  if (!input.files?.length) { status.textContent = 'Choose an audio or video file first.'; return; }
  await submitMeeting(input.files[0], status);
}

function setupRecorder() {
  const start = document.querySelector('#recordButton');
  const stop = document.querySelector('#stopButton');
  const status = document.querySelector('#recordStatus');
  if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) {
    start.disabled = true;
    status.textContent = 'Browser recording is not supported here; use file upload.';
    return;
  }
  start.addEventListener('click', async () => {
    try {
      state.recordingStream = await navigator.mediaDevices.getUserMedia({audio: true});
      const preferred = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus'].find(type => MediaRecorder.isTypeSupported(type));
      state.recorder = new MediaRecorder(state.recordingStream, preferred ? {mimeType: preferred} : undefined);
      state.recordingChunks = [];
      state.recorder.addEventListener('dataavailable', event => { if (event.data.size) state.recordingChunks.push(event.data); });
      state.recorder.addEventListener('stop', async () => {
        const type = state.recorder.mimeType || 'audio/webm';
        const ext = type.includes('ogg') ? 'ogg' : 'webm';
        const blob = new Blob(state.recordingChunks, {type});
        const file = new File([blob], `meeting-${Date.now()}.${ext}`, {type});
        state.recordingStream?.getTracks().forEach(track => track.stop());
        document.querySelector('#recordOrb').classList.remove('recording');
        await submitMeeting(file, status);
      });
      state.recorder.start(1000);
      state.recordingStartedAt = Date.now();
      document.querySelector('#recordOrb').classList.add('recording');
      start.classList.add('hidden');
      stop.classList.remove('hidden');
      status.textContent = 'Recording locally in your browser…';
      const timer = setInterval(() => {
        if (!state.recorder || state.recorder.state === 'inactive') { clearInterval(timer); return; }
        const s = Math.floor((Date.now() - state.recordingStartedAt) / 1000);
        document.querySelector('#recordTime').textContent = `${String(Math.floor(s/60)).padStart(2,'0')}:${String(s%60).padStart(2,'0')}`;
      }, 500);
    } catch (error) { status.textContent = `Microphone unavailable: ${error.message}`; }
  });
  stop.addEventListener('click', () => {
    if (state.recorder?.state !== 'inactive') state.recorder.stop();
    stop.disabled = true;
    status.textContent = 'Finishing recording…';
  });
}

async function showMeeting(id) {
  state.selectedMeeting = id;
  clearInterval(state.refreshTimer);
  shell(`<div class="page-header"><div><button class="back" id="backMeetings">← Meetings</button><h1>Meeting</h1></div></div><div id="meetingDetail" class="skeleton">Loading meeting…</div>`);
  document.querySelector('#backMeetings').addEventListener('click', () => navigate('meetings'));
  await refreshMeetingDetail(id);
  state.refreshTimer = setInterval(async () => {
    if (state.page === 'meetings' && state.selectedMeeting === id) await refreshMeetingDetail(id, true);
  }, 3000);
}

async function artifact(id, name) {
  const response = await fetch(`/api/meetings/${encodeURIComponent(id)}/artifacts/${encodeURIComponent(name)}`);
  if (!response.ok) return '';
  return response.text();
}

async function refreshMeetingDetail(id, silent = false) {
  try {
    const job = await api(`/api/meetings/${encodeURIComponent(id)}`);
    let summary = '', transcript = '';
    if (job.status === 'draft' || job.status === 'published') {
      [summary, transcript] = await Promise.all([artifact(id, 'summary.md'), artifact(id, 'normalized_transcript.md')]);
    }
    const host = document.querySelector('#meetingDetail');
    if (!host) return;
    const publishing = job.status === 'draft' ? `
      <section class="publish-box">
        <div><strong>Publish to knowledge</strong><p>Publication is explicit. The normalized transcript becomes governed evidence.</p></div>
        <div class="publish-actions"><button class="secondary-button" data-publish="private">Private to me</button><button class="primary-button" data-publish="everyone">Everyone</button></div>
      </section>` : '';
    host.innerHTML = `
      <section class="meeting-hero card">
        <div><h1>${escapeHtml(job.title)}</h1><p>${prettyDate(job.created_at)} · ${duration(job.duration_seconds)} · ${escapeHtml((job.participants || []).join(', ') || 'No participant context')}</p></div>
        ${statusPill(job.status)}
      </section>
      ${job.error ? `<div class="error card"><strong>Processing failed</strong><pre>${escapeHtml(job.error)}</pre></div>` : ''}
      ${publishing}
      ${summary ? `<section class="card"><div class="section-title"><h2>Meeting record</h2><span>evidence-grounded</span></div><div class="markdown">${markdown(summary)}</div></section>` : `<section class="card processing"><div class="spinner"></div><div><h2>${job.status === 'queued' ? 'Queued' : 'Processing locally'}</h2><p>Transcription, diarisation, conservative normalization and summary extraction run inside the runtime.</p></div></section>`}
      ${transcript ? `<section class="card"><div class="section-title"><h2>Transcript</h2><span>normalized · raw preserved separately</span></div><div class="transcript">${markdown(transcript)}</div></section>` : ''}`;
    document.querySelectorAll('[data-publish]').forEach(button => button.addEventListener('click', async () => {
      button.disabled = true;
      try {
        await api(`/api/meetings/${encodeURIComponent(id)}/publish`, {method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({visibility: button.dataset.publish})});
        await refreshMeetingDetail(id);
      } catch (error) { alert(error.message); button.disabled = false; }
    }));
    if (['draft','published','failed'].includes(job.status)) clearInterval(state.refreshTimer);
  } catch (error) {
    if (!silent) document.querySelector('#meetingDetail').innerHTML = `<div class="error card">${escapeHtml(error.message)}</div>`;
  }
}

async function renderKnowledge() {
  shell(`<div class="page-header"><div><h1>Knowledge</h1><p>See what this runtime knows, and test retrieval under your permissions.</p></div></div>
    <section class="card search-card"><form id="knowledgeSearch"><input id="knowledgeQuery" placeholder="Search governed knowledge…" /><button class="primary-button">Search</button></form><div id="knowledgeResults"></div></section>
    <section class="card"><div class="section-title"><h2>Sources</h2><span>visible to you</span></div><div id="knowledgeSources" class="skeleton">Loading sources…</div></section>`);
  document.querySelector('#knowledgeSearch').addEventListener('submit', async event => {
    event.preventDefault();
    const q = document.querySelector('#knowledgeQuery').value.trim();
    if (!q) return;
    const host = document.querySelector('#knowledgeResults');
    host.innerHTML = '<div class="skeleton">Searching…</div>';
    try {
      const data = await api(`/api/knowledge/search?q=${encodeURIComponent(q)}`);
      host.innerHTML = data.data.length ? `<div class="search-results">${data.data.map(item => `<article><strong>${escapeHtml(item.title)}</strong><span>${escapeHtml(item.uri)}</span><p>${escapeHtml(item.content)}</p></article>`).join('')}</div>` : '<div class="empty-small">No authorised evidence matched.</div>';
    } catch (error) { host.innerHTML = `<div class="error">${escapeHtml(error.message)}</div>`; }
  });
  try {
    const data = await api('/api/knowledge');
    const host = document.querySelector('#knowledgeSources');
    host.innerHTML = data.data.length ? `<div class="source-list">${data.data.map(doc => `<div class="source-row"><div><strong>${escapeHtml(doc.title)}</strong><span>${escapeHtml(doc.uri)}</span></div><div><span class="source-type">${escapeHtml(doc.source_type)}</span></div></div>`).join('')}</div>` : '<div class="empty-small">No knowledge sources are visible to this user.</div>';
  } catch (error) { document.querySelector('#knowledgeSources').innerHTML = `<div class="error">${escapeHtml(error.message)}</div>`; }
}

async function renderAdmin() {
  if (!state.me?.is_admin) return navigate('meetings');
  shell(`<div class="page-header"><div><h1>Governance</h1><p>Runtime readiness, installed models and content-free audit metadata.</p></div></div>
    <section class="card"><div class="section-title"><h2>Runtime status</h2><span id="runtimeVersion"></span></div><div id="runtimeStatus" class="status-grid skeleton">Loading status…</div></section>
    <section class="card"><div class="section-title"><h2>Models</h2><span>local capability inventory</span></div><div id="modelStatus" class="model-list"></div></section>
    <section class="card"><div class="section-title"><h2>Recent audit</h2><span>prompt/response content disabled</span></div><div id="auditStatus" class="skeleton">Loading audit…</div></section>`);
  try {
    const data = await api('/api/status');
    document.querySelector('#runtimeVersion').textContent = data.runtime_version;
    document.querySelector('#runtimeStatus').classList.remove('skeleton');
    document.querySelector('#runtimeStatus').innerHTML = data.services.map(s => {
      const detail = s.state || (s.ok ? 'ready' : (s.error || `HTTP ${s.status}`));
      const healthy = s.ok && s.state !== 'misconfigured';
      return `<div class="status-card ${healthy ? 'ok' : 'bad'}"><span class="status-dot"></span><div><strong>${escapeHtml(s.name)}</strong><span>${escapeHtml(detail)}</span></div></div>`;
    }).join('');
    document.querySelector('#modelStatus').innerHTML = `<div><strong>LLM</strong>${(data.models.llm || []).map(m => `<span>${escapeHtml(m)}</span>`).join('') || '<span>none reported</span>'}</div><div><strong>Speech</strong>${(data.models.speech || []).map(m => `<span>${escapeHtml(m)}</span>`).join('') || '<span>none reported</span>'}</div>`;
  } catch (error) { document.querySelector('#runtimeStatus').innerHTML = `<div class="error">${escapeHtml(error.message)}</div>`; }
  try {
    const data = await api('/api/audit?limit=30');
    const host = document.querySelector('#auditStatus');
    host.classList.remove('skeleton');
    host.innerHTML = data.data.length ? `<div class="audit-list">${data.data.map(e => `<div class="audit-row"><span>${prettyDate(e.started_at)}</span><strong>${escapeHtml(e.principal?.email || e.principal?.id || 'system')}</strong><span>${escapeHtml(e.client || '')}</span><span>${escapeHtml(e.model_alias || '')}</span><span>${escapeHtml(e.status || '')}</span><span>${escapeHtml(e.total_tokens ?? '')} tokens</span></div>`).join('')}</div>` : '<div class="empty-small">No audit events yet.</div>';
  } catch (error) { document.querySelector('#auditStatus').innerHTML = `<div class="error">${escapeHtml(error.message)}</div>`; }
}

async function init() {
  try {
    state.me = await api('/api/me');
    await renderChat();
  } catch (error) {
    if (!state.me) renderSignedOut();
  }
}

init();

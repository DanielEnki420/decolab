/* Decolab panel - page logic (stage 1: read-only).

   Reads /api/v1/* and fills the page. Rules:
   - Every value goes in with textContent, never innerHTML: container and
     alert names are data from outside.
   - Whatever this host does not have ({"available": false} or null) shows
     as "—" or hides its card; it is never an error.
   - No inline handlers: the Content-Security-Policy allows only this file. */
'use strict';

/* ── helpers ──────────────────────────────────────────────────────────── */
const $ = id => document.getElementById(id);
function set(id, v) { const e = $(id); if (e) e.textContent = (v === null || v === undefined || v === '') ? '—' : v; }
function setW(id, pct) { const e = $(id); if (e) e.style.width = Math.min(100, Math.max(0, pct || 0)) + '%'; }
const num = v => typeof v === 'number' && isFinite(v);
function gb(bytes, d = 1) { return num(bytes) ? (bytes / 1024 ** 3).toFixed(d) : '—'; }
function fmtMenge(bytes) {
  if (!num(bytes)) return '—';
  const mb = bytes / 1024 ** 2;
  return mb >= 1024 ? (mb / 1024).toFixed(1) + ' GB' : Math.round(mb) + ' MB';
}
function fmtRate(bytesPerS) {
  const mbit = bytesPerS * 8 / 1e6;
  if (mbit >= 10) return [String(Math.round(mbit)), 'Mbit/s'];
  if (mbit >= 1) return [mbit.toFixed(1), 'Mbit/s'];
  return [String(Math.round(mbit * 1000)), 'kbit/s'];
}
function fmtUptime(s) {
  if (!num(s)) return '—';
  const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
  return d ? `${d}d ${h}h` : `${h}h ${String(m).padStart(2, '0')}m`;
}
function ago(epoch) {
  if (!num(epoch)) return '—';
  const s = Date.now() / 1000 - epoch;
  if (s < 90) return 'just now';
  if (s < 5400) return Math.round(s / 60) + ' min ago';
  if (s < 172800) return Math.round(s / 3600) + ' h ago';
  return Math.round(s / 86400) + ' days ago';
}
function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}
function icon(name) {
  const ns = 'http://www.w3.org/2000/svg';
  const s = document.createElementNS(ns, 'svg'), u = document.createElementNS(ns, 'use');
  s.setAttribute('class', 'i'); s.setAttribute('aria-hidden', 'true');
  u.setAttribute('href', '/static/icons/ui.svg#' + name);
  s.appendChild(u);
  return s;
}
function animNum(id, target, suffix = '', decimals = 0) {
  const e = $(id);
  if (!e) return;
  if (!num(target)) { e.textContent = '—'; e._cur = null; return; }
  const start = num(e._cur) ? e._cur : target, t0 = performance.now(), dur = 600;
  function step(t) {
    const p = Math.min(1, (t - t0) / dur), val = start + (target - start) * (1 - Math.pow(1 - p, 3));
    e.textContent = (decimals ? val.toFixed(decimals) : Math.round(val)) + suffix;
    if (p < 1) requestAnimationFrame(step); else e._cur = target;
  }
  e._cur = start;
  requestAnimationFrame(step);
}

/* Colours come from the stylesheet, never copied: a copy drifts. */
const COLORS = (function () {
  const cs = getComputedStyle(document.documentElement);
  const v = (name, fallback) => cs.getPropertyValue(name).trim() || fallback;
  return { accent: v('--accent', '#c9a35b'), green: v('--green', '#4bb98e'),
           amber: v('--amber', '#dca844'), red: v('--red', '#cd5f58') };
})();

async function api(path) {
  const r = await fetch('/api/v1/' + path, { credentials: 'same-origin', cache: 'no-store' });
  if (r.status === 401) { location.reload(); throw new Error('login'); }
  if (!r.ok) throw new Error(path + ': HTTP ' + r.status);
  return r.json();
}

/* ── navigation, clock, full screen ───────────────────────────────────── */
function nav(item) {
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  item.classList.add('active');
  const page = $(item.dataset.page);
  if (page) { page.classList.add('active'); $('main').scrollTop = 0; setTimeout(drawAll, 30); }
  closeNav();
}
function closeNav() { $('nav').classList.remove('open'); $('overlay').style.display = 'none'; }
document.querySelectorAll('.nav-item').forEach(n => {
  n.addEventListener('click', () => nav(n));
  n.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); nav(n); } });
});
$('menu-btn').addEventListener('click', () => {
  $('nav').classList.toggle('open');
  $('overlay').style.display = $('nav').classList.contains('open') ? 'block' : 'none';
});
$('overlay').addEventListener('click', closeNav);
$('fs-btn').addEventListener('click', () => {
  const d = document, on = d.fullscreenElement || d.webkitFullscreenElement, root = d.documentElement;
  if (!on) (root.requestFullscreen || root.webkitRequestFullscreen || function () {}).call(root);
  else (d.exitFullscreen || d.webkitExitFullscreen || function () {}).call(d);
});
function tick() {
  const now = new Date();
  const ts = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  set('hdr-time', ts);
  set('dash-time-sub', now.toLocaleDateString([], { weekday: 'short', day: 'numeric', month: 'short' }) + ' · ' + ts);
}
tick(); setInterval(tick, 1000);

/* ── sparkline ────────────────────────────────────────────────────────── */
function drawChart(canvasId, datasets, min = 0, max = 100) {
  const canvas = $(canvasId);
  if (!canvas) return;
  const dpr = window.devicePixelRatio || 1, W = canvas.offsetWidth, H = canvas.offsetHeight;
  if (!W || !H) return;
  canvas.width = W * dpr; canvas.height = H * dpr;
  const ctx = canvas.getContext('2d');
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, W, H);
  ctx.strokeStyle = 'rgba(255,255,255,.05)';
  ctx.lineWidth = 1;
  [25, 50, 75].forEach(p => {
    const y = H - p / 100 * H;
    ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(W, y); ctx.stroke();
  });
  datasets.forEach(({ data, color }) => {
    const vals = (data || []).map(v => num(v) ? v : null);
    const n = vals.length;
    if (n < 2) return;
    const pts = [];
    vals.forEach((v, i) => { if (v !== null) pts.push({ x: i / (n - 1) * W, y: H - (v - min) / ((max - min) || 1) * H }); });
    if (pts.length < 2) return;
    ctx.beginPath();
    pts.forEach((p, i) => i === 0 ? ctx.moveTo(p.x, p.y) : ctx.lineTo(p.x, p.y));
    ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.lineJoin = 'round';
    ctx.stroke();
    ctx.lineTo(pts[pts.length - 1].x, H); ctx.lineTo(pts[0].x, H); ctx.closePath();
    ctx.globalAlpha = 0.12; ctx.fillStyle = color; ctx.fill(); ctx.globalAlpha = 1;
  });
}

let hist = null, speed = null;
function drawAll() {
  if (hist) {
    drawChart('chart-cpu-ram', [{ data: hist.cpu, color: COLORS.accent }, { data: hist.ram, color: COLORS.green }], 0, 100);
    drawChart('chart-temps', [{ data: hist.cpu_temp, color: COLORS.red }, { data: hist.nvme_temp, color: COLORS.amber }], 20, 90);
    const rates = [...(hist.rx || []), ...(hist.tx || [])].filter(num).map(v => v * 8 / 1e6);
    const top = Math.max(1, ...rates) * 1.15;
    drawChart('chart-netz', [{ data: (hist.rx || []).map(v => num(v) ? v * 8 / 1e6 : null), color: COLORS.green },
                             { data: (hist.tx || []).map(v => num(v) ? v * 8 / 1e6 : null), color: COLORS.accent }], 0, top);
  }
  if (speed) renderSpeed(speed);
}
let resizeT;
window.addEventListener('resize', () => { clearTimeout(resizeT); resizeT = setTimeout(drawAll, 150); });

/* ── system ───────────────────────────────────────────────────────────── */
function tempWord(t) { return !num(t) ? '—' : t >= 75 ? 'hot' : t >= 60 ? 'warm' : 'normal'; }
function renderSystem(s) {
  const t = s.temps || {}, cpu = s.cpu || {}, mem = s.memory || {}, net = s.network || {};
  const root = (s.disks || [])[0] || {};
  set('hdr-name', s.hostname || 'Decolab');
  set('hdr-ip-txt', net.address);
  set('hdr-temp', 'CPU ' + (num(t.cpu) ? t.cpu + '°' : '—') + (num(t.nvme) ? ' · NVMe ' + t.nvme + '°' : ''));
  $('hdr-dot').className = 'dot ' + (num(t.cpu) && t.cpu >= 75 ? 'dot-red' : 'dot-green');
  set('nav-up', 'Uptime ' + fmtUptime(s.uptime_s));
  set('nav-ip', net.address);
  set('nav-model', s.model || s.kernel);

  animNum('s-cpu', cpu.pct, '%');
  set('s-cpu-sub', num(cpu.count) ? cpu.count + ' cores' : '—');
  animNum('s-ram', mem.pct, '%');
  set('s-ram-sub', `${gb(mem.used)} / ${gb(mem.total)} GB`);
  animNum('s-disk', root.pct, '%');
  set('s-disk-sub', `${gb(root.used, 0)} / ${gb(root.total, 0)} GB`);
  animNum('s-ctemp', t.cpu, '°');
  set('s-ctemp-sub', tempWord(t.cpu));
  animNum('s-ntemp', t.nvme, '°');
  set('s-ntemp-sub', num(t.nvme) ? tempWord(t.nvme) : 'no NVMe sensor');
  set('s-uptime', fmtUptime(s.uptime_s));
  setW('sb-cpu', cpu.pct); setW('sb-ram', mem.pct); setW('sb-disk', root.pct);
  setW('sb-ctemp', num(t.cpu) ? t.cpu / 85 * 100 : 0); setW('sb-ntemp', num(t.nvme) ? t.nvme / 70 * 100 : 0);

  // network: rate from the server's sampler, totals since boot
  set('net-iface', net.interface);
  if (num(net.rx_rate)) {
    const [a, ae] = fmtRate(net.rx_rate), [u, ue] = fmtRate(net.tx_rate);
    set('nl-r', a); set('nl-r-e', ae); set('nl-s', u); set('nl-s-e', ue);
  }
  set('nl-summe', `since boot  ↓ ${fmtMenge(net.rx_total)}  ·  ↑ ${fmtMenge(net.tx_total)}`);

  // fan: the card only exists on hosts with a PWM fan
  const fan = s.fan || {};
  // style.display, not hidden: the stylesheet's display rules win over [hidden]
  $('fan-card').style.display = fan.available ? '' : 'none';
  $('hdr-fan-pill').style.display = fan.available ? '' : 'none';
  $('fan-card').parentElement.classList.toggle('zwei', !fan.available);
  if (fan.available) {
    set('hdr-fan', (num(fan.rpm) ? fan.rpm : '—') + ' RPM');
    animNum('fan-rpm-big', fan.rpm);
    setW('g-fan', num(fan.pwm) ? fan.pwm / 255 * 100 : 0);
    set('gv-fan', num(fan.pwm) ? Math.round(fan.pwm / 255 * 100) + ' %' : '—');
    const ring = $('fan-ring');
    if (num(fan.rpm) && fan.rpm > 0) {
      ring.style.setProperty('--fan-dur', Math.max(0.3, Math.min(3, 800 / fan.rpm)).toFixed(2) + 's');
      ring.style.setProperty('--fan-play', 'running');
    } else ring.style.setProperty('--fan-play', 'paused');
  }

  // system page
  const hw = $('hw-grid');
  hw.textContent = '';
  [['Model', s.model], ['Kernel', s.kernel], ['CPU cores', cpu.count], ['RAM', num(mem.total) ? gb(mem.total) + ' GB' : null],
   ['Load (1/5/15 min)', s.load ? s.load.join(' / ') : null], ['Address ' + (net.interface || ''), net.address]]
    .forEach(([k, v]) => {
      const d = el('div');
      d.appendChild(el('div', '', k)).style.cssText = 'font-size:12.3px;color:var(--text-2)';
      d.appendChild(el('div', '', v === null || v === undefined ? '—' : String(v))).style.cssText = 'font-size:14.6px;margin-top:3px;font-weight:600';
      hw.appendChild(d);
    });
  const cg = $('cores-grid');
  cg.textContent = '';
  (cpu.cores || []).forEach((c, i) => {
    const item = el('div', 'core-item');
    item.appendChild(el('div', 'cv ' + (c >= 80 ? 'c-red' : c >= 60 ? 'c-amber' : 'c-blue'), (num(c) ? c : '—') + '%'));
    item.appendChild(el('div', 'cl', 'Core ' + (i + 1)));
    cg.appendChild(item);
  });
  set('sgv-ram', num(mem.pct) ? mem.pct + '%' : '—');
  setW('sg-ram', mem.pct);
  set('ram-detail', `${gb(mem.used)} GB used · ${gb(mem.total)} GB total`);
  const sw = s.swap || {};
  set('swap-detail', sw.available === false ? 'no swap' : `${fmtMenge(sw.used)} used of ${fmtMenge(sw.total)}`);
  const dk = $('disks');
  dk.textContent = '';
  (s.disks || []).forEach(d => {
    const row = el('div', 'gauge');
    row.appendChild(el('span', 'g-name', d.path));
    const bar = el('div', 'g-bar'), wrap = el('div', 'bar-wrap'), fill = el('div', 'bar-fill');
    fill.style.background = d.pct >= 90 ? 'var(--red)' : d.pct >= 75 ? 'var(--amber)' : 'var(--green)';
    fill.style.width = Math.min(100, d.pct) + '%';
    wrap.appendChild(fill); bar.appendChild(wrap); row.appendChild(bar);
    row.appendChild(el('span', 'g-val', `${d.pct}% · ${gb(d.free, 0)} GB free`));
    dk.appendChild(row);
  });
}

/* ── containers ───────────────────────────────────────────────────────── */
let containers = [], containersOk = false;
function state(c) { return c.running === null ? 'neutral' : c.running ? 'gruen' : 'rot'; }
function renderContainers(d) {
  containersOk = !!d.available;
  containers = Array.isArray(d.containers) ? d.containers : [];
  const rank = { rot: 0, neutral: 1, gruen: 2 };
  const sorted = [...containers].sort((a, b) => rank[state(a)] - rank[state(b)] || a.name.localeCompare(b.name));
  const grid = $('cgrid');
  grid.textContent = '';
  sorted.forEach(c => {
    const chip = el('span', 'cchip ' + (state(c) === 'neutral' ? 'gelb' : state(c)));
    chip.title = c.name + (c.image ? ' — ' + c.image : '');
    chip.appendChild(el('i'));
    chip.appendChild(document.createTextNode(c.name.replace(/_/g, ' ')));
    grid.appendChild(chip);
  });
  const up = containers.filter(c => c.running).length, down = containers.filter(c => c.running === false).length;
  const sum = $('cgrid-summary');
  if (!containersOk) {
    set('cgrid-zahl', 'state unknown');
    sum.className = 'waechter-zeile gelb';
    sum.textContent = 'Containers: ' + (d.reason || 'state unknown');
  } else {
    set('cgrid-zahl', down ? `${down} stopped · ${up} running` : `all ${up} running`);
    sum.className = 'waechter-zeile ' + (down ? 'rot' : 'gruen');
    sum.textContent = down ? `Containers: ${down} of ${containers.length} stopped` : `Containers: all ${up} running`;
  }
  set('dk-up', containersOk ? up : '—');
  set('dk-ges', containers.length);
  set('dk-extra', containersOk ? containers.filter(c => !c.expected).length : '—');
  set('dk-down', containersOk ? down : '—');
  set('dk-down-sub', !containersOk ? 'state unknown' : down ? 'please look' : 'all running');
  set('dk-src', containersOk ? 'live' : 'offline');
  renderTable();
}
function renderTable() {
  const tbody = $('docker-tbody'), q = ($('dk-suche').value || '').trim().toLowerCase();
  const text = { rot: 'Stopped', gruen: 'Running', neutral: 'Unknown' };
  const badge = { rot: 'badge-red', gruen: 'badge-green', neutral: 'badge-amber' };
  const list = containers.filter(c => !q || (c.name + ' ' + (c.image || '')).toLowerCase().includes(q))
    .sort((a, b) => a.name.localeCompare(b.name));
  tbody.textContent = '';
  list.forEach(c => {
    const tr = el('tr');
    tr.appendChild(el('td', 'name-col', c.name + (c.expected ? '' : ' (extra)')));
    tr.appendChild(el('td', 'img-col', c.image || '—'));
    tr.appendChild(el('td', 'port-col', c.since ? ago(c.since) : '—'));
    const td = el('td'), b = el('span', 'badge ' + badge[state(c)]);
    b.appendChild(el('span', 'bdot'));
    b.appendChild(document.createTextNode(text[state(c)]));
    td.appendChild(b); tr.appendChild(td); tbody.appendChild(tr);
  });
  set('docker-count', q ? `${list.length} found` : containersOk ? `${containers.filter(c => c.running).length}/${containers.length} running` : '');
}
$('dk-suche').addEventListener('input', renderTable);

/* ── alerts, backup, services, speed test ─────────────────────────────── */
function renderAlerts(d) {
  const list = $('alerts-list');
  list.textContent = '';
  const txt = $('alerts-txt');
  if (!d.available) {
    set('alerts-n', '—'); set('alerts-sub', '');
    txt.textContent = 'Prometheus not reachable'; txt.className = 'waechter-txt rot';
    return;
  }
  const n = d.firing.length;
  set('alerts-n', n); set('alerts-sub', d.pending ? ` +${d.pending} pending` : '');
  txt.textContent = n ? (n === 1 ? '1 alert firing' : n + ' alerts firing') : 'no alert firing';
  txt.className = 'waechter-txt ' + (n ? 'rot' : 'gruen');
  d.firing.slice(0, 5).forEach(a => list.appendChild(el('li', '', a.name + (a.summary ? ': ' + a.summary : ''))));
}
function renderBackup(d) {
  const line = $('backup-line'), tbl = $('backup-tbl');
  tbl.textContent = '';
  const row = (k, v) => {
    const r = el('div', 'info-row');
    r.appendChild(el('div', 'info-key', k)); r.appendChild(el('div', 'info-val', v));
    tbl.appendChild(r);
  };
  if (!d.available) {
    line.className = 'waechter-zeile gelb'; line.textContent = 'Backup: directory not readable';
    row('Status', 'BACKUP_DIR is not readable for the panel');
    return;
  }
  const old = !num(d.age_h) || d.age_h > 26;
  line.className = 'waechter-zeile ' + (d.running ? 'gelb' : old || d.last_incomplete ? 'rot' : 'gruen');
  line.textContent = d.running ? 'Backup: running now' : !d.latest ? 'Backup: none yet'
    : `Backup: ${d.age_h} h old` + (d.last_incomplete ? ' · last run incomplete' : '');
  row('Newest complete', d.latest ? d.latest.replace('_', ' ').replace(/-(\d\d)$/, ':$1') : 'none yet');
  row('Age', num(d.age_h) ? d.age_h + ' hours' : '—');
  row('Kept', String(d.count));
  row('Running now', d.running ? 'yes' : 'no');
  if (d.last_incomplete) row('Incomplete', d.last_incomplete + ' (newer than the last complete one)');
}
function renderServices(d) {
  const box = $('launcher');
  box.textContent = '';
  const https = location.protocol === 'https:';
  (d.services || []).forEach(s => {
    const usable = s.available && (s.reach !== 'tailscale' || https);
    const a = el(usable ? 'a' : 'div', 'app-tile' + (usable ? '' : ' off'));
    if (usable) {
      a.href = `${location.protocol}//${location.hostname}:${s.port}${s.path}`;
      a.target = '_blank'; a.rel = 'noopener noreferrer';
    } else a.title = 'only over HTTPS (tailscale serve)';
    a.style.setProperty('--tile-c', 'rgba(201,163,91,.55)');
    const ico = el('div', 'app-ico mark');
    ico.appendChild(icon(s.icon));
    a.appendChild(ico);
    a.appendChild(el('div', 'app-name', s.title));
    box.appendChild(a);
  });
  if (!box.children.length) box.appendChild(el('div', 'leer-hinweis', 'no web interfaces configured'));
}
function fmtMbit(x) { return !num(x) ? '—' : x >= 100 ? String(Math.round(x)) : x.toFixed(1); }
function renderSpeed(d) {
  speed = d;
  $('speed-block').hidden = !d.available;
  const inet = $('nl-internet');
  inet.hidden = !d.available;
  if (!d.available) return;
  const runs = d.runs || [], ok = runs.filter(e => e.ok), last = ok[ok.length - 1], newest = runs[runs.length - 1];
  if (last) {
    set('it-down', fmtMbit(last.down)); set('it-up', fmtMbit(last.up));
    set('it-ping', num(last.ping) ? Math.round(last.ping) : '—'); set('it-jitter', num(last.jitter) ? last.jitter : '—');
    set('it-meta', (last.server ? last.server + ' · ' : '') + ago(last.t));
    inet.textContent = `Internet  ↓ ${fmtMbit(last.down)}  ↑ ${fmtMbit(last.up)} Mbit/s  ·  ${ago(last.t)}`;
  } else {
    set('it-meta', 'no measurement yet'); inet.textContent = 'Internet: no measurement yet';
  }
  const f = $('it-fehler'), failed = newest && !newest.ok;
  f.hidden = !failed;
  if (failed) f.textContent = 'Last attempt ' + ago(newest.t) + ' without a result';
  const ds = ok.slice(-28);
  $('it-kurven').classList.toggle('leer', ds.length < 2);
  if (ds.length > 1) {
    drawChart('chart-it-down', [{ data: ds.map(e => e.down), color: COLORS.green }], 0, Math.max(1, ...ds.map(e => e.down).filter(num)) * 1.15);
    drawChart('chart-it-up', [{ data: ds.map(e => e.up), color: COLORS.accent }], 0, Math.max(1, ...ds.map(e => e.up).filter(num)) * 1.15);
  }
}

/* ── polling ──────────────────────────────────────────────────────────── */
function quiet(p) { return p.catch(e => { if (e.message !== 'login') console.warn(e.message); }); }
function fast() {
  quiet(api('system').then(renderSystem));
  quiet(api('history').then(h => { hist = h; drawAll(); }));
}
function slow() {
  quiet(api('containers').then(renderContainers));
  quiet(api('alerts').then(renderAlerts));
  quiet(api('backup').then(renderBackup));
  quiet(api('speedtest').then(renderSpeed));
}
quiet(api('services').then(renderServices));
fast(); slow();
setInterval(fast, 5000);
setInterval(slow, 30000);

// ─────────────────────────────────────────────────────────────
//  Boombox relay — Cloudflare Workers version (Durable Object)
//  Always-on, free, no PC, no credit card, never sleeps.
//
//  Why a Durable Object: plain module state is per-isolate, so
//  two WebSocket clients can land on different isolates and never
//  see each other. A Durable Object routes ALL WebSocket
//  connections to a single object instance -> real fanout.
//
//  Deploy (dashboard): dash.cloudflare.com → Workers & Pages →
//  Create → Worker → paste this whole file → Deploy, THEN:
//  Settings → Bindings → Durable Object → name: BOOMBOX_RELAY,
//  class: BoomboxRelay → Save. Redeploy (Deploy again) so the
//  migration registers.
//
//  Your URL:  https://<name>.workers.dev
//  Lua uses:  wss://<name>.workers.dev
// ─────────────────────────────────────────────────────────────

export class BoomboxRelay {
  constructor(state, env) {
    this.connections = new Set();
  }

  async fetch(request) {
    const upgrade = (request.headers.get("Upgrade") || "").toLowerCase();
    if (upgrade !== "websocket") {
      return new Response("Boombox relay", { status: 200 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();
    this.connections.add(server);

    server.addEventListener("message", (event) => {
      const text = String(event.data);
      for (const other of this.connections) {
        if (other === server || other.readyState !== 1) continue;
        try { other.send(text); } catch {}
      }
    });
    server.addEventListener("close", () => this.connections.delete(server));
    server.addEventListener("error", () => this.connections.delete(server));

    return new Response(null, { status: 101, webSocket: client });
  }
}

const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Boombox Web Player</title>
<style>
:root{--bg:#0f141c;--panel:#1b2130;--row:#242c3d;--acc:#00e5ff;--ok:#22c55e;--bad:#ef4444}
*{box-sizing:border-box;margin:0;padding:0;font-family:-apple-system,Segoe UI,Roboto,sans-serif}
body{background:var(--bg);color:#e8eef7;min-height:100vh;display:flex;justify-content:center;padding:24px}
.card{width:100%;max-width:420px;background:var(--panel);border-radius:16px;padding:18px;height:fit-content}
h1{font-size:20px;display:flex;align-items:center;gap:8px}
.dot{width:10px;height:10px;border-radius:50%;background:#666;display:inline-block}
.dot.on{background:var(--ok);box-shadow:0 0 8px var(--ok)}
.dot.off{background:var(--bad)}
.sub{color:#8b94a7;font-size:12px;margin-top:2px}
input{width:100%;padding:10px;border-radius:8px;border:1px solid #2e3a52;background:var(--row);color:#e8eef7;font-size:14px}
.row{display:flex;gap:8px;margin-top:8px}
.row input{flex:1}
button{padding:10px 14px;border:none;border-radius:8px;font-weight:700;cursor:pointer;color:#08131a;font-size:14px}
.play{background:var(--acc)} .stop{background:var(--bad);color:#fff}
.save{background:var(--ok);color:#08131a} .xp{background:#3a1116;color:#fca5a5}
.list{margin-top:14px;display:flex;flex-direction:column;gap:6px;max-height:45vh;overflow-y:auto}
.item{display:flex;align-items:center;gap:8px;background:var(--row);padding:8px 10px;border-radius:8px}
.item .meta{flex:1;overflow:hidden}
.item .n{font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.item .i{font-size:11px;color:#8b94a7}
.toast{text-align:center;font-size:12px;color:var(--acc);min-height:16px;margin-top:10px}
.vol{display:flex;align-items:center;gap:10px;margin-top:12px}
.vol input[type=range]{flex:1;accent-color:var(--acc)}
</style>
</head>
<body>
<div class="card">
  <h1><span class="dot" id="dot"></span>Boombox <span style="font-weight:400;font-size:12px;color:#8b94a7">web client</span></h1>
  <div class="sub" id="conn">connecting…</div>
  <div class="row"><input id="name" placeholder="Your name" maxlength="20"></div>
  <div class="row">
    <input id="id" placeholder="Enter audio ID (123456789)" inputmode="numeric">
    <button class="play" id="play">▶</button>
    <button class="stop" id="stop">■</button>
  </div>
  <div class="row"><button class="save" id="save" style="flex:1">＋ Save to playlist</button></div>
  <div class="vol"><span style="font-size:12px">Vol</span><input type="range" id="vol" min="0" max="1" step="0.01" value="1"></div>
  <div class="sub" style="margin-top:12px" id="now">Not playing</div>
  <div class="list" id="list"></div>
  <div class="toast" id="toast"></div>
</div>
<script>
const $=id=>document.getElementById(id);
const dot=$('dot'),conn=$('conn'),toastEl=$('toast'),listEl=$('list'),nowEl=$('now');
let ws=null,audio=null,vol=1;
const KEY='boombox_playlist';
let playlist=[];try{playlist=JSON.parse(localStorage.getItem(KEY)||'[]')}catch{}
function toast(t){toastEl.textContent=t;setTimeout(()=>{if(toastEl.textContent===t)toastEl.textContent=''},2500)}
function connect(){
  dot.className='dot off';conn.textContent='connecting…';
  const url=(location.protocol==='https:'?'wss://':'ws://')+location.host;
  try{ws=new WebSocket(url)}catch(e){conn.textContent='bad url';return}
  ws.onopen=()=>{dot.className='dot on';conn.textContent='connected';send({type:'join',user:$('name').value||'Web user'})};
  ws.onmessage=(ev)=>{let m;try{m=JSON.parse(ev.data)}catch{return}
    if(m.type==='play'){playId(m.id,true);toast((m.user||'Someone')+' ▶ '+(m.name||m.id))}
    if(m.type==='stop'){stopAudio();toast((m.user||'Someone')+' stopped the music')}
    if(m.type==='join')toast((m.user||'Someone')+' joined')};
  ws.onclose=()=>{dot.className='dot off';conn.textContent='disconnected — retrying';setTimeout(connect,3000)};
  ws.onerror=()=>{try{ws.close()}catch{}};
}
function send(o){if(ws&&ws.readyState===1)ws.send(JSON.stringify(o))}
function getName(id){const e=playlist.find(x=>x.id===id);return e?e.name:'Audio '+id}
function playId(id,fromNet){
  const clean=String(id).replace(/\D/g,'');if(!clean)return;
  stopAudio();
  audio=new Audio('https://assetdelivery.roblox.com/v1/asset/?id='+clean);
  audio.volume=vol;
  audio.play().then(()=>nowEl.textContent='Now playing: '+clean).catch(()=>toast('audio blocked by Roblox (unlicensed or region-locked)'));
  if(!fromNet)send({type:'play',id:clean,name:getName(clean),user:$('name').value||'Web user'});
}
function stopAudio(){if(audio){audio.pause();audio=null}nowEl.textContent='Not playing'}
$('play').onclick=()=>playId($('id').value);
$('stop').onclick=()=>{stopAudio();send({type:'stop',user:$('name').value||'Web user'})};
$('vol').oninput=e=>{vol=+e.target.value;if(audio)audio.volume=vol};
$('save').onclick=()=>{
  const id=String($('id').value).replace(/\D/g,'');if(!id)return toast('enter an audio id first');
  if(playlist.some(x=>x.id===id))return toast('already in playlist');
  playlist.unshift({id,name:'Audio '+id});localStorage.setItem(KEY,JSON.stringify(playlist));render();toast('saved (browser only)');
};
function render(){
  listEl.innerHTML='';
  playlist.forEach(e=>{
    const item=document.createElement('div');item.className='item';
    item.innerHTML='<div class="meta"><div class="n"></div><div class="i"></div></div><button class="xp">✕</button>';
    item.querySelector('.n').textContent=e.name;
    item.querySelector('.i').textContent=e.id;
    item.onclick=()=>playId(e.id);
    item.querySelector('.xp').onclick=ev=>{ev.stopPropagation();playlist=playlist.filter(x=>x!==e);localStorage.setItem(KEY,JSON.stringify(playlist));render()};
    listEl.appendChild(item);
  });
}
render();connect();
</script>
</body>
</html>`;

export default {
  async fetch(request, env) {
    const upgrade = (request.headers.get("Upgrade") || "").toLowerCase();
    if (upgrade !== "websocket") {
      return new Response(HTML, {
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }
    const id = env.BOOMBOX_RELAY.idFromName("main");
    const stub = env.BOOMBOX_RELAY.get(id);
    return stub.fetch(request);
  },
};

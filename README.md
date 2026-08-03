# Delta Boombox — websocket shared audio player

Play Roblox audio together. Everyone who runs the script (or the web player)
connects to one relay server. When anyone plays a song, **everyone hears it**.

```
boombox.lua        ← execute this in Delta on Roblox (the GUI + playlist)
server.js          ← relay for hosting yourself (see below)
worker.js          ← relay for Cloudflare Workers (best free option)
web/index.html     ← browser client (auto-served by server.js and worker.js)
```

---

## 1. Get the relay online (free)

> If you host on your own PC/phone your friends can't reach it. Use Cloudflare
> Workers instead — it's **always-on, free, no PC, no credit card, never sleeps**.

### Option A — Cloudflare Workers (RECOMMENDED, 5 minutes)

1. Go to **dash.cloudflare.com** → sign up (free) → **Workers & Pages**
2. **Create** → **Worker** → **Deploy** (create the default one)
3. Click **Edit code**, delete everything, paste the contents of **`worker.js`**
4. Click **Deploy**. You get `https://<your-name>.<subdomain>.workers.dev`
5. Put that into `boombox.lua` as `wss://<your-name>.<subdomain>.workers.dev`
   and execute. Share the same URL with your friend (they use the same script).
6. Bonus: opening the URL in a browser gives your friend a web player too.

### Option B — your own PC / Termux + tunnel (free, needs your PC online)

```bash
cd boombox
npm install
node server.js          # relays on port 8080
```

In a **second terminal**, run a free tunnel:

```bash
# localhost.run (no signup):
ssh -R 80:localhost:8080 nokey@localhost.run
# → prints https://xxxx.lhr.life   (use wss://xxxx.lhr.life)

# or cloudflared (no account needed):
cloudflared tunnel --url http://localhost:8080
# → prints https://xxxx.trycloudflare.com  (use wss://xxxx.trycloudflare.com)
```

### Option C — free web host (no PC, but some sleep when idle)

- **Render.com** → New Web Service → deploy this folder (Build `npm install`,
  Start `node server.js`). Free tier supports websockets (wakes on demand).
- **Glitch.com** → new project → paste `server.js` + `package.json` →
  it auto-installs and starts → `https://your-app.glitch.me`.

---

## 2. Put your URL into the script

Open `boombox.lua` and change this one line:

```lua
local WS_URL   = "wss://YOUR-URL-HERE"      -- e.g. "wss://xxxx.lhr.life"
```

Save it, execute it in **Delta** on Roblox. That's it. Hand the same URL to your
friends and they execute the same script (or open the URL in a browser).

---

## 3. Using the GUI

- **Enter audio ID** (the number in a Roblox audio's URL) → **▶ Play**
- **＋ Save** → adds it to your playlist (name is fetched automatically) and saves it **locally**
  to `boombox_playlist.json` so it survives restarts
- Click any saved song to play it, **✕** deletes it, **Clear** wipes the list
- Volume bar on the right, drag the title bar to move the window
- Green/red dot shows relay connection status

**Everyone hears what you play, and you hear what they play.**

---

## Notes

- The relay excludes the sender, so you don't get your own song twice.
- Roblox will block an audio ID you don't have license/access to ("audio unavailable").
  Use IDs your account can actually play — the classic boombox rule.
- The web player plays IDs through `assetdelivery.roblox.com`; a few audios are
  region-locked and won't stream in a browser.
- Reconnects automatically every 5 seconds when the relay is offline.

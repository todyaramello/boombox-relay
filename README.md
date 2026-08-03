# Delta Boombox — websocket shared audio player

Play Roblox audio together. Everyone who runs the script (or the web player)
connects to one relay server. When anyone plays a song, **everyone hears it**.

```
boombox.lua        ← execute this in Delta on Roblox (the GUI + playlist)
server.js          ← relay for hosting yourself (see below)
worker.js          ← relay for Cloudflare Workers (best free option)
wrangler.toml      ← config so Cloudflare can deploy worker.js from GitHub
web/index.html     ← browser client (auto-served by server.js and worker.js)
```

---

## 1. Get the relay online (free)

> If you host on your own PC/phone your friends can't reach it. Use Cloudflare
> Workers instead — it's **always-on, free, no PC, no credit card, never sleeps**,
> and it can deploy straight from this GitHub repo.

### Option A — Cloudflare Workers from your GitHub repo (RECOMMENDED, ~5 min)

1. Go to **dash.cloudflare.com** → sign up (free) → **Workers & Pages**
2. **Create application** → **Connect to Git** → choose the
   `boombox-relay` repo (the `wrangler.toml` makes it build with zero setup)
3. It builds and deploys automatically → you get
   `https://boombox-relay.<your-subdomain>.workers.dev`
4. Put that into `boombox.lua` as `wss://boombox-relay.<your-subdomain>.workers.dev`
   and execute. Share the same URL with your friend (they use the same script).
5. Bonus: opening the URL in a browser gives your friend a web player too.
   Every time you push to GitHub it redeploys automatically.

> No GitHub link? Instead do **Create application → Worker → Edit code** →
> delete everything → paste `worker.js` → Deploy. Same result.

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

### Option C — Render.com (free web host, imports from GitHub)

- **Render.com** → New → Web Service → connect this GitHub repo →
  Build: `npm install`, Start: `node server.js` → `https://<name>.onrender.com`
- Free tier wakes on demand, but it can sleep when idle — less reliable than
  Cloudflare for long sessions.

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

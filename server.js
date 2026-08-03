// Boombox relay - broadcasts play/stop messages between all connected clients.
// The sender is excluded, so nobody hears their own song twice.
const http = require("http");
const fs = require("fs");
const path = require("path");
const { WebSocketServer, WebSocket } = require("ws");

const PORT = process.env.PORT || 8080;

const clients = new Map(); // ws -> meta

const server = http.createServer((req, res) => {
  if (req.method !== "GET") {
    res.writeHead(405).end();
    return;
  }
  if (req.url === "/" || req.url === "/index.html") {
    fs.readFile(path.join(__dirname, "web", "index.html"), (err, data) => {
      if (err) {
        res.writeHead(404).end("no web player found");
        return;
      }
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(data);
    });
    return;
  }
  res.writeHead(404).end();
});

const wss = new WebSocketServer({ server });

function broadcast(sender, text) {
  for (const [ws, meta] of clients) {
    if (ws === sender) continue;
    if (ws.readyState === WebSocket.OPEN) ws.send(text);
  }
}

wss.on("connection", (ws) => {
  clients.set(ws, {});
  ws.on("message", (raw) => {
    const text = raw.toString();
    try {
      const m = JSON.parse(text);
      if (m.type === "join") clients.set(ws, { user: m.user || "?" });
      if (m.type === "play")
        console.log(`[play] ${m.user || "?"} -> ${m.id || "?"} (${m.name || "?"})`);
      if (m.type === "stop") console.log(`[stop] ${m.user || "?"}`);
    } catch {}
    broadcast(ws, text);
  });
  ws.on("close", () => clients.delete(ws));
  ws.on("error", () => clients.delete(ws));
});

server.listen(PORT, () => {
  console.log(`Boombox relay running on port ${PORT}`);
  console.log(`Local: ws://localhost:${PORT}`);
  console.log("Expose to the internet with a tunnel (cloudflared / localhost.run) or free host.");
});

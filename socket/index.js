const WebSocket = require("ws");
const Redis = require("ioredis");

const SCANNER_PASSWORD = "29678292";
const LISTENER_PASSWORD = "24908812";
const wss = new WebSocket.Server({ port: 8080 });

// Use Upstash Redis URL + token
const redis = new Redis(process.env.UPSTASH_REDIS_URL || "rediss://default:AbfZAAIncDI3NDBkMzhlNDA5MjQ0YjIwYmE2ZWZkMjY3YTI4ZTEyMnAyNDcwNjU@well-newt-47065.upstash.io:6379");

let scanners = new Map();
let listeners = new Set();

function color(e, c = 0) {
  const l = ["grey", "red", "green", "yellow", "blue", "magenta", "cyan", "white"];
  c = l.indexOf(c);
  if (c === -1) c = 0;
  return `\x1b[3${c}m${e}\x1b[0m`;
}

wss.on("connection", (ws) => {
  let authed = false;
  let role = null;
  let scannerId = null;
  let sessionKey = null;

  ws.on("message", async (msg) => {
    let data;
    try { data = JSON.parse(msg); } catch { return; }

    if (data.type === "auth") {
      if (data.password === SCANNER_PASSWORD) {
        authed = true;
        role = "scanner";

        // Unique scanner ID: use metadata fingerprint or fallback
        scannerId = data.metadata?.fingerprint || `scanner-${Date.now()}`;
        sessionKey = `session:${scannerId}:${Date.now()}`;

        // Store scanner metadata permanently
        await redis.hSet(`scanner:${scannerId}`, data.metadata || {});
        await redis.rPush("scanners_list", scannerId);

        // Initialize session
        await redis.hSet(sessionKey, {
          connectedAt: new Date().toISOString(),
          scans: 0,
          name: data.metadata?.device || "Unknown",
        });

        scanners.set(scannerId, ws);
        console.log(color(`Scanner connected: ${scannerId}`, "green"));
        ws.send(JSON.stringify({ type: "auth", status: "success", role: "scanner", id: scannerId }));
      }
      else if (data.password === LISTENER_PASSWORD) {
        authed = true;
        role = "listener";
        listeners.add(ws);
        console.log(color(`Listener connected`, "yellow"));

        // Send currently online scanners
        ws.send(JSON.stringify({ type: "online_devices", devices: Array.from(scanners.keys()) }));
        ws.send(JSON.stringify({ type: "auth", status: "success", role: "listener" }));
      }
      else ws.send(JSON.stringify({ type: "auth", status: "fail" }));

      return;
    }

    if (!authed) return;

    if (role === "scanner" && data.type === "scan") {
      const record = {
        time: data.time || new Date().toISOString(),
        scannerId,
        data: data.data,
        color: data.color || "grey",
      };

      console.log(`${color(record.time, "grey")} ${color(scannerId, "cyan")} ${color(record.data, record.color)}`);

      // Store scan permanently
      await redis.rPush("scanned_codes", JSON.stringify(record));

      // Update session scan count
      await redis.hIncrBy(sessionKey, "scans", 1);

      // Broadcast to listeners
      listeners.forEach((l) => {
        if (l.readyState === WebSocket.OPEN) l.send(JSON.stringify({ type: "scan", ...record }));
      });
    }
  });

  ws.on("close", async () => {
    if (role === "scanner" && scannerId) {
      scanners.delete(scannerId);
      // Update session disconnect time
      await redis.hSet(sessionKey, { disconnectedAt: new Date().toISOString() });
    } else if (role === "listener") {
      listeners.delete(ws);
    }
  });
});

console.log("WebSocket server running on ws://localhost:8080");

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

wss.on("connection", (ws, req) => {
  const clientIp = req.socket.remoteAddress.replace("::ffff:", "");
  let authed = false;
  let role = null;
  let userScannerId = null; // The person using the device
  let startTime = null;

  ws.on("message", async (msg) => {
    let data;
    try { data = JSON.parse(msg); } catch { return; }

    if (data.type === "auth") {
      if (data.password === SCANNER_PASSWORD) {
        authed = true;
        role = "scanner";

        userScannerId = data.scannerId || "Unknown User";
        startTime = new Date().toISOString();

        await redis.hset(`scanner:${clientIp}`, {
          ...(data.metadata || {}),
          scanner_user_id: userScannerId,
          last_connected: startTime,
          current_session_scans: 0,
          name: data.metadata?.device || "Unknown Device",
        });

        // Add IP to global list (Using a new key name 'scanners_ips' to avoid type conflicts)
        await redis.sadd("scanners_ips", clientIp);

        scanners.set(clientIp, ws);
        console.log(color(`Scanner Connected | User: ${userScannerId} | IP: ${clientIp}`, "green"));
        ws.send(JSON.stringify({ type: "auth", status: "success", role: "scanner", ip: clientIp, userId: userScannerId }));
      }
      else if (data.password === LISTENER_PASSWORD) {
        authed = true;
        role = "listener";
        listeners.add(ws);
        console.log(color(`Listener connected from ${clientIp}`, "yellow"));

        // Send currently online IPs
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
        userId: userScannerId,
        ip: clientIp,
        data: data.data,
        color: data.color || "grey",
      };

      console.log(`${color(record.time, "grey")} ${color(userScannerId, "cyan")} (${color(clientIp, "blue")}): ${color(record.data, record.color)}`);

      // Store scan permanently
      await redis.rpush("scanned_codes", JSON.stringify(record));

      // Update session scan count for this IP
      await redis.hincrby(`scanner:${clientIp}`, "current_session_scans", 1);

      // Broadcast to listeners
      listeners.forEach((l) => {
        if (l.readyState === WebSocket.OPEN) l.send(JSON.stringify({ type: "scan", ...record }));
      });
    }
  });

  ws.on("close", async () => {
    if (role === "scanner") {
      scanners.delete(clientIp);
      const stats = await redis.hgetall(`scanner:${clientIp}`);

      const historyEntry = {
        userId: userScannerId,
        connectedAt: startTime,
        disconnectedAt: new Date().toISOString(),
        scans: parseInt(stats.current_session_scans) || 0,
        device: stats.name || "Unknown"
      };

      await redis.rpush(`scanner:${clientIp}:sessions`, JSON.stringify(historyEntry));

      console.log(color(`Scanner Disconnected | User: ${userScannerId} | IP: ${clientIp}`, "red"));
    } else if (role === "listener") {
      listeners.delete(ws);
    }
  });
});

console.log("WebSocket server running on ws://localhost:8080");

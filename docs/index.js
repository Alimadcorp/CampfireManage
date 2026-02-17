const WebSocket = require("ws");
const Redis = require("ioredis");

const SCANNER_PASSWORD = "29678292";
const LISTENER_PASSWORD = "24908812";
const wss = new WebSocket.Server({ port: 8080 });

const redis = new Redis(process.env.UPSTASH_REDIS_URL || "rediss://default:AbfZAAIncDI3NDBkMzhlNDA5MjQ0YjIwYmE2ZWZkMjY3YTI4ZTEyMnAyNDcwNjU@well-newt-47065.upstash.io:6379");

const scanners = new Map(); // Store { ws, metadata }
const listeners = new Set();

function color(e, c = 0) {
  const l = ["grey", "red", "green", "yellow", "blue", "magenta", "cyan", "white"];
  c = l.indexOf(c);
  if (c === -1) c = 0;
  return `\x1b[3${c}m${e}\x1b[0m`;
}

function broadcastOnlineDevices() {
  const devices = Array.from(scanners.keys());
  const metadataMap = {};
  scanners.forEach((val, key) => {
    metadataMap[key] = val.metadata;
  });

  const payload = JSON.stringify({ type: "online_devices", devices, metadataMap });
  listeners.forEach((l) => {
    if (l.readyState === WebSocket.OPEN) l.send(payload);
  });
}

function broadcastListenerCount() {
  const count = listeners.size;
  listeners.forEach((l) => {
    if (l.readyState === WebSocket.OPEN) {
      l.send(JSON.stringify({ type: "listener_count", count }));
    }
  });
}

// Heartbeat: prune stale connections
const heartbeatInterval = setInterval(() => {
  wss.clients.forEach((ws) => {
    if (ws.isAlive === false) {
      console.log(color("Pruning dead connection", "red"));
      return ws.terminate();
    }
    ws.isAlive = false;
    ws.ping();
  });
}, 30000);

wss.on("close", () => clearInterval(heartbeatInterval));

wss.on("connection", (ws, req) => {
  ws.isAlive = true;
  ws.on("pong", () => { ws.isAlive = true; });

  const clientIp = (req.socket.remoteAddress || "0.0.0.0").replace("::ffff:", "");
  let authed = false;
  let role = null;
  let userScannerId = null;
  let startTime = null;
  let currentMetadata = {};

  const safeSend = (target, payload) => {
    try {
      if (target.readyState === WebSocket.OPEN) {
        target.send(JSON.stringify(payload));
      }
    } catch (e) {
      console.error("Failed to send message:", e.message);
    }
  };

  ws.on("message", async (msg) => {
    let data;
    try {
      data = JSON.parse(msg);
    } catch (e) {
      return;
    }

    if (data.type === "auth") {
      if (data.password === SCANNER_PASSWORD) {
        authed = true;
        role = "scanner";

        userScannerId = data.scannerId || "Unknown User";
        startTime = new Date().toISOString();

        currentMetadata = {
          ...(data.metadata || {}),
          scanner_user_id: userScannerId,
          last_connected: startTime,
          current_session_scans: 0,
          name: data.metadata?.device || "Unknown Device",
          ip: clientIp
        };

        try {
          await redis.hset(`scanner:${clientIp}`, currentMetadata);
          await redis.sadd("scanners_ips", clientIp);
        } catch (e) {
          console.error("Redis Error (Auth):", e.message);
        }

        scanners.set(clientIp, { ws, metadata: currentMetadata });
        console.log(color(`Scanner Connected | User: ${userScannerId} | IP: ${clientIp}`, "green"));
        safeSend(ws, { type: "auth", status: "success", role: "scanner", ip: clientIp, userId: userScannerId });

        broadcastOnlineDevices();
      }
      else if (data.password === LISTENER_PASSWORD) {
        authed = true;
        role = "listener";
        listeners.add(ws);
        console.log(color(`Listener connected from ${clientIp}`, "yellow"));

        broadcastOnlineDevices();
        safeSend(ws, { type: "auth", status: "success", role: "listener" });
        broadcastListenerCount();

        try {
          const history = await redis.lrange("scanned_codes", -50, -1);
          if (history && history.length > 0) {
            const parsedHistory = [];
            for (const s of history) {
              try {
                parsedHistory.push(JSON.parse(s));
              } catch (e) { }
            }
            safeSend(ws, { type: "history", scans: parsedHistory });
          }
        } catch (e) {
          console.error("Redis Error (History):", e.message);
        }
      }
      else safeSend(ws, { type: "auth", status: "fail" });

      return;
    }

    if (!authed) return;

    if (role === "scanner" && data.type === "scan") {
      const record = {
        time: data.time || new Date().toISOString(),
        userId: userScannerId,
        scannerId: userScannerId,
        ip: clientIp,
        data: data.data || "",
        scannerInfo: currentMetadata
      };

      const num = Number.isInteger(data.num) ? data.num : (typeof data.num === 'string' && /^[0-9]+$/.test(data.num) ? parseInt(data.num, 10) : null);
      if (num !== null) record.num = num;

      console.log(`${color(record.time, "grey")} ${color(userScannerId, "cyan")} (${color(clientIp, "blue")}): ${color(record.data, record.color)}${num !== null ? (' #' + num) : ''}`);

      try {
        if (num !== null) {
          const packetKey = `scanner:${clientIp}:packets`;
          await redis.hset(packetKey, `${num}`, JSON.stringify(record));
        }
        await redis.rpush("scanned_codes", JSON.stringify(record));
        await redis.hincrby(`scanner:${clientIp}`, "current_session_scans", 1);
      } catch (e) {
        console.error("Redis Error (Scan):", e.message);
      }

      listeners.forEach((l) => safeSend(l, { type: "scan", ...record }));

      if (num !== null) {
        safeSend(ws, { type: "received", num: num, status: "success" });
      }
    }

    if (role === "listener" && data.type === "resend_request") {
      const target = data.scannerId || data.ip;
      const reqNum = data.num;
      if (!target || reqNum == null) return;

      const scannerEntry = scanners.get(target);
      if (scannerEntry) {
        safeSend(scannerEntry.ws, { type: "resend", num: reqNum });
      }
    }
  });

  ws.on("close", async () => {
    if (role === "scanner") {
      scanners.delete(clientIp);
      broadcastOnlineDevices();
      try {
        const stats = await redis.hgetall(`scanner:${clientIp}`);
        if (stats && Object.keys(stats).length > 0) {
          const historyEntry = {
            userId: userScannerId,
            connectedAt: startTime,
            disconnectedAt: new Date().toISOString(),
            scans: parseInt(stats.current_session_scans) || 0,
            device: stats.name || "Unknown"
          };
          await redis.rpush(`scanner:${clientIp}:sessions`, JSON.stringify(historyEntry));
        }
      } catch (e) {
        console.error("Redis Error (Close):", e.message);
      }
      console.log(color(`Scanner Disconnected | User: ${userScannerId} | IP: ${clientIp}`, "red"));
    } else if (role === "listener") {
      listeners.delete(ws);
      broadcastListenerCount();
    }
  });

  ws.on("error", (e) => {
    console.error("WS Client Error:", e.message);
  });
});

console.log("WebSocket server running on ws://localhost:8080");

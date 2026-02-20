const WebSocket = require("ws");
const Redis = require("ioredis");

const wss = new WebSocket.Server({ port: 8080 });
const redis = new Redis(process.env.UPSTASH_REDIS_URL);

// Parse channels from environment: CHANNELS="channel1:password1|channel2:password2"
const CHANNELS = (() => {
  const channelStr = process.env.CHANNELS || "test:test";
  const map = new Map();
  if (channelStr) {
    const pairs = channelStr.split("|");
    for (const pair of pairs) {
      const [channel, password] = pair.split(":");
      if (channel && password) {
        map.set(channel, password);
      }
    }
  }
  return map;
})();

console.log(`Loaded ${CHANNELS.size} channels from CHANNELS env var`);

const scanners = new Map(); // Store { ws, metadata, channel }
const listeners = new Map(); // Store { ws, channel } indexed by WebSocket

function color(e, c = 0) {
  const l = ["grey", "red", "green", "yellow", "blue", "magenta", "cyan", "white"];
  c = l.indexOf(c);
  if (c === -1) c = 0;
  return `\x1b[3${c}m${e}\x1b[0m`;
}

function broadcastOnlineDevices(channel) {
  const devices = [];
  const metadataMap = {};
  
  scanners.forEach((val, key) => {
    if (val.channel === channel) {
      devices.push(key);
      metadataMap[key] = val.metadata;
    }
  });

  const payload = JSON.stringify({ type: "online_devices", devices, metadataMap });
  listeners.forEach((listenerData, listenerWs) => {
    if (listenerData.channel === channel && listenerWs.readyState === WebSocket.OPEN) {
      listenerWs.send(payload);
    }
  });
}

function broadcastListenerCount(channel) {
  let count = 0;
  listeners.forEach((listenerData) => {
    if (listenerData.channel === channel) count++;
  });
  
  listeners.forEach((listenerData, listenerWs) => {
    if (listenerData.channel === channel && listenerWs.readyState === WebSocket.OPEN) {
      listenerWs.send(JSON.stringify({ type: "listener_count", count }));
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
  let channel = null;
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
      const channelId = data.channel;
      const password = data.password;

      // Verify channel exists and password is correct
      if (!channelId || !CHANNELS.has(channelId)) {
        return safeSend(ws, { type: "auth", status: "fail", error: "Channel does not exist" });
      }

      if (CHANNELS.get(channelId) !== password) {
        return safeSend(ws, { type: "auth", status: "fail", error: "Invalid password" });
      }

      // Determine role based on password match
      authed = true;
      channel = channelId;
      role = "scanner"; // For now, all auth are scanners. Listeners would have different role logic if needed

      userScannerId = data.scannerId || "Unknown User";
      startTime = new Date().toISOString();

      currentMetadata = {
        ...(data.metadata || {}),
        scanner_user_id: userScannerId,
        last_connected: startTime,
        current_session_scans: 0,
        name: data.metadata?.device || "Unknown Device",
        ip: data.metadata?.ip || clientIp
      };

      try {
        // Store device info in channel devices key
        const devicesKey = `channel:${channel}:devices`;
        const deviceId = `${userScannerId}:${clientIp}`;
        await redis.hset(devicesKey, deviceId, JSON.stringify(currentMetadata));
      } catch (e) {
        console.error("Redis Error (Auth):", e.message);
      }

      scanners.set(clientIp, { ws, metadata: currentMetadata, channel });
      console.log(color(`Scanner Connected | Channel: ${channel} | User: ${userScannerId} | IP: ${clientIp}`, "green"));
      safeSend(ws, { type: "auth", status: "success", role: "scanner", channel, userId: userScannerId });

      broadcastOnlineDevices(channel);
      broadcastListenerCount(channel);
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
        color: data.color || "grey",
      };

      const num = Number.isInteger(data.num) ? data.num : (typeof data.num === 'string' && /^[0-9]+$/.test(data.num) ? parseInt(data.num, 10) : null);
      if (num !== null) record.num = num;

      console.log(`${color(record.time, "grey")} ${color(userScannerId, "cyan")} (${color(clientIp, "blue")}): ${color(record.data, record.color)}${num !== null ? (' #' + num) : ''}`);

      try {
        // Store scan in channel scans key
        const scansKey = `channel:${channel}:scans`;
        const scanId = `${Date.now()}:${num || Math.random()}`;
        await redis.hset(scansKey, scanId, JSON.stringify(record));
      } catch (e) {
        console.error("Redis Error (Scan):", e.message);
      }

      // Broadcast to all listeners of this channel
      listeners.forEach((listenerData, l) => {
        if (listenerData.channel === channel) {
          safeSend(l, { type: "scan", ...record });
        }
      });

      if (num !== null) {
        safeSend(ws, { type: "received", num: num, status: "success" });
      }
    }

    if (role === "listener" && data.type === "resend_request") {
      const target = data.scannerId || data.ip;
      const reqNum = data.num;
      if (!target || reqNum == null) return;

      const scannerEntry = scanners.get(target);
      if (scannerEntry && scannerEntry.channel === channel) {
        safeSend(scannerEntry.ws, { type: "resend", num: reqNum });
      }
    }
  });

  ws.on("close", async () => {
    if (role === "scanner") {
      scanners.delete(clientIp);
      try {
        // Remove device from channel devices key
        const devicesKey = `channel:${channel}:devices`;
        const deviceId = `${userScannerId}:${clientIp}`;
        await redis.hdel(devicesKey, deviceId);
      } catch (e) {
        console.error("Redis Error (Close):", e.message);
      }
      console.log(color(`Scanner Disconnected | Channel: ${channel} | User: ${userScannerId} | IP: ${clientIp}`, "red"));
      if (channel) {
        broadcastOnlineDevices(channel);
        broadcastListenerCount(channel);
      }
    } else if (role === "listener") {
      listeners.delete(ws);
      if (channel) {
        broadcastListenerCount(channel);
      }
    }
  });

  ws.on("error", (e) => {
    console.error("WS Client Error:", e.message);
  });
});

console.log("WebSocket server running on ws://localhost:8080");

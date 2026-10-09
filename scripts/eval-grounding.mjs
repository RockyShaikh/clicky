#!/usr/bin/env node
// Grounding eval: for each fixture in test-fixtures/screens/targets.json, send /v1/ask to the
// bridge, wait for the matching `respond` SSE event, and score a HIT if the primary shape's
// point (or box center) falls inside target_box_px. Prints hit rate and p50/p90 latency.
//
// Usage:
//   node scripts/eval-grounding.mjs                 # live bridge (reads ~/.clicky/bridge.json + bridge-token)
//   node scripts/eval-grounding.mjs --selftest      # built-in mock bridge; verifies scoring, no network/model
//   Options: --limit N  --only substring  --pad PX (tolerance around the box, default 0)
//            --timeout-ms MS (default 90000)  --json (machine-readable output)  --mode auto|point|do
//            --snap (reserved: score after WS4 accessibility snapping once a CLI snapper exists)
//
// The live run needs a bridge connected to a Claude Code session (see CONTRACTS.md). That session
// must be launched with ANTHROPIC_API_KEY unset and without --bare (scripts/clicky-session.sh does this).
import { readFileSync, existsSync } from "node:fs";
import { createServer } from "node:http";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes } from "node:crypto";

const rootDirectory = join(dirname(fileURLToPath(import.meta.url)), "..");
const screensDirectory = join(rootDirectory, "test-fixtures", "screens");

// ---------- pure helpers (exported for tests) ----------

export function shapeAnchorPoint(shape) {
  switch (shape.kind) {
    case "box":
    case "highlight":
      return [(shape.x + shape.x2) / 2, (shape.y + shape.y2) / 2];
    case "path": {
      const points = shape.points ?? [];
      if (points.length === 0) return null;
      const sum = points.reduce((total, point) => [total[0] + point[0], total[1] + point[1]], [0, 0]);
      return [sum[0] / points.length, sum[1] / points.length];
    }
    default: // circle, arrow (points AT x,y), label
      return typeof shape.x === "number" && typeof shape.y === "number" ? [shape.x, shape.y] : null;
  }
}

// Primary = emphasis "primary" if present; otherwise the first shape that has an anchor point.
export function selectPrimaryShape(shapes) {
  const explicitPrimary = shapes.find((shape) => shape.emphasis === "primary");
  if (explicitPrimary) return explicitPrimary;
  return shapes.find((shape) => shapeAnchorPoint(shape) !== null) ?? null;
}

export function scoreResponse(respondData, targetBox, padInPixels = 0) {
  const shapes = respondData.shapes ?? respondData.steps?.[0]?.shapes ?? [];
  const primaryShape = selectPrimaryShape(shapes);
  if (!primaryShape) return { hit: false, reason: "no_shape", point: null };
  const point = shapeAnchorPoint(primaryShape);
  const [x1, y1, x2, y2] = targetBox;
  const hit = point[0] >= x1 - padInPixels && point[0] <= x2 + padInPixels &&
              point[1] >= y1 - padInPixels && point[1] <= y2 + padInPixels;
  const targetCenter = [(x1 + x2) / 2, (y1 + y2) / 2];
  const distance = Math.hypot(point[0] - targetCenter[0], point[1] - targetCenter[1]);
  return { hit, reason: hit ? "hit" : "miss", point, distanceFromTargetCenter: Math.round(distance) };
}

export function percentile(sortedValues, fraction) {
  if (sortedValues.length === 0) return null;
  const index = Math.min(sortedValues.length - 1, Math.ceil(fraction * sortedValues.length) - 1);
  return sortedValues[Math.max(0, index)];
}

export function newRequestID() {
  const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
  const bytes = randomBytes(10);
  return "r_" + [...bytes].map((byte) => alphabet[byte % 32]).join("");
}

// ---------- SSE client ----------

class EventStreamClient {
  constructor(baseURL, token) {
    this.baseURL = baseURL; this.token = token;
    this.waiters = []; // {requestID, resolve}
    this.abortController = new AbortController();
  }
  async connect() {
    const response = await fetch(`${this.baseURL}/v1/events`, {
      headers: { Authorization: `Bearer ${this.token}` }, signal: this.abortController.signal,
    });
    if (!response.ok) throw new Error(`/v1/events returned HTTP ${response.status}`);
    this.pump(response.body).catch(() => {});
  }
  async pump(body) {
    const decoder = new TextDecoder();
    let buffer = "";
    for await (const chunk of body) {
      buffer += decoder.decode(chunk, { stream: true });
      let separatorIndex;
      while ((separatorIndex = buffer.indexOf("\n\n")) !== -1) {
        const rawMessage = buffer.slice(0, separatorIndex);
        buffer = buffer.slice(separatorIndex + 2);
        this.dispatch(rawMessage);
      }
    }
  }
  dispatch(rawMessage) {
    let eventType = "message"; const dataLines = [];
    for (const line of rawMessage.split("\n")) {
      if (line.startsWith("event:")) eventType = line.slice(6).trim();
      else if (line.startsWith("data:")) dataLines.push(line.slice(5).trim());
    }
    if (dataLines.length === 0) return;
    let data; try { data = JSON.parse(dataLines.join("\n")); } catch { return; }
    for (const waiter of [...this.waiters]) {
      if (data.request_id === waiter.requestID && (eventType === "respond" || eventType === "error")) {
        this.waiters = this.waiters.filter((other) => other !== waiter);
        waiter.resolve({ eventType, data });
      }
    }
  }
  waitForRequest(requestID, timeoutMs) {
    return new Promise((resolvePromise) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((waiter) => waiter.requestID !== requestID);
        resolvePromise({ eventType: "timeout", data: null });
      }, timeoutMs);
      this.waiters.push({ requestID, resolve: (result) => { clearTimeout(timer); resolvePromise(result); } });
    });
  }
  close() { this.abortController.abort(); }
}

// ---------- mock bridge for --selftest ----------

function startMockBridge(targets) {
  const token = "selftest-token";
  const targetByRequestID = new Map();
  let eventResponse = null; let askCount = 0;
  const server = createServer((request, response) => {
    if (request.headers.authorization !== `Bearer ${token}`) { response.writeHead(401).end(); return; }
    if (request.url === "/v1/events") {
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.write('event: hello\ndata: {"version":"1.0"}\n\n');
      eventResponse = response; return;
    }
    if (request.url === "/v1/ask" && request.method === "POST") {
      let body = ""; request.on("data", (chunk) => (body += chunk));
      request.on("end", () => {
        const ask = JSON.parse(body); askCount += 1;
        const target = targets.find((entry) => ask.screens[0].image_path.endsWith(entry.file));
        response.writeHead(202, { "Content-Type": "application/json" }).end('{"accepted":true}');
        // Every 5th ask misses on purpose (circle far from the target) so the scorer is exercised both ways.
        const [x1, y1, x2, y2] = target.target_box_px;
        const shouldMiss = askCount % 5 === 0;
        const shape = shouldMiss
          ? { kind: "circle", x: 5, y: 5, r: 20, emphasis: "primary" }
          : { kind: "box", x: x1, y: y1, x2, y2, emphasis: "primary" };
        setTimeout(() => eventResponse.write(`event: respond\ndata: ${JSON.stringify({
          request_id: ask.request_id, say: "mock", screen_index: 1, shapes: [shape], expect_click: false, final: true,
        })}\n\n`), 20 + (askCount % 3) * 10);
      });
      return;
    }
    response.writeHead(404).end();
  });
  return new Promise((resolvePromise) => server.listen(0, "127.0.0.1", () =>
    resolvePromise({ server, token, port: server.address().port })));
}

// ---------- main ----------

function parseArguments(argumentList) {
  const options = { limit: Infinity, only: null, pad: 0, timeoutMs: 90000, json: false, selftest: false, snap: false, mode: "point" };
  for (let index = 0; index < argumentList.length; index++) {
    const argument = argumentList[index];
    if (argument === "--limit") options.limit = Number(argumentList[++index]);
    else if (argument === "--only") options.only = argumentList[++index];
    else if (argument === "--pad") options.pad = Number(argumentList[++index]);
    else if (argument === "--timeout-ms") options.timeoutMs = Number(argumentList[++index]);
    else if (argument === "--mode") options.mode = argumentList[++index];
    else if (argument === "--json") options.json = true;
    else if (argument === "--selftest") options.selftest = true;
    else if (argument === "--snap") options.snap = true;
    else { console.error(`Unknown argument: ${argument}`); process.exit(2); }
  }
  return options;
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.snap) console.error("note: --snap is not implemented yet (needs a CLI-callable WS4 snapper); scoring raw coordinates.");

  let targets = JSON.parse(readFileSync(join(screensDirectory, "targets.json"), "utf8"));
  if (options.only) targets = targets.filter((entry) => entry.file.includes(options.only));
  targets = targets.slice(0, options.limit);

  let baseURL; let token; let mock = null;
  if (options.selftest) {
    mock = await startMockBridge(targets);
    baseURL = `http://127.0.0.1:${mock.port}`; token = mock.token;
  } else {
    const bridgeInfoPath = join(homedir(), ".clicky", "bridge.json");
    const tokenPath = join(homedir(), ".clicky", "bridge-token");
    const port = process.env.CLICKY_BRIDGE_PORT ??
      (existsSync(bridgeInfoPath) ? JSON.parse(readFileSync(bridgeInfoPath, "utf8")).port : 8977);
    if (!existsSync(tokenPath)) { console.error("No ~/.clicky/bridge-token. Is the bridge running?"); process.exit(1); }
    token = readFileSync(tokenPath, "utf8").trim(); baseURL = `http://127.0.0.1:${port}`;
    const health = await fetch(`${baseURL}/v1/health`, { headers: { Authorization: `Bearer ${token}` } }).catch(() => null);
    if (!health?.ok) { console.error(`Bridge not reachable at ${baseURL}`); process.exit(1); }
    const healthBody = await health.json();
    if (!healthBody.channel_registered) console.error("warning: channel_registered is false; Claude Code may not be connected yet.");
  }

  const eventStream = new EventStreamClient(baseURL, token);
  await eventStream.connect();

  const results = [];
  for (const target of targets) {
    const requestID = newRequestID();
    const imagePath = resolve(screensDirectory, target.file);
    const askBody = {
      request_id: requestID, mode: options.mode, utterance: target.question,
      screens: [{ screen_index: 1, image_path: imagePath, width_px: target.width_px, height_px: target.height_px,
                  label: "cursor screen (primary focus)", is_cursor_screen: true }],
      frontmost_app: { name: target.app_name, bundle_id: target.app_bundle_id, window_title: target.window_title },
      sent_at: new Date().toISOString(),
    };
    const startedAt = performance.now();
    const waitPromise = eventStream.waitForRequest(requestID, options.timeoutMs);
    const askResponse = await fetch(`${baseURL}/v1/ask`, {
      method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify(askBody),
    });
    if (askResponse.status !== 202) {
      results.push({ file: target.file, hit: false, reason: `ask_http_${askResponse.status}`, latencyMs: null });
      continue;
    }
    const { eventType, data } = await waitPromise;
    const latencyMs = Math.round(performance.now() - startedAt);
    if (eventType !== "respond") {
      results.push({ file: target.file, hit: false, reason: eventType === "error" ? `error: ${data.message}` : "timeout", latencyMs: eventType === "timeout" ? null : latencyMs });
    } else {
      results.push({ file: target.file, latencyMs, ...scoreResponse(data, target.target_box_px, options.pad) });
    }
    if (!options.json) console.log(`${results.at(-1).hit ? "HIT " : "MISS"} ${target.file.padEnd(32)} ${String(latencyMs).padStart(6)} ms  ${results.at(-1).reason}${results.at(-1).distanceFromTargetCenter !== undefined ? ` (off by ${results.at(-1).distanceFromTargetCenter}px)` : ""}`);
  }
  eventStream.close();
  mock?.server.close();

  const hits = results.filter((result) => result.hit).length;
  const sortedLatencies = results.map((result) => result.latencyMs).filter((value) => value !== null).sort((a, b) => a - b);
  const summary = {
    total: results.length, hits, hit_rate: results.length ? Number((hits / results.length).toFixed(3)) : 0,
    latency_ms_p50: percentile(sortedLatencies, 0.5), latency_ms_p90: percentile(sortedLatencies, 0.9),
    pad_px: options.pad, mode: options.mode, selftest: options.selftest,
  };
  if (options.json) console.log(JSON.stringify({ summary, results }, null, 2));
  else console.log(`\nhit rate ${hits}/${results.length} = ${(summary.hit_rate * 100).toFixed(1)}%   p50 ${summary.latency_ms_p50} ms   p90 ${summary.latency_ms_p90} ms`);
  if (options.selftest) {
    // 25 fixtures, every 5th ask misses by construction -> exactly 5 misses expected on a full run.
    const expectedMisses = Math.floor(results.length / 5);
    if (results.length - hits !== expectedMisses) { console.error("SELFTEST FAILED: scorer disagrees with mock bridge"); process.exit(1); }
    console.log("selftest ok");
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();

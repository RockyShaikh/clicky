import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { createBridgeHttpServer } from "../src/http.js";
import { BridgeState, loadOrCreateBridgeToken } from "../src/state.js";
import { handleConfirm, handleLook, handleRespond, handleStatus } from "../src/tools.js";

const testHome = mkdtempSync(join(tmpdir(), "clicky-bridge-test-"));
process.env.CLICKY_HOME = testHome;
mkdirSync(join(testHome, "shots"), { recursive: true });
const shotPath = join(testHome, "shots", "r_aaaaaaaaaa-s1.jpg");
writeFileSync(shotPath, Buffer.from([0xff, 0xd8, 0xff, 0xd9]));
const outsidePath = join(testHome, "secret.jpg");
writeFileSync(outsidePath, "nope");
symlinkSync(outsidePath, join(testHome, "shots", "link.jpg"));

const requestID = "r_aaaaaaaaaa";
const screen = { screen_index: 1, image_path: shotPath, width_px: 1280, height_px: 831, label: "cursor screen", is_cursor_screen: true };
const askBody = { request_id: requestID, mode: "auto", utterance: "where is the font size", screens: [screen] };

describe("token", () => {
  test("creates a 64-hex token with mode 0600 and reuses it", () => {
    const token = loadOrCreateBridgeToken();
    assert.match(token, /^[0-9a-f]{64}$/);
    assert.equal(statSync(join(testHome, "bridge-token")).mode & 0o777, 0o600);
    assert.equal(loadOrCreateBridgeToken(), token);
  });
});

describe("tools", () => {
  test("look returns image + text, refuses outside and symlinked paths, unknown ids", () => {
    const state = new BridgeState();
    state.registerAsk(requestID, [screen]);
    const result = handleLook(state, { request_id: requestID });
    assert.equal(result.content[0].type, "image");
    assert.match((result.content[1] as { text: string }).text, /screen 1 of 1, 1280x831 px, origin top-left, cursor screen/);

    state.registerAsk("r_bbbbbbbbbb", [{ ...screen, image_path: outsidePath }]);
    assert.equal(handleLook(state, { request_id: "r_bbbbbbbbbb" }).isError, true);
    state.registerAsk("r_cccccccccc", [{ ...screen, image_path: join(testHome, "shots", "link.jpg") }]);
    assert.equal(handleLook(state, { request_id: "r_cccccccccc" }).isError, true);
    assert.equal(handleLook(state, { request_id: "r_zzzzzzzzzz" }).isError, true);
  });

  test("newest ask supersedes older; respond to superseded is rejected and not broadcast", () => {
    const state = new BridgeState();
    state.registerAsk("r_aaaaaaaaaa", [screen]);
    state.registerAsk("r_bbbbbbbbbb", [screen]);
    const result = handleRespond(state, { request_id: "r_aaaaaaaaaa", say: "hi", shapes: [] });
    assert.equal(result.isError, true);
    assert.equal(handleRespond(state, { request_id: "r_bbbbbbbbbb", say: "hi", shapes: [] }).isError, undefined);
  });

  test("status and confirm reply text", () => {
    const state = new BridgeState();
    state.registerAsk(requestID, [screen]);
    assert.equal((handleStatus(state, { request_id: requestID, text: "working" }).content[0] as { text: string }).text, "ok");
    assert.match((handleConfirm(state, { request_id: requestID, question: "send it?" }).content[0] as { text: string }).text, /end your turn/);
  });
});

describe("http", () => {
  const state = new BridgeState();
  const token = "a".repeat(64);
  const notified: Array<{ content: string; meta: Record<string, string> }> = [];
  const server = createBridgeHttpServer({
    state,
    token,
    notifyChannel: async (content, meta) => {
      notified.push({ content, meta });
    },
  });
  let baseURL = "";
  const auth = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };

  before(async () => {
    await new Promise<void>((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
    baseURL = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  after(() => {
    state.closeAllServerSentEventClients();
    server.close();
  });

  test("health requires a token", async () => {
    assert.equal((await fetch(`${baseURL}/v1/health`)).status, 401);
    assert.equal((await fetch(`${baseURL}/v1/health`, { headers: { Authorization: "Bearer nope" } })).status, 401);
    const response = await fetch(`${baseURL}/v1/health`, { headers: auth });
    assert.deepEqual(await response.json(), { ok: true, channel_registered: false, version: "1.0" });
  });

  test("ask emits a channel event with safe meta keys; bad body is 400; >1MB is 413", async () => {
    const response = await fetch(`${baseURL}/v1/ask`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({ ...askBody, frontmost_app: { name: "Notes", window_title: "line1\nline2" }, browser_tab: { url: "https://x.test" } }),
    });
    assert.equal(response.status, 202);
    const event = notified.at(-1)!;
    assert.equal(event.content, "where is the font size");
    assert.equal(event.meta.kind, "ask");
    assert.equal(event.meta.request_id, requestID);
    assert.equal(event.meta.screens, "1");
    assert.equal(event.meta.window_title, "line1 line2");
    for (const key of Object.keys(event.meta)) assert.match(key, /^[A-Za-z0-9_]+$/);

    const bad = await fetch(`${baseURL}/v1/ask`, { method: "POST", headers: auth, body: JSON.stringify({ request_id: "x" }) });
    assert.equal(bad.status, 400);
    const huge = await fetch(`${baseURL}/v1/ask`, { method: "POST", headers: auth, body: "x".repeat(1024 * 1024 + 10) }).catch(() => null);
    if (huge) assert.equal(huge.status, 413);
  });

  test("followups map to channel events; cancel marks request cancelled", async () => {
    await fetch(`${baseURL}/v1/ask`, { method: "POST", headers: auth, body: JSON.stringify(askBody) });
    let response = await fetch(`${baseURL}/v1/followup`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({ request_id: requestID, kind: "confirmation", answer: "yes", utterance: "yes go ahead" }),
    });
    assert.equal(response.status, 202);
    assert.equal(notified.at(-1)!.meta.kind, "confirmation");
    assert.match(notified.at(-1)!.content, /answer: yes/);
    response = await fetch(`${baseURL}/v1/followup`, { method: "POST", headers: auth, body: JSON.stringify({ request_id: requestID, kind: "step_done", step_index: 1 }) });
    assert.equal(notified.at(-1)!.meta.step_index, "1");
    await fetch(`${baseURL}/v1/followup`, { method: "POST", headers: auth, body: JSON.stringify({ request_id: requestID, kind: "cancel" }) });
    assert.equal(state.requests.get(requestID)!.status, "cancelled");
  });

  test("SSE: hello, then respond/status/confirm broadcasts arrive in order", async () => {
    await fetch(`${baseURL}/v1/ask`, { method: "POST", headers: auth, body: JSON.stringify({ ...askBody, request_id: "r_dddddddddd" }) });
    const controller = new AbortController();
    const response = await fetch(`${baseURL}/v1/events`, { headers: auth, signal: controller.signal });
    assert.match(response.headers.get("content-type") ?? "", /text\/event-stream/);
    const reader = response.body!.getReader();
    const decoder = new TextDecoder();
    let received = "";
    const readUntil = async (needle: string) => {
      while (!received.includes(needle)) {
        const { value, done } = await reader.read();
        if (done) break;
        received += decoder.decode(value);
      }
    };
    await readUntil("event: hello");
    handleStatus(state, { request_id: "r_dddddddddd", text: "working" });
    handleConfirm(state, { request_id: "r_dddddddddd", question: "send it?" });
    handleRespond(state, {
      request_id: "r_dddddddddd",
      say: "there",
      shapes: [{ kind: "circle", x: 10, y: 10, r: 5, emphasis: "primary" }],
    });
    await readUntil("event: respond");
    controller.abort();
    assert.ok(received.indexOf("event: status") < received.indexOf("event: confirm"));
    assert.ok(received.indexOf("event: confirm") < received.indexOf("event: respond"));
    assert.match(received, /"final":true/);
  });
});

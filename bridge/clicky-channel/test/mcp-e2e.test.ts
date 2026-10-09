import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { z } from "zod";

// Spawns the built server over stdio exactly like Claude Code would and exercises the MCP surface.
test("stdio MCP: capabilities, tools, and channel notification", async () => {
  const home = mkdtempSync(join(tmpdir(), "clicky-e2e-"));
  mkdirSync(join(home, "shots"));
  writeFileSync(join(home, "shots", "r_aaaaaaaaaa-s1.jpg"), Buffer.from([0xff, 0xd8, 0xff, 0xd9]));
  const port = 20000 + Math.floor(Math.random() * 20000);
  const serverPath = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "dist", "index.js");

  const client = new Client({ name: "fake-claude-code", version: "0" }, { capabilities: {} });
  const channelEvents: Array<{ content: string; meta: Record<string, string> }> = [];
  client.setNotificationHandler(
    z.object({ method: z.literal("notifications/claude/channel"), params: z.object({ content: z.string(), meta: z.record(z.string()) }) }),
    async (notification) => {
      channelEvents.push(notification.params);
    },
  );
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    env: { ...process.env, CLICKY_HOME: home, CLICKY_BRIDGE_PORT: String(port) } as Record<string, string>,
  });
  await client.connect(transport);
  try {
    const capabilities = client.getServerCapabilities()!;
    assert.deepEqual(capabilities.experimental, { "claude/channel": {} });
    assert.ok(capabilities.tools);
    assert.equal(client.getServerVersion()!.name, "clicky");
    assert.match(client.getInstructions() ?? "", /look/);
    const tools = (await client.listTools()).tools.map((tool) => tool.name).sort();
    assert.deepEqual(tools, ["confirm", "look", "respond", "status"]);

    const token = readFileSync(join(home, "bridge-token"), "utf8").trim();
    const headers = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
    const health = await (await fetch(`http://127.0.0.1:${port}/v1/health`, { headers })).json();
    assert.equal((health as { channel_registered: boolean }).channel_registered, true);

    await fetch(`http://127.0.0.1:${port}/v1/ask`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        request_id: "r_aaaaaaaaaa",
        utterance: "hello",
        screens: [{ screen_index: 1, image_path: join(home, "shots", "r_aaaaaaaaaa-s1.jpg"), width_px: 10, height_px: 10, label: "x", is_cursor_screen: true }],
      }),
    });
    for (let attempt = 0; attempt < 50 && channelEvents.length === 0; attempt++) await new Promise((r) => setTimeout(r, 50));
    assert.equal(channelEvents[0]?.meta.kind, "ask");

    const looked = await client.callTool({ name: "look", arguments: { request_id: "r_aaaaaaaaaa" } });
    assert.equal((looked.content as Array<{ type: string }>)[0].type, "image");
    const bad = await client.callTool({ name: "respond", arguments: { request_id: "r_aaaaaaaaaa", say: "x", shapes: new Array(7).fill({ kind: "circle", x: 1, y: 1, r: 1 }) } });
    assert.equal(bad.isError, true);
    const good = await client.callTool({ name: "respond", arguments: { request_id: "r_aaaaaaaaaa", say: "x", shapes: [] } });
    assert.equal((good.content as Array<{ text: string }>)[0].text, "shown");
  } finally {
    await client.close();
  }
});

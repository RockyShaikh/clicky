import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createBridgeHttpServer } from "./http.js";
import {
  BridgeState,
  loadOrCreateBridgeToken,
  logLine,
  writeBridgeInfoFile,
} from "./state.js";
import {
  confirmInputShape,
  handleConfirm,
  handleLook,
  handleRespond,
  handleStatus,
  lookInputShape,
  respondInputShape,
  statusInputShape,
} from "./tools.js";

const CHANNEL_INSTRUCTIONS = `Events from source="clicky" are the user speaking to you through the Clicky screen companion. kind=ask: a spoken request; the screenshot is NOT in the event. ALWAYS call the look tool with its request_id before answering. Answer ONLY by calling respond; plain text is never shown or spoken. Shape coordinates are pixels of the image look returned, origin top-left. kind=confirmation is the user's yes/no to a confirm you sent; kind=step_done means they finished a walkthrough step; kind=cancel means stop and respond with nothing. If several asks are queued, handle only the newest. For web tasks, call status every few actions; before any submit/send/purchase/delete call confirm, then end your turn and wait. Full rules are in the session CLAUDE.md.`;

const port = Number(process.env.CLICKY_BRIDGE_PORT ?? 8977);
const state = new BridgeState();
const token = loadOrCreateBridgeToken();

const mcpServer = new McpServer(
  { name: "clicky", version: "1.0.0" },
  {
    capabilities: { experimental: { "claude/channel": {} }, tools: {} },
    instructions: CHANNEL_INSTRUCTIONS,
  },
);

mcpServer.server.oninitialized = () => {
  state.channelRegistered = true;
  logLine("mcp initialized (channel_registered=true)");
};

mcpServer.registerTool(
  "look",
  {
    description: "Fetch the screenshot for an ask. Returns the image plus its pixel size. Call before answering any ask.",
    inputSchema: lookInputShape,
  },
  async (input) => handleLook(state, input),
);
mcpServer.registerTool(
  "respond",
  {
    description:
      "Deliver your answer: say (spoken aloud, 1-2 sentences, no markdown), up to 6 shapes in pixels of the image from look (at most one emphasis:primary), optional steps for walkthroughs.",
    inputSchema: respondInputShape,
  },
  async (input) => handleRespond(state, input),
);
mcpServer.registerTool(
  "status",
  { description: "Short progress line shown in a bubble while you work (do mode).", inputSchema: statusInputShape },
  async (input) => handleStatus(state, input),
);
mcpServer.registerTool(
  "confirm",
  {
    description: "Ask the user a yes/no question out loud before a risky action. After calling, end your turn and wait.",
    inputSchema: confirmInputShape,
  },
  async (input) => handleConfirm(state, input),
);

async function notifyChannel(content: string, meta: Record<string, string>): Promise<void> {
  await mcpServer.server.notification({ method: "notifications/claude/channel", params: { content, meta } });
}

const httpServer = createBridgeHttpServer({ state, token, notifyChannel });
httpServer.on("error", (error: NodeJS.ErrnoException) => {
  // Most likely a second instance (e.g. a headless run) while the main session owns the port.
  logLine(`http server error: ${error.code ?? ""} ${error.message}; continuing as MCP-only`);
});
httpServer.listen(port, "127.0.0.1", () => {
  writeBridgeInfoFile(port);
  logLine(`listening on 127.0.0.1:${port} pid=${process.pid}`);
});

await mcpServer.connect(new StdioServerTransport());

function shutDown(): void {
  state.closeAllServerSentEventClients();
  httpServer.close();
  process.exit(0);
}
process.on("SIGTERM", shutDown);
process.on("SIGINT", shutDown);
process.stdin.on("close", shutDown);

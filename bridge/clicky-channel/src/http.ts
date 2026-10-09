import { timingSafeEqual } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { z } from "zod";
import { BRIDGE_VERSION, BridgeState, logLine } from "./state.js";

const MAXIMUM_BODY_BYTES = 1024 * 1024;
const HEARTBEAT_INTERVAL_MILLISECONDS = 15_000;

/** Delivers a `<channel>` event into the Claude Code session. */
export type ChannelNotifier = (content: string, meta: Record<string, string>) => Promise<void>;

const screenSchema = z.object({
  screen_index: z.number().int().positive(),
  image_path: z.string(),
  width_px: z.number().int().positive(),
  height_px: z.number().int().positive(),
  label: z.string().default(""),
  is_cursor_screen: z.boolean().default(false),
});

export const askSchema = z.object({
  request_id: z.string().regex(/^r_[a-z2-7]{10}$/),
  mode: z.enum(["auto", "point", "do"]).default("auto"),
  utterance: z.string().min(1).max(8000),
  screens: z.array(screenSchema).min(1).max(8),
  frontmost_app: z
    .object({
      name: z.string().optional(),
      bundle_id: z.string().optional(),
      window_title: z.string().optional(),
    })
    .optional(),
  browser_tab: z.object({ url: z.string().optional(), title: z.string().optional() }).optional(),
  sent_at: z.string().optional(),
});

export const followupSchema = z.discriminatedUnion("kind", [
  z.object({
    request_id: z.string(),
    kind: z.literal("confirmation"),
    answer: z.enum(["yes", "no"]),
    utterance: z.string().default(""),
  }),
  z.object({ request_id: z.string(), kind: z.literal("step_done"), step_index: z.number().int().nonnegative() }),
  z.object({ request_id: z.string(), kind: z.literal("cancel") }),
]);

/** Channel meta values must be single-line strings; keys are letters/digits/underscores (others are silently dropped). */
function metaValue(value: string | undefined): string {
  return (value ?? "").replace(/[\r\n]+/g, " ").slice(0, 300);
}

export function buildAskChannelEvent(ask: z.infer<typeof askSchema>): { content: string; meta: Record<string, string> } {
  return {
    content: ask.utterance,
    meta: {
      kind: "ask",
      request_id: ask.request_id,
      mode: ask.mode,
      screens: String(ask.screens.length),
      app: metaValue(ask.frontmost_app?.name),
      bundle_id: metaValue(ask.frontmost_app?.bundle_id),
      window_title: metaValue(ask.frontmost_app?.window_title),
      tab_url: metaValue(ask.browser_tab?.url),
      tab_title: metaValue(ask.browser_tab?.title),
    },
  };
}

export function buildFollowupChannelEvent(followup: z.infer<typeof followupSchema>): { content: string; meta: Record<string, string> } {
  const baseMeta = { kind: followup.kind, request_id: followup.request_id };
  switch (followup.kind) {
    case "confirmation":
      return {
        content: `answer: ${followup.answer}${followup.utterance ? `\n${followup.utterance}` : ""}`,
        meta: baseMeta,
      };
    case "step_done":
      return { content: `the user completed step ${followup.step_index}`, meta: { ...baseMeta, step_index: String(followup.step_index) } };
    case "cancel":
      return { content: "the user cancelled this request; stop and respond nothing", meta: baseMeta };
  }
}

function sendJson(response: ServerResponse, statusCode: number, body: unknown): void {
  const payload = JSON.stringify(body);
  response.writeHead(statusCode, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) });
  response.end(payload);
}

class BodyTooLargeError extends Error {}

function readJsonBody(request: IncomingMessage): Promise<unknown> {
  return new Promise((resolvePromise, rejectPromise) => {
    const chunks: Buffer[] = [];
    let totalBytes = 0;
    request.on("data", (chunk: Buffer) => {
      totalBytes += chunk.length;
      if (totalBytes > MAXIMUM_BODY_BYTES) {
        rejectPromise(new BodyTooLargeError());
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => {
      try {
        resolvePromise(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        rejectPromise(new SyntaxError("invalid JSON"));
      }
    });
    request.on("error", rejectPromise);
  });
}

function isLoopbackAddress(address: string | undefined): boolean {
  return address === "127.0.0.1" || address === "::1" || address === "::ffff:127.0.0.1";
}

function bearerTokenMatches(authorizationHeader: string | undefined, expectedToken: string): boolean {
  const presentedToken = /^Bearer (.+)$/.exec(authorizationHeader ?? "")?.[1] ?? "";
  const presentedBuffer = Buffer.from(presentedToken);
  const expectedBuffer = Buffer.from(expectedToken);
  return presentedBuffer.length === expectedBuffer.length && timingSafeEqual(presentedBuffer, expectedBuffer);
}

export function createBridgeHttpServer(options: {
  state: BridgeState;
  token: string;
  notifyChannel: ChannelNotifier;
}): Server {
  const { state, token, notifyChannel } = options;

  const server = createServer(async (request, response) => {
    try {
      if (!isLoopbackAddress(request.socket.remoteAddress)) return sendJson(response, 403, { error: "loopback only" });
      if (!bearerTokenMatches(request.headers.authorization, token)) return sendJson(response, 401, { error: "bad token" });

      const path = (request.url ?? "").split("?")[0];

      if (request.method === "GET" && path === "/v1/health") {
        return sendJson(response, 200, { ok: true, channel_registered: state.channelRegistered, version: BRIDGE_VERSION });
      }

      if (request.method === "GET" && path === "/v1/events") {
        response.writeHead(200, {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
        });
        response.write(`event: hello\ndata: ${JSON.stringify({ version: BRIDGE_VERSION })}\n\n`);
        state.addServerSentEventClient(response);
        const heartbeatTimer = setInterval(() => {
          response.write(`event: heartbeat\ndata: {}\n\n`);
        }, HEARTBEAT_INTERVAL_MILLISECONDS);
        response.on("close", () => clearInterval(heartbeatTimer));
        return;
      }

      if (request.method === "POST" && (path === "/v1/ask" || path === "/v1/followup")) {
        let body: unknown;
        try {
          body = await readJsonBody(request);
        } catch (error) {
          if (error instanceof BodyTooLargeError) return sendJson(response, 413, { error: "body too large" });
          return sendJson(response, 400, { error: "invalid JSON" });
        }

        if (path === "/v1/ask") {
          const parsedAsk = askSchema.safeParse(body);
          if (!parsedAsk.success) return sendJson(response, 400, { error: parsedAsk.error.message });
          const ask = parsedAsk.data;
          state.registerAsk(ask.request_id, ask.screens);
          const channelEvent = buildAskChannelEvent(ask);
          logLine(`ask ${ask.request_id} mode=${ask.mode} screens=${ask.screens.length} registered=${state.channelRegistered}`);
          try {
            await notifyChannel(channelEvent.content, channelEvent.meta);
          } catch (error) {
            logLine(`notify failed: ${(error as Error).message}`);
            state.broadcast("error", { request_id: ask.request_id, message: "channel notification failed" });
          }
          return sendJson(response, 202, { accepted: true });
        }

        const parsedFollowup = followupSchema.safeParse(body);
        if (!parsedFollowup.success) return sendJson(response, 400, { error: parsedFollowup.error.message });
        const followup = parsedFollowup.data;
        const trackedRequest = state.requests.get(followup.request_id);
        if (followup.kind === "cancel" && trackedRequest) trackedRequest.status = "cancelled";
        const channelEvent = buildFollowupChannelEvent(followup);
        logLine(`followup ${followup.kind} ${followup.request_id}`);
        try {
          await notifyChannel(channelEvent.content, channelEvent.meta);
        } catch (error) {
          logLine(`notify failed: ${(error as Error).message}`);
          state.broadcast("error", { request_id: followup.request_id, message: "channel notification failed" });
        }
        return sendJson(response, 202, { accepted: true });
      }

      return sendJson(response, 404, { error: "not found" });
    } catch (error) {
      logLine(`http error: ${(error as Error).stack ?? error}`);
      if (!response.headersSent) sendJson(response, 500, { error: "internal error" });
    }
  });
  return server;
}

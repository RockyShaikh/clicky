import { randomBytes } from "node:crypto";
import { appendFileSync, chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import type { ServerResponse } from "node:http";
import { homedir } from "node:os";
import { join } from "node:path";

export const BRIDGE_VERSION = "1.0";

/** Root of Clicky's runtime files. CLICKY_HOME exists so tests never touch the real ~/.clicky. */
export function clickyHomeDirectory(): string {
  return process.env.CLICKY_HOME ?? join(homedir(), ".clicky");
}

export function shotsDirectory(): string {
  return join(clickyHomeDirectory(), "shots");
}

export function logFilePath(): string {
  return join(clickyHomeDirectory(), "logs", "bridge.log");
}

/** Append one line to ~/.clicky/logs/bridge.log. stderr is swallowed by Claude Code, so a file is the only reliable log. */
export function logLine(message: string): void {
  try {
    mkdirSync(join(clickyHomeDirectory(), "logs"), { recursive: true });
    appendFileSync(logFilePath(), `${new Date().toISOString()} ${message}\n`);
  } catch {
    // Logging must never take the bridge down.
  }
}

/** Reads ~/.clicky/bridge-token, creating a 64-hex-char token with mode 0600 if missing. */
export function loadOrCreateBridgeToken(): string {
  const directory = clickyHomeDirectory();
  const tokenPath = join(directory, "bridge-token");
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  if (existsSync(tokenPath)) {
    const existingToken = readFileSync(tokenPath, "utf8").trim();
    if (/^[0-9a-f]{64}$/.test(existingToken)) {
      chmodSync(tokenPath, 0o600);
      return existingToken;
    }
  }
  const newToken = randomBytes(32).toString("hex");
  writeFileSync(tokenPath, newToken + "\n", { mode: 0o600 });
  chmodSync(tokenPath, 0o600);
  return newToken;
}

export function writeBridgeInfoFile(port: number): void {
  const info = {
    port,
    pid: process.pid,
    version: BRIDGE_VERSION,
    started_at: new Date().toISOString(),
  };
  writeFileSync(join(clickyHomeDirectory(), "bridge.json"), JSON.stringify(info) + "\n", { mode: 0o600 });
}

export interface ScreenInfo {
  screen_index: number;
  image_path: string;
  width_px: number;
  height_px: number;
  label: string;
  is_cursor_screen: boolean;
}

export type RequestStatus = "open" | "superseded" | "cancelled" | "answered";

export interface TrackedRequest {
  requestID: string;
  screens: ScreenInfo[];
  createdAtMilliseconds: number;
  status: RequestStatus;
  firstRespondLatencyLogged: boolean;
}

/** Shared mutable state: the request table, the SSE subscriber list, and the channel-registered flag. */
export class BridgeState {
  readonly requests = new Map<string, TrackedRequest>();
  private readonly serverSentEventClients = new Set<ServerResponse>();
  channelRegistered = false;

  /** Registers a new ask. Older open requests are marked superseded: newest ask wins. */
  registerAsk(requestID: string, screens: ScreenInfo[]): void {
    for (const trackedRequest of this.requests.values()) {
      if (trackedRequest.status === "open") trackedRequest.status = "superseded";
    }
    this.requests.set(requestID, {
      requestID,
      screens,
      createdAtMilliseconds: Date.now(),
      status: "open",
      firstRespondLatencyLogged: false,
    });
    // Keep the table bounded.
    while (this.requests.size > 200) {
      const oldestRequestID = this.requests.keys().next().value as string;
      this.requests.delete(oldestRequestID);
    }
  }

  addServerSentEventClient(response: ServerResponse): void {
    this.serverSentEventClients.add(response);
    response.on("close", () => this.serverSentEventClients.delete(response));
  }

  get serverSentEventClientCount(): number {
    return this.serverSentEventClients.size;
  }

  /** Sends one SSE message to every connected app. */
  broadcast(eventName: string, data: unknown): void {
    const message = `event: ${eventName}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const client of this.serverSentEventClients) {
      try {
        client.write(message);
      } catch {
        this.serverSentEventClients.delete(client);
      }
    }
  }

  closeAllServerSentEventClients(): void {
    for (const client of this.serverSentEventClients) client.end();
    this.serverSentEventClients.clear();
  }
}

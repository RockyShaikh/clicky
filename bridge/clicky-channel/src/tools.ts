import { readFileSync, realpathSync } from "node:fs";
import { resolve, sep } from "node:path";
import { z } from "zod";
import { BridgeState, logLine, shotsDirectory } from "./state.js";

// ---- Shapes (CONTRACTS §5) ----

const optionalShapeFields = {
  label: z.string().optional(),
  snap: z.boolean().optional(),
  emphasis: z.enum(["primary", "secondary"]).optional(),
};

export const shapeSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("circle"), x: z.number(), y: z.number(), r: z.number().positive(), ...optionalShapeFields }),
  z.object({ kind: z.literal("box"), x: z.number(), y: z.number(), x2: z.number(), y2: z.number(), ...optionalShapeFields }),
  z.object({
    kind: z.literal("arrow"),
    x: z.number(),
    y: z.number(),
    from_x: z.number(),
    from_y: z.number(),
    ...optionalShapeFields,
  }),
  z.object({ kind: z.literal("label"), x: z.number(), y: z.number(), text: z.string(), ...optionalShapeFields }),
  z.object({
    kind: z.literal("path"),
    points: z.array(z.tuple([z.number(), z.number()])).min(2).max(200),
    ...optionalShapeFields,
  }),
  z.object({ kind: z.literal("highlight"), x: z.number(), y: z.number(), x2: z.number(), y2: z.number(), ...optionalShapeFields }),
]);

const shapesArraySchema = z
  .array(shapeSchema)
  .max(6)
  .refine((shapes) => shapes.filter((shape) => shape.emphasis === "primary").length <= 1, {
    message: "at most one shape may have emphasis: primary",
  });

export const stepSchema = z.object({
  say: z.string(),
  shapes: shapesArraySchema,
  expect_click: z.boolean(),
});

export const lookInputShape = {
  request_id: z.string(),
  screen_index: z.number().int().positive().optional(),
};

export const respondInputShape = {
  request_id: z.string(),
  say: z.string().min(1),
  screen_index: z.number().int().positive().optional(),
  shapes: shapesArraySchema,
  steps: z.array(stepSchema).max(20).optional(),
  expect_click: z.boolean().optional(),
  final: z.boolean().optional(),
};

export const statusInputShape = { request_id: z.string(), text: z.string().min(1).max(200) };
export const confirmInputShape = { request_id: z.string(), question: z.string().min(1).max(400) };

// ---- Tool results ----

export type ToolContent =
  | { type: "text"; text: string }
  | { type: "image"; data: string; mimeType: string };

export interface ToolResult {
  [key: string]: unknown;
  content: ToolContent[];
  isError?: boolean;
}

function textResult(text: string, isError = false): ToolResult {
  return { content: [{ type: "text", text }], ...(isError ? { isError: true } : {}) };
}

/** True when `candidatePath` resolves (symlinks included) to a file inside ~/.clicky/shots/. */
export function isInsideShotsDirectory(candidatePath: string): boolean {
  try {
    const shotsRoot = realpathSync(shotsDirectory());
    const resolvedCandidate = realpathSync(resolve(candidatePath));
    return resolvedCandidate.startsWith(shotsRoot + sep);
  } catch {
    return false;
  }
}

function mimeTypeForImagePath(imagePath: string): string {
  return /\.png$/i.test(imagePath) ? "image/png" : "image/jpeg";
}

export function handleLook(state: BridgeState, input: { request_id: string; screen_index?: number }): ToolResult {
  const trackedRequest = state.requests.get(input.request_id);
  if (!trackedRequest) return textResult(`unknown request_id ${input.request_id}`, true);
  const wantedScreenIndex = input.screen_index ?? trackedRequest.screens.find((screen) => screen.is_cursor_screen)?.screen_index ?? 1;
  const screen = trackedRequest.screens.find((candidate) => candidate.screen_index === wantedScreenIndex);
  if (!screen) {
    return textResult(`no screen ${wantedScreenIndex} in this request (screens: ${trackedRequest.screens.map((s) => s.screen_index).join(", ")})`, true);
  }
  if (!isInsideShotsDirectory(screen.image_path)) {
    logLine(`look refused path outside shots dir: ${screen.image_path}`);
    return textResult("refused: image is not inside ~/.clicky/shots/", true);
  }
  let imageBytes: Buffer;
  try {
    imageBytes = readFileSync(screen.image_path);
  } catch (error) {
    return textResult(`could not read screenshot: ${(error as Error).message}`, true);
  }
  const description =
    `screen ${screen.screen_index} of ${trackedRequest.screens.length}, ${screen.width_px}x${screen.height_px} px, ` +
    `origin top-left, ${screen.is_cursor_screen ? "cursor screen" : screen.label}`;
  return {
    content: [
      { type: "image", data: imageBytes.toString("base64"), mimeType: mimeTypeForImagePath(screen.image_path) },
      { type: "text", text: description },
    ],
  };
}

/** Returns a rejection message when this request should no longer produce output, else null. */
function rejectionForInactiveRequest(state: BridgeState, requestID: string): string | null {
  const trackedRequest = state.requests.get(requestID);
  if (!trackedRequest) return `unknown request_id ${requestID}`;
  if (trackedRequest.status === "superseded") return "this request was superseded by a newer ask; say nothing about it";
  if (trackedRequest.status === "cancelled") return "this request was cancelled; stop and say nothing";
  return null;
}

export function handleRespond(state: BridgeState, input: z.infer<z.ZodObject<typeof respondInputShape>>): ToolResult {
  const rejection = rejectionForInactiveRequest(state, input.request_id);
  if (rejection) return textResult(rejection, true);
  const trackedRequest = state.requests.get(input.request_id)!;
  if (!trackedRequest.firstRespondLatencyLogged) {
    trackedRequest.firstRespondLatencyLogged = true;
    logLine(`first respond for ${input.request_id} after ${Date.now() - trackedRequest.createdAtMilliseconds} ms`);
  }
  const screenIndex = input.screen_index ?? trackedRequest.screens.find((screen) => screen.is_cursor_screen)?.screen_index ?? 1;
  const isFinal = input.final ?? true;
  if (isFinal) trackedRequest.status = "answered";
  state.broadcast("respond", {
    request_id: input.request_id,
    say: input.say,
    screen_index: screenIndex,
    shapes: input.shapes,
    ...(input.steps ? { steps: input.steps } : {}),
    expect_click: input.expect_click ?? false,
    final: isFinal,
  });
  return textResult("shown");
}

export function handleStatus(state: BridgeState, input: { request_id: string; text: string }): ToolResult {
  const rejection = rejectionForInactiveRequest(state, input.request_id);
  if (rejection) return textResult(rejection, true);
  state.broadcast("status", { request_id: input.request_id, text: input.text });
  return textResult("ok");
}

export function handleConfirm(state: BridgeState, input: { request_id: string; question: string }): ToolResult {
  const rejection = rejectionForInactiveRequest(state, input.request_id);
  if (rejection) return textResult(rejection, true);
  state.broadcast("confirm", { request_id: input.request_id, question: input.question });
  return textResult("asked — end your turn and wait for a kind=confirmation event");
}

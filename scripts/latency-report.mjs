#!/usr/bin/env node
// Parses latency log lines and prints per-stage p50/p90 vs the ARCHITECTURE.md budget.
// Line format (see docs/fork/TESTING.md "Latency logging spec"):
//   <ISO8601 with ms> latency request_id=<id> event=<name> [key=value ...]
// Usage: node scripts/latency-report.mjs [--dir ~/.clicky/logs] [file ...]
import { readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// stage name, from event, to event, budget in ms (p50 target)
const STAGES = [
  ["wake -> dim shown", "wake", "dim_shown", 300],
  ["wake -> capture done", "wake", "capture_done", 150],
  ["speech end -> submit", "speech_end", "submit", 1200],
  ["submit -> first event", "submit", "first_event", null],
  ["submit -> respond", "submit", "respond", 5000],
  ["respond -> tts start", "respond", "tts_start", 400],
  ["wake -> tts start (total)", "wake", "tts_start", null],
];

function percentile(sortedValues, fraction) {
  if (sortedValues.length === 0) return null;
  return sortedValues[Math.max(0, Math.min(sortedValues.length - 1, Math.ceil(fraction * sortedValues.length) - 1))];
}

const args = process.argv.slice(2);
let directory = join(homedir(), ".clicky", "logs");
const explicitFiles = [];
for (let index = 0; index < args.length; index++) {
  if (args[index] === "--dir") directory = args[++index];
  else explicitFiles.push(args[index]);
}
const files = explicitFiles.length ? explicitFiles
  : (() => { try { return readdirSync(directory).filter((name) => name.endsWith(".log")).map((name) => join(directory, name)); } catch { return []; } })();
if (files.length === 0) { console.error(`No log files found (${directory}).`); process.exit(1); }

const eventTimesByRequest = new Map(); // request_id -> Map(event -> first timestamp ms)
for (const file of files) {
  for (const line of readFileSync(file, "utf8").split("\n")) {
    const match = line.match(/^(\S+)\s+latency\s+request_id=(\S+)\s+event=(\S+)/);
    if (!match) continue;
    const timestampMs = Date.parse(match[1]);
    if (Number.isNaN(timestampMs)) continue;
    const events = eventTimesByRequest.get(match[2]) ?? new Map();
    if (!events.has(match[3])) events.set(match[3], timestampMs);
    eventTimesByRequest.set(match[2], events);
  }
}

console.log(`${eventTimesByRequest.size} requests from ${files.length} file(s)\n`);
console.log("stage".padEnd(30) + "n".padStart(4) + "p50".padStart(8) + "p90".padStart(8) + "  budget  status");
for (const [stageName, fromEvent, toEvent, budgetMs] of STAGES) {
  const durations = [];
  for (const events of eventTimesByRequest.values()) {
    if (events.has(fromEvent) && events.has(toEvent)) durations.push(events.get(toEvent) - events.get(fromEvent));
  }
  durations.sort((a, b) => a - b);
  const p50 = percentile(durations, 0.5); const p90 = percentile(durations, 0.9);
  const status = budgetMs === null || p50 === null ? "-" : p50 <= budgetMs ? "ok" : "OVER";
  console.log(stageName.padEnd(30) + String(durations.length).padStart(4) + String(p50 ?? "-").padStart(8) +
    String(p90 ?? "-").padStart(8) + String(budgetMs ?? "-").padStart(9) + "  " + status);
}

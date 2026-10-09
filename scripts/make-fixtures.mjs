#!/usr/bin/env node
// Generates SYNTHETIC mock app screenshots (1280x800 PNG) plus targets.json.
// No real screen content is involved, so the output is safe to commit.
// Usage: node scripts/make-fixtures.mjs
import { deflateSync } from "node:zlib";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const rootDirectory = join(dirname(fileURLToPath(import.meta.url)), "..");
const outputDirectory = join(rootDirectory, "test-fixtures", "screens");
mkdirSync(outputDirectory, { recursive: true });

const WIDTH = 1280;
const HEIGHT = 800;

// 5x7 bitmap font (uppercase, digits, a little punctuation). Lowercase is drawn as uppercase.
const GLYPHS = {
  A: "01110 10001 10001 11111 10001 10001 10001", B: "11110 10001 10001 11110 10001 10001 11110",
  C: "01110 10001 10000 10000 10000 10001 01110", D: "11110 10001 10001 10001 10001 10001 11110",
  E: "11111 10000 10000 11110 10000 10000 11111", F: "11111 10000 10000 11110 10000 10000 10000",
  G: "01110 10001 10000 10111 10001 10001 01111", H: "10001 10001 10001 11111 10001 10001 10001",
  I: "01110 00100 00100 00100 00100 00100 01110", J: "00111 00010 00010 00010 00010 10010 01100",
  K: "10001 10010 10100 11000 10100 10010 10001", L: "10000 10000 10000 10000 10000 10000 11111",
  M: "10001 11011 10101 10101 10001 10001 10001", N: "10001 11001 10101 10011 10001 10001 10001",
  O: "01110 10001 10001 10001 10001 10001 01110", P: "11110 10001 10001 11110 10000 10000 10000",
  Q: "01110 10001 10001 10001 10101 10010 01101", R: "11110 10001 10001 11110 10100 10010 10001",
  S: "01111 10000 10000 01110 00001 00001 11110", T: "11111 00100 00100 00100 00100 00100 00100",
  U: "10001 10001 10001 10001 10001 10001 01110", V: "10001 10001 10001 10001 10001 01010 00100",
  W: "10001 10001 10001 10101 10101 11011 10001", X: "10001 10001 01010 00100 01010 10001 10001",
  Y: "10001 10001 01010 00100 00100 00100 00100", Z: "11111 00001 00010 00100 01000 10000 11111",
  0: "01110 10001 10011 10101 11001 10001 01110", 1: "00100 01100 00100 00100 00100 00100 01110",
  2: "01110 10001 00001 00010 00100 01000 11111", 3: "11110 00001 00001 01110 00001 00001 11110",
  4: "00010 00110 01010 10010 11111 00010 00010", 5: "11111 10000 11110 00001 00001 10001 01110",
  6: "00110 01000 10000 11110 10001 10001 01110", 7: "11111 00001 00010 00100 01000 01000 01000",
  8: "01110 10001 10001 01110 10001 10001 01110", 9: "01110 10001 10001 01111 00001 00010 01100",
  ".": "00000 00000 00000 00000 00000 01100 01100", "-": "00000 00000 00000 11111 00000 00000 00000",
  "+": "00000 00100 00100 11111 00100 00100 00000", "/": "00001 00010 00010 00100 01000 01000 10000",
  ":": "00000 01100 01100 00000 01100 01100 00000", "&": "01100 10010 10100 01000 10101 10010 01101",
  "?": "01110 10001 00001 00110 00100 00000 00100", " ": "00000 00000 00000 00000 00000 00000 00000",
};

const pixels = new Uint8Array(WIDTH * HEIGHT * 3);

function hexToRGB(hex) {
  const value = parseInt(hex.slice(1), 16);
  return [(value >> 16) & 255, (value >> 8) & 255, value & 255];
}

function fillRect(x1, y1, x2, y2, color) {
  const [red, green, blue] = hexToRGB(color);
  for (let y = Math.max(0, y1); y < Math.min(HEIGHT, y2); y++) {
    for (let x = Math.max(0, x1); x < Math.min(WIDTH, x2); x++) {
      const offset = (y * WIDTH + x) * 3;
      pixels[offset] = red; pixels[offset + 1] = green; pixels[offset + 2] = blue;
    }
  }
}

function strokeRect(x1, y1, x2, y2, color) {
  fillRect(x1, y1, x2, y1 + 1, color); fillRect(x1, y2 - 1, x2, y2, color);
  fillRect(x1, y1, x1 + 1, y2, color); fillRect(x2 - 1, y1, x2, y2, color);
}

function textWidth(text, scale) { return text.length * 6 * scale - scale; }

function drawText(text, x, y, color, scale = 2) {
  let cursorX = x;
  for (const character of text.toUpperCase()) {
    const rows = (GLYPHS[character] ?? GLYPHS["?"]).split(" ");
    rows.forEach((row, rowIndex) => {
      [...row].forEach((bit, columnIndex) => {
        if (bit === "1") {
          fillRect(cursorX + columnIndex * scale, y + rowIndex * scale,
                   cursorX + (columnIndex + 1) * scale, y + (rowIndex + 1) * scale, color);
        }
      });
    });
    cursorX += 6 * scale;
  }
}

const crcTable = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function crc32(buffer) {
  let c = 0xffffffff;
  for (const b of buffer) c = crcTable[(c ^ b) & 255] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function pngChunk(type, data) {
  const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

function writePNG(filePath) {
  const rowStride = WIDTH * 3 + 1;
  const raw = Buffer.alloc(rowStride * HEIGHT);
  for (let y = 0; y < HEIGHT; y++) {
    raw[y * rowStride] = 0;
    Buffer.from(pixels.buffer, y * WIDTH * 3, WIDTH * 3).copy(raw, y * rowStride + 1);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(WIDTH, 0); header.writeUInt32BE(HEIGHT, 4); header[8] = 8; header[9] = 2;
  writeFileSync(filePath, Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk("IHDR", header), pngChunk("IDAT", deflateSync(raw)), pngChunk("IEND", Buffer.alloc(0)),
  ]));
}

const THEMES = {
  light: { window: "#f5f5f7", sidebar: "#e4e4ea", toolbar: "#ececf0", control: "#ffffff", border: "#b8b8c0", text: "#222226", accent: "#2f6fed", menubar: "#d8d8de" },
  dark: { window: "#1f1f23", sidebar: "#2a2a30", toolbar: "#33333a", control: "#3d3d46", border: "#55555f", text: "#e8e8ec", accent: "#4f8cff", menubar: "#141417" },
};

// Each fixture is a mock app window. The target is one named control; its box is recorded exactly.
// target.region: "toolbar" | "sidebar" | "rows". Rows are "Label:kind" (kind: toggle|button|field).
const FIXTURES = [
  { id: "finder-sidebar-downloads", app: "Finder", bundle: "com.apple.finder", title: "Documents", theme: "light", sidebar: ["Recents", "Applications", "Desktop", "Documents", "Downloads"], toolbar: ["Back", "View", "Group", "Share", "Tags"], rows: ["Report.pdf", "Photos", "Budget.xlsx", "Notes.txt"], target: { region: "sidebar", label: "Downloads" }, question: "Where do I find my downloads folder?" },
  { id: "finder-share-button", app: "Finder", bundle: "com.apple.finder", title: "Projects", theme: "dark", sidebar: ["Recents", "Applications", "Desktop", "Documents", "Downloads"], toolbar: ["Back", "View", "Group", "Share", "Tags"], rows: ["Alpha", "Beta", "Gamma"], target: { region: "toolbar", label: "Share" }, question: "How do I share this folder?" },
  { id: "finder-tags", app: "Finder", bundle: "com.apple.finder", title: "Desktop", theme: "light", sidebar: ["Recents", "Applications", "Desktop"], toolbar: ["Back", "View", "Group", "Share", "Tags"], rows: ["Screenshot", "Draft"], target: { region: "toolbar", label: "Tags" }, question: "How do I tag this file?" },
  { id: "notes-font-size", app: "Notes", bundle: "com.apple.Notes", title: "Groceries", theme: "light", sidebar: ["All iCloud", "Notes", "Shared", "Recently Deleted"], toolbar: ["New", "Delete", "Format", "Checklist", "Table", "Share"], rows: ["Milk", "Eggs", "Bread", "Coffee"], target: { region: "toolbar", label: "Format" }, question: "Where do I change the font size?" },
  { id: "notes-checklist", app: "Notes", bundle: "com.apple.Notes", title: "Todo", theme: "dark", sidebar: ["All iCloud", "Notes", "Shared"], toolbar: ["New", "Delete", "Format", "Checklist", "Table", "Share"], rows: ["Call dentist", "Pay rent"], target: { region: "toolbar", label: "Checklist" }, question: "How do I turn this into a checklist?" },
  { id: "notes-new-note", app: "Notes", bundle: "com.apple.Notes", title: "Ideas", theme: "light", sidebar: ["All iCloud", "Notes", "Shared"], toolbar: ["New", "Delete", "Format", "Checklist"], rows: ["Trip", "Gift list"], target: { region: "toolbar", label: "New" }, question: "How do I start a new note?" },
  { id: "safari-privacy", app: "Safari", bundle: "com.apple.Safari", title: "Settings", theme: "light", sidebar: ["General", "Tabs", "AutoFill", "Search", "Privacy", "Extensions"], toolbar: ["Back", "Forward"], rows: ["Prevent tracking:toggle", "Hide IP address:toggle", "Manage website data:button"], target: { region: "sidebar", label: "Privacy" }, question: "Where are the privacy settings?" },
  { id: "safari-clear-data", app: "Safari", bundle: "com.apple.Safari", title: "Privacy", theme: "dark", sidebar: ["General", "Tabs", "AutoFill", "Search", "Privacy", "Extensions"], toolbar: ["Back", "Forward"], rows: ["Prevent tracking:toggle", "Hide IP address:toggle", "Manage website data:button"], target: { region: "rows", label: "Manage website data" }, question: "How do I clear my cookies?" },
  { id: "chrome-extensions", app: "Chrome", bundle: "com.google.Chrome", title: "Settings", theme: "light", sidebar: ["You and Google", "Autofill", "Privacy and security", "Performance", "Appearance", "Extensions"], toolbar: ["Back", "Reload"], rows: ["Default browser:button", "On startup:button", "Languages:button"], target: { region: "sidebar", label: "Extensions" }, question: "Where do I manage my extensions?" },
  { id: "chrome-default-browser", app: "Chrome", bundle: "com.google.Chrome", title: "Settings", theme: "dark", sidebar: ["You and Google", "Autofill", "Privacy and security", "Appearance"], toolbar: ["Back", "Reload"], rows: ["Default browser:button", "On startup:button", "Languages:button"], target: { region: "rows", label: "Default browser" }, question: "How do I make Chrome my default browser?" },
  { id: "chrome-signup-form", app: "Chrome", bundle: "com.google.Chrome", title: "Create account", theme: "light", sidebar: [], toolbar: ["Back", "Reload"], rows: ["Full name:field", "Email:field", "Password:field", "Create account:button"], target: { region: "rows", label: "Create account" }, question: "Where do I submit this form?" },
  { id: "sysset-wifi", app: "System Settings", bundle: "com.apple.systempreferences", title: "Wi-Fi", theme: "light", sidebar: ["Wi-Fi", "Bluetooth", "Network", "Notifications", "Sound", "Focus", "Displays"], toolbar: [], rows: ["Wi-Fi:toggle", "Ask to join networks:toggle", "Advanced:button"], target: { region: "rows", label: "Wi-Fi" }, question: "How do I turn Wi-Fi off?" },
  { id: "sysset-displays", app: "System Settings", bundle: "com.apple.systempreferences", title: "General", theme: "dark", sidebar: ["Wi-Fi", "Bluetooth", "Network", "Notifications", "Sound", "Focus", "Displays"], toolbar: [], rows: ["Resolution:button", "Night Shift:button"], target: { region: "sidebar", label: "Displays" }, question: "Where can I change my screen resolution?" },
  { id: "sysset-sound", app: "System Settings", bundle: "com.apple.systempreferences", title: "Sound", theme: "light", sidebar: ["Wi-Fi", "Bluetooth", "Network", "Notifications", "Sound", "Focus"], toolbar: [], rows: ["Alert volume:field", "Output volume:field", "Mute:toggle"], target: { region: "rows", label: "Output volume" }, question: "How do I make my speakers quieter?" },
  { id: "xcode-run", app: "Xcode", bundle: "com.apple.dt.Xcode", title: "Clicky", theme: "dark", sidebar: ["Project", "Source Control", "Find", "Issues", "Tests"], toolbar: ["Run", "Stop", "Scheme", "Library", "Inspector"], rows: ["AppDelegate.swift", "Info.plist"], target: { region: "toolbar", label: "Run" }, question: "How do I build and run this?" },
  { id: "xcode-issues", app: "Xcode", bundle: "com.apple.dt.Xcode", title: "Clicky", theme: "light", sidebar: ["Project", "Source Control", "Find", "Issues", "Tests"], toolbar: ["Run", "Stop", "Scheme", "Library", "Inspector"], rows: ["AppDelegate.swift", "Info.plist"], target: { region: "sidebar", label: "Issues" }, question: "Where do I see the build errors?" },
  { id: "xcode-inspector", app: "Xcode", bundle: "com.apple.dt.Xcode", title: "Clicky", theme: "dark", sidebar: ["Project", "Find", "Issues"], toolbar: ["Run", "Stop", "Scheme", "Library", "Inspector"], rows: ["View.swift"], target: { region: "toolbar", label: "Inspector" }, question: "How do I open the right-hand inspector panel?" },
  { id: "vscode-extensions", app: "VS Code", bundle: "com.microsoft.VSCode", title: "main.ts", theme: "dark", sidebar: ["Explorer", "Search", "Source Control", "Run and Debug", "Extensions"], toolbar: [], rows: ["main.ts", "util.ts", "README.md"], target: { region: "sidebar", label: "Extensions" }, question: "Where do I install a plugin?" },
  { id: "vscode-source-control", app: "VS Code", bundle: "com.microsoft.VSCode", title: "app.py", theme: "light", sidebar: ["Explorer", "Search", "Source Control", "Run and Debug", "Extensions"], toolbar: [], rows: ["app.py", "test.py"], target: { region: "sidebar", label: "Source Control" }, question: "How do I commit my changes?" },
  { id: "vscode-search", app: "VS Code", bundle: "com.microsoft.VSCode", title: "app.py", theme: "dark", sidebar: ["Explorer", "Search", "Source Control", "Run and Debug"], toolbar: [], rows: ["app.py"], target: { region: "sidebar", label: "Search" }, question: "How do I search across all files?" },
  { id: "figma-share", app: "Figma", bundle: "com.google.Chrome", title: "Landing page", theme: "light", sidebar: ["Layers", "Assets", "Pages"], toolbar: ["Move", "Frame", "Shape", "Pen", "Text", "Comment", "Share"], rows: ["Hero", "Pricing"], target: { region: "toolbar", label: "Share" }, question: "How do I share this design?" },
  { id: "figma-text-tool", app: "Figma", bundle: "com.google.Chrome", title: "Landing page", theme: "dark", sidebar: ["Layers", "Assets", "Pages"], toolbar: ["Move", "Frame", "Shape", "Pen", "Text", "Comment", "Share"], rows: ["Hero", "Pricing"], target: { region: "toolbar", label: "Text" }, question: "Which tool do I use to add text?" },
  { id: "gdocs-share", app: "Google Docs", bundle: "com.google.Chrome", title: "Essay draft", theme: "light", sidebar: ["Outline"], toolbar: ["File", "Edit", "View", "Insert", "Format", "Tools", "Share"], rows: ["Introduction", "Body", "Conclusion"], target: { region: "toolbar", label: "Share" }, question: "How do I give my friend access to this doc?" },
  { id: "gdocs-insert", app: "Google Docs", bundle: "com.google.Chrome", title: "Essay draft", theme: "dark", sidebar: ["Outline"], toolbar: ["File", "Edit", "View", "Insert", "Format", "Tools", "Share"], rows: ["Introduction", "Body"], target: { region: "toolbar", label: "Insert" }, question: "Where do I add an image?" },
  { id: "gdocs-format", app: "Google Docs", bundle: "com.google.Chrome", title: "Essay draft", theme: "light", sidebar: ["Outline"], toolbar: ["File", "Edit", "View", "Insert", "Format", "Tools", "Share"], rows: ["Introduction"], target: { region: "toolbar", label: "Format" }, question: "How do I change the line spacing?" },
];

function renderFixture(fixture) {
  const theme = THEMES[fixture.theme];
  fillRect(0, 0, WIDTH, HEIGHT, theme.window);
  // Menu bar and title bar
  fillRect(0, 0, WIDTH, 28, theme.menubar);
  drawText(fixture.app, 24, 8, theme.text, 2);
  fillRect(0, 28, WIDTH, 60, theme.toolbar);
  [["#ff5f57", 20], ["#febc2e", 44], ["#28c840", 68]].forEach(([color, x]) => fillRect(x, 38, x + 12, 50, color));
  drawText(fixture.title, Math.round(WIDTH / 2 - textWidth(fixture.title, 2) / 2), 38, theme.text, 2);
  // Toolbar buttons
  const boxes = {};
  let toolbarX = 120;
  fillRect(0, 60, WIDTH, 100, theme.toolbar);
  for (const label of fixture.toolbar) {
    const width = textWidth(label, 2) + 28;
    fillRect(toolbarX, 66, toolbarX + width, 94, theme.control);
    strokeRect(toolbarX, 66, toolbarX + width, 94, theme.border);
    drawText(label, toolbarX + 14, 73, theme.text, 2);
    boxes[`toolbar:${label}`] = [toolbarX, 66, toolbarX + width, 94];
    toolbarX += width + 14;
  }
  // Sidebar
  const sidebarWidth = fixture.sidebar.length > 0 ? 240 : 0;
  if (sidebarWidth) fillRect(0, 100, sidebarWidth, HEIGHT, theme.sidebar);
  fixture.sidebar.forEach((label, index) => {
    const top = 118 + index * 44;
    if (index === 0) fillRect(10, top, sidebarWidth - 10, top + 34, theme.accent);
    drawText(label, 28, top + 10, index === 0 ? "#ffffff" : theme.text, 2);
    boxes[`sidebar:${label}`] = [10, top, sidebarWidth - 10, top + 34];
  });
  // Content rows
  fixture.rows.forEach((rowSpec, index) => {
    const [label, kind = "plain"] = rowSpec.split(":");
    const top = 130 + index * 90;
    const rowLeft = sidebarWidth + 40;
    fillRect(rowLeft, top, WIDTH - 40, top + 70, theme.control);
    strokeRect(rowLeft, top, WIDTH - 40, top + 70, theme.border);
    drawText(label, rowLeft + 24, top + 28, theme.text, 2);
    let controlBox = [rowLeft, top, WIDTH - 40, top + 70];
    if (kind === "toggle") {
      controlBox = [WIDTH - 140, top + 20, WIDTH - 70, top + 50];
      fillRect(...controlBox, theme.accent);
      fillRect(WIDTH - 100, top + 23, WIDTH - 73, top + 47, "#ffffff");
    } else if (kind === "button") {
      controlBox = [WIDTH - 260, top + 18, WIDTH - 64, top + 52];
      fillRect(...controlBox, theme.accent);
      drawText(label.length > 14 ? "OPEN" : label, WIDTH - 244, top + 28, "#ffffff", 2);
    } else if (kind === "field") {
      controlBox = [WIDTH - 480, top + 16, WIDTH - 64, top + 54];
      fillRect(...controlBox, theme.window);
      strokeRect(...controlBox, theme.border);
    }
    boxes[`rows:${label}`] = controlBox;
  });
  const key = `${fixture.target.region}:${fixture.target.label}`;
  if (!boxes[key]) throw new Error(`Target ${key} not found in ${fixture.id}`);
  return boxes[key];
}

const targets = [];
for (const fixture of FIXTURES) {
  const targetBox = renderFixture(fixture);
  const file = `${fixture.id}.png`;
  writePNG(join(outputDirectory, file));
  targets.push({
    file, question: fixture.question, target_box_px: targetBox, app_bundle_id: fixture.bundle,
    app_name: fixture.app, window_title: fixture.title, width_px: WIDTH, height_px: HEIGHT,
    synthetic: true,
  });
}
writeFileSync(join(outputDirectory, "targets.json"), JSON.stringify(targets, null, 2) + "\n");
console.log(`Wrote ${targets.length} synthetic fixtures to ${outputDirectory}`);

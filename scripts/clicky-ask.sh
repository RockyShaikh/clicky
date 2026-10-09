#!/usr/bin/env bash
# Ask Clicky a question from the terminal, through the running bridge (docs/fork/CONTRACTS.md section 2).
#
# Usage: clicky-ask.sh "question" [--no-screenshot] [--all-screens] [--mode auto|point|do] [--timeout SECONDS]
#
#   - Captures the main display with `screencapture -x` into ~/.clicky/shots/ (files are mode 0600),
#     downscaled to a 1280 px long edge like the app does. --all-screens captures every display.
#     --no-screenshot sends a 1x1 placeholder (the bridge requires one screen entry) and a text-only label.
#   - Reads ~/.clicky/bridge.json (port) and ~/.clicky/bridge-token. The token is never printed.
#   - Opens /v1/events first, POSTs /v1/ask, then prints status lines, the spoken text and any shapes
#     for THIS request id, and exits on the `respond` event (0), on `error` (1) or on timeout (2).
#
# Terminal only: the Clicky app is also subscribed to /v1/events, but it ignores respond/confirm
# events whose request id is not its own current request, so nothing is drawn or spoken on screen.
# If the brain asks for confirmation (do mode) the CLI answers "no" and says so; it never confirms actions.
#
# Never launches `claude`. Requires python3 (ships with the Xcode command line tools) and `sips`.
set -euo pipefail

question=""
take_screenshot=1
all_screens=0
mode="auto"
timeout_seconds=120

while [ $# -gt 0 ]; do
  case "$1" in
    --no-screenshot) take_screenshot=0 ;;
    --all-screens) all_screens=1 ;;
    --mode) mode="${2:?--mode needs a value}"; shift ;;
    --timeout) timeout_seconds="${2:?--timeout needs a value}"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    --*) echo "unknown option: $1" >&2; exit 64 ;;
    *) if [ -z "$question" ]; then question="$1"; else question="$question $1"; fi ;;
  esac
  shift
done

if [ -z "$question" ]; then
  echo 'usage: clicky-ask.sh "question" [--no-screenshot] [--all-screens]' >&2
  exit 64
fi
case "$mode" in auto|point|do) ;; *) echo "--mode must be auto, point or do" >&2; exit 64 ;; esac

clicky_home="${CLICKY_HOME:-$HOME/.clicky}"
if [ ! -f "$clicky_home/bridge.json" ] || [ ! -f "$clicky_home/bridge-token" ]; then
  echo "No bridge found in $clicky_home. Start it with scripts/clicky-session.sh start." >&2
  exit 69
fi

shots_directory="$clicky_home/shots"
mkdir -p "$shots_directory"
chmod 700 "$shots_directory" 2>/dev/null || true
umask 077

# Request ids must match r_[a-z2-7]{10}.
request_id="r_$(python3 -c 'import secrets; print("".join(secrets.choice("abcdefghijklmnopqrstuvwxyz234567") for _ in range(10)))')"

screen_image_paths=()
if [ "$take_screenshot" -eq 1 ]; then
  if [ "$all_screens" -eq 1 ]; then
    display_count="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c 'Resolution:' || true)"
    [ "${display_count:-0}" -ge 1 ] || display_count=1
  else
    display_count=1
  fi
  capture_targets=()
  for ((screen_number = 1; screen_number <= display_count; screen_number++)); do
    capture_targets+=("$shots_directory/$request_id-s$screen_number.png")
  done
  screencapture -x "${capture_targets[@]}"
  for capture_target in "${capture_targets[@]}"; do
    [ -f "$capture_target" ] || continue
    jpeg_path="${capture_target%.png}.jpg"
    sips -s format jpeg -s formatOptions 70 --resampleHeightWidthMax 1280 "$capture_target" --out "$jpeg_path" >/dev/null
    rm -f "$capture_target"
    chmod 600 "$jpeg_path"
    screen_image_paths+=("$jpeg_path")
  done
  if [ "${#screen_image_paths[@]}" -eq 0 ]; then
    echo "screencapture produced no image (Screen Recording permission for your terminal?). Use --no-screenshot to skip." >&2
    exit 70
  fi
fi

CLICKY_HOME_DIR="$clicky_home" \
REQUEST_ID="$request_id" QUESTION="$question" MODE="$mode" TIMEOUT_SECONDS="$timeout_seconds" \
python3 - "${screen_image_paths[@]+"${screen_image_paths[@]}"}" <<'PYTHON'
import base64, json, os, struct, subprocess, sys, threading, time, urllib.request, zlib
from datetime import datetime, timezone

clicky_home = os.environ["CLICKY_HOME_DIR"]
request_id = os.environ["REQUEST_ID"]
question = os.environ["QUESTION"]
mode = os.environ["MODE"]
timeout_seconds = float(os.environ["TIMEOUT_SECONDS"])
image_paths = sys.argv[1:]

port = json.load(open(os.path.join(clicky_home, "bridge.json")))["port"]
token = open(os.path.join(clicky_home, "bridge-token")).read().strip()
base_url = f"http://127.0.0.1:{port}"
auth_headers = {"Authorization": f"Bearer {token}"}


def jpeg_size(path):
    output = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path], capture_output=True, text=True).stdout
    values = {line.split(":")[0].strip(): int(line.split(":")[1]) for line in output.splitlines() if ":" in line and line.split(":")[1].strip().isdigit()}
    return values["pixelWidth"], values["pixelHeight"]


def write_placeholder_png(path):
    # 1x1 white PNG: the bridge requires at least one screen entry even for text-only questions.
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    raw = b"\x00\xff\xff\xff"
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(png)


screens = []
if image_paths:
    for index, path in enumerate(image_paths, start=1):
        width, height = jpeg_size(path)
        screens.append({"screen_index": index, "image_path": path, "width_px": width, "height_px": height,
                        "label": "cursor screen (primary focus)" if index == 1 else f"screen {index}",
                        "is_cursor_screen": index == 1})
else:
    placeholder_path = os.path.join(clicky_home, "shots", f"{request_id}-s1.png")
    write_placeholder_png(placeholder_path)
    screens.append({"screen_index": 1, "image_path": placeholder_path, "width_px": 1, "height_px": 1,
                    "label": "no screenshot: text-only question, ignore this placeholder image", "is_cursor_screen": True})

ask_body = {
    "request_id": request_id, "mode": mode, "utterance": question, "screens": screens,
    "sent_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
}

exit_code = {"value": 2}
finished = threading.Event()


def describe_shape(shape):
    kind = shape.get("kind", "?")
    label = f' "{shape["text"]}"' if shape.get("text") else ""
    if "points" in shape:
        position = f'{len(shape["points"])} points'
    elif "x2" in shape:
        position = f'({shape.get("x")},{shape.get("y")})-({shape.get("x2")},{shape.get("y2")})'
    else:
        position = f'({shape.get("x")},{shape.get("y")})'
    return f"{kind} {position}{label}"


def post_json(path, body):
    request = urllib.request.Request(base_url + path, data=json.dumps(body).encode(), method="POST",
                                     headers={**auth_headers, "Content-Type": "application/json"})
    return urllib.request.urlopen(request, timeout=15)


def handle_event(event_type, data):
    if data.get("request_id") != request_id:
        return
    if event_type == "status":
        print(f"[status] {data.get('text', '')}", flush=True)
    elif event_type == "respond":
        print(f"say: {data.get('say', '')}", flush=True)
        shapes = data.get("shapes") or []
        for step in data.get("steps") or []:
            shapes = shapes + (step.get("shapes") or [])
        for shape in shapes:
            print(f"shape: {describe_shape(shape)}", flush=True)
        if data.get("expect_click"):
            print("(Clicky expects a click on the primary shape; the terminal cannot report it.)", flush=True)
        exit_code["value"] = 0
        finished.set()
    elif event_type == "confirm":
        print(f"[confirm requested] {data.get('question', '')}", flush=True)
        print("The CLI never confirms actions: answering no.", flush=True)
        try:
            post_json("/v1/followup", {"request_id": request_id, "kind": "confirmation", "answer": "no", "utterance": ""})
        except Exception as error:
            print(f"followup failed: {error}", file=sys.stderr)
    elif event_type == "error":
        print(f"error: {data.get('message', '')}", file=sys.stderr, flush=True)
        exit_code["value"] = 1
        finished.set()


def read_events(connected):
    request = urllib.request.Request(base_url + "/v1/events", headers=auth_headers)
    try:
        response = urllib.request.urlopen(request, timeout=timeout_seconds + 30)
    except Exception as error:
        print(f"could not open /v1/events: {error}", file=sys.stderr)
        exit_code["value"] = 1
        connected.set()
        finished.set()
        return
    connected.set()
    event_type, data_lines = "message", []
    for raw_line in response:
        line = raw_line.decode("utf-8", "replace").rstrip("\r\n")
        if line == "":
            if data_lines:
                try:
                    handle_event(event_type, json.loads("\n".join(data_lines)))
                except json.JSONDecodeError:
                    pass
            event_type, data_lines = "message", []
        elif line.startswith("event:"):
            event_type = line[6:].strip()
        elif line.startswith("data:"):
            data_lines.append(line[5:].strip())


connected = threading.Event()
threading.Thread(target=read_events, args=(connected,), daemon=True).start()
connected.wait(10)
if finished.is_set():
    sys.exit(exit_code["value"])

try:
    post_json("/v1/ask", ask_body).read()
except Exception as error:
    print(f"ask failed: {error}", file=sys.stderr)
    sys.exit(1)

print(f"asked {request_id}; waiting for the answer...", flush=True)
if not finished.wait(timeout_seconds):
    print(f"timed out after {int(timeout_seconds)}s with no respond event", file=sys.stderr)
sys.exit(exit_code["value"])
PYTHON

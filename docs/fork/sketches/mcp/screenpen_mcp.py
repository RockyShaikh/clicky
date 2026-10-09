# screenpen_mcp.py — starter sketch (untested). pip install "mcp[cli]"
# Claude Code:  claude mcp add screenpen -- python3 /path/to/screenpen_mcp.py
import json, subprocess, urllib.request
from mcp.server.fastmcp import FastMCP, Image

mcp = FastMCP("screenpen")
SHOT = "/tmp/screenpen.png"
last_size = {"w": 1280, "h": 800}

@mcp.tool()
def capture_screen() -> list:
    """Screenshot of the user's main display, long edge resized to 1280 px.
    Coordinates for draw_on_screen are pixels in THIS image, origin top-left."""
    subprocess.run(["screencapture", "-x", "-m", SHOT], check=True)
    subprocess.run(["sips", "-Z", "1280", SHOT], check=True, capture_output=True)
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", SHOT],
                         capture_output=True, text=True, check=True).stdout.split()
    last_size["w"] = int(out[out.index("pixelWidth:") + 1])
    last_size["h"] = int(out[out.index("pixelHeight:") + 1])
    return [Image(path=SHOT), f"Image is {last_size['w']}x{last_size['h']} px."]

@mcp.tool()
def draw_on_screen(shapes: list[dict], say: str = "") -> str:
    """Draw over the user's screen. Each shape: {kind: circle|arrow|box|label,
    x, y, x2?, y2?, r?, text?} in capture_screen pixel coordinates.
    Circle is centered on x,y; box is x,y to x2,y2; arrow points at x,y from x2,y2."""
    payload = {"shapes": shapes, "say": say, "imgW": last_size["w"], "imgH": last_size["h"]}
    req = urllib.request.Request("http://127.0.0.1:7777/draw", json.dumps(payload).encode(),
                                 {"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=5)
    return "Drawn. The user can press Esc to clear it."

if __name__ == "__main__":
    mcp.run()

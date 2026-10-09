#!/bin/bash
# usage: ask.sh <screenshot.png> "<question>"   -> prints shape JSON
set -euo pipefail
unset ANTHROPIC_API_KEY                       # use the subscription login, not API billing
DIR="$HOME/.screenpen"; SHOT="$1"; Q="$2"
sips -Z 1280 "$SHOT" >/dev/null               # long edge -> 1280 px, aspect kept
W=$(sips -g pixelWidth  "$SHOT" | awk '/pixelWidth/{print $2}')
H=$(sips -g pixelHeight "$SHOT" | awk '/pixelHeight/{print $2}')
cd "$DIR"                                     # screenshot lives here, so Read needs no prompt
claude -p "Screenshot file: $SHOT. It is ${W}x${H} pixels, origin top-left.
The user is looking at this screen and asked: \"$Q\"
Read the screenshot, then answer in one or two spoken sentences (field: say)
and give shapes to draw, in this image's pixel coordinates (field: shapes).
Point at the center of the exact control. Use at most 3 shapes.
Return an empty shapes list if nothing on screen is relevant." \
  --model sonnet --max-turns 3 --allowedTools Read \
  --output-format json --json-schema "$(cat "$DIR/schema.json")" \
| jq -c --argjson w "$W" --argjson h "$H" '.structured_output + {imgW: $w, imgH: $h}'

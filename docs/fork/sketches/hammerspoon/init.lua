-- ~/.hammerspoon/init.lua — starter sketch (untested). Grant Hammerspoon Accessibility + Screen Recording.
local DIR, ASK = os.getenv("HOME") .. "/.screenpen", os.getenv("HOME") .. "/.screenpen/ask.sh"
local SHOT = DIR .. "/screen.png"
local pen, shotScreen = nil, nil
local voice = hs.speech.new()
local BLUE = { red = 0.12, green = 0.33, blue = 0.94, alpha = 0.95 }

local escKey
local function clearPen()
  if pen then pen:delete(); pen = nil end
  if escKey then escKey:disable() end
end
escKey = hs.hotkey.new({}, "escape", clearPen)

local function arrowHead(x, y, fx, fy)
  local a, L = math.atan(y - fy, x - fx), 16
  return { { x = x - L * math.cos(a - 0.5), y = y - L * math.sin(a - 0.5) }, { x = x, y = y },
           { x = x - L * math.cos(a + 0.5), y = y - L * math.sin(a + 0.5) } }
end

-- result = { say, shapes, imgW, imgH } in screenshot pixels
local function draw(result)
  clearPen()
  local f = (shotScreen or hs.screen.primaryScreen()):fullFrame()   -- points, top-left origin
  local sx, sy = f.w / result.imgW, f.h / result.imgH
  pen = hs.canvas.new(f):level(hs.canvas.windowLevels.overlay)
          :behavior({ "canJoinAllSpaces", "stationary" })
  for _, s in ipairs(result.shapes or {}) do
    local x, y = s.x * sx, s.y * sy
    if s.kind == "circle" then
      pen:appendElements({ type = "circle", action = "stroke", strokeColor = BLUE, strokeWidth = 4,
        center = { x = x, y = y }, radius = (s.r or 28) * sx })
    elseif s.kind == "box" and s.x2 then
      pen:appendElements({ type = "rectangle", action = "stroke", strokeColor = BLUE, strokeWidth = 4,
        roundedRectRadii = { xRadius = 8, yRadius = 8 },
        frame = { x = x, y = y, w = (s.x2 - s.x) * sx, h = (s.y2 - s.y) * sy } })
    elseif s.kind == "arrow" and s.x2 then
      local fx, fy = s.x2 * sx, s.y2 * sy
      pen:appendElements({ type = "segments", action = "stroke", strokeColor = BLUE, strokeWidth = 4,
        coordinates = { { x = fx, y = fy }, { x = x, y = y } } })
      pen:appendElements({ type = "segments", action = "stroke", strokeColor = BLUE, strokeWidth = 4,
        coordinates = arrowHead(x, y, fx, fy) })
    end
    if s.text then
      pen:appendElements({ type = "text", text = s.text, textColor = BLUE, textSize = 18,
        frame = { x = x + 18, y = y + 14, w = 360, h = 26 } })
    end
  end
  pen:canvasMouseEvents(false, false, false, false)   -- keep clicks passing through
  pen:show()
  escKey:enable()                                       -- Esc clears, only while drawn
  if result.say and result.say ~= "" then voice:speak(result.say) end
end

-- the pen also listens locally, so MCP tools, scripts or a person can draw
penServer = hs.httpserver.new(false, false)
penServer:setInterface("localhost")
penServer:setPort(7777)
penServer:setCallback(function(method, path, _, body)
  if method == "POST" and path == "/draw" then
    local ok, result = pcall(hs.json.decode, body)
    if ok and result then
      hs.timer.doAfter(0, function() shotScreen = nil; draw(result) end)
      return "ok", 200, {}
    end
  end
  return "bad request", 400, {}
end)
penServer:start()

-- Ctrl+Option+Space: screenshot first, then ask (dictate with Wispr Flow into the box)
hs.hotkey.bind({ "ctrl", "alt" }, "space", function()
  clearPen()
  shotScreen = hs.mouse.getCurrentScreen()
  shotScreen:snapshot():saveToFile(SHOT)
  hs.focus()
  local button, question = hs.dialog.textPrompt("Ask about your screen", "", "", "Ask", "Cancel")
  if button ~= "Ask" or question == "" then return end
  hs.alert.show("looking…")
  hs.task.new(ASK, function(code, out, err)
    if code ~= 0 then hs.alert.show("screenpen failed: " .. (err or "")); return end
    draw(hs.json.decode(out))
  end, { SHOT, question }):start()
end)

--[[
  ════════════════════════════════════════════════════════════
   Delta Boombox — websocket relayed audio player
   UI copied 1:1 from MM2PepsiMenu (drag + mobile + sidebar tabs)
   Everyone connected to the relay hears what you play.
   Set WS_URL below, then execute.
  ════════════════════════════════════════════════════════════
]]

getgenv().Boombox = getgenv().Boombox or {}
local BB = getgenv().Boombox
if BB.Running then
    BB.Running = false
    task.wait()
    pcall(function()
        if BB.Cleanup then BB.Cleanup() end
    end)
end
BB.Running = true

-- re-running the script cleans up the old instance instead of doing nothing,
-- so you always get the newest code when you paste it again.
local _cleanup = {}
local function onCleanup(fn) _cleanup[#_cleanup + 1] = fn end
local function bind(sig, cb)
    local ok, c = pcall(function() return sig:Connect(cb) end)
    if ok and c then onCleanup(function() pcall(function() c:Disconnect() end) end) end
    return c
end

local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local Tween      = game:GetService("TweenService")
local Http       = game:GetService("HttpService")
local SoundService = game:GetService("SoundService")

local LP = Players.LocalPlayer

local WS_URL    = "wss://boombox-relay.wifiskeleton07.workers.dev"
local SAVE_FILE = "boombox_playlist.json"
local TOGGLE_KEY = Enum.KeyCode.Semicolon

local playlist     = {}
local currentSound = nil
local volume       = 1
local ws           = nil
local connected    = false
local nowPlaying   = ""

local function displayName()
    return pcall(function() return LP.DisplayName end) and LP.DisplayName or LP.Name or "Player"
end

-- ── small request helper (works on Delta) ─────────────────
local function httpGet(url)
    local g = getgenv()
    local fn = g.request or g.http_request or (g.syn and g.syn.request)
    if not fn then return nil end
    local ok, res = pcall(function()
        return fn({ Url = url, Method = "GET", Headers = { ["User-Agent"] = "Mozilla/5.0" } })
    end)
    if ok and res and res.StatusCode == 200 then return res.Body end
    return nil
end

local function fetchName(id)
    local body = httpGet("https://economy.roblox.com/v2/assets/" .. id .. "/details")
    if body then
        local ok, data = pcall(function() return Http:JSONDecode(body) end)
        if ok and data and data.Name then
            return tostring(data.Name)
        end
    end
    body = httpGet("https://catalog.roblox.com/v1/catalog-items/details?assetTypeId=3&subcategoryType=3&itemIds=" .. id)
    if body then
        local ok, data = pcall(function() return Http:JSONDecode(body) end)
        if ok and data.data and data.data[1] and data.data[1].name then
            return tostring(data.data[1].name)
        end
    end
    body = httpGet("https://assetdelivery.roblox.com/v1/asset/?id=" .. id)
    if body then
        local n = body:match('name="Name">(.-)</string>')
        if n and n ~= "" then return n end
    end
    return "Audio " .. id
end

-- ── playlist persistence ──────────────────────────────────
local function savePlaylist()
    local ok = pcall(function()
        local data = { names = {} }
        for _, e in ipairs(playlist) do data.names[#data.names + 1] = e end
        writefile(SAVE_FILE, Http:JSONEncode(data))
    end)
    return ok
end

local function loadPlaylist()
    if isfile and isfile(SAVE_FILE) then
        pcall(function()
            local data = Http:JSONDecode(readfile(SAVE_FILE))
            if type(data) == "table" then
                for _, e in ipairs(data.names or {}) do
                    if type(e) == "table" and e.id then playlist[#playlist + 1] = e end
                end
            end
        end)
    end
end

-- ── websocket (Delta / Synapse / Fluxus style) ────────────
local wsLibCache = nil
local wsLibScanDone = false
local function getWsLib()
    if wsLibCache then return wsLibCache end
    if wsLibScanDone then return nil end
    local g = getgenv()
    local env = getfenv(0)
    local c = {
        g.websocket, env.websocket, _G and _G.websocket,
        g.WebSocket, env.WebSocket, _G and _G.WebSocket,
        g.syn and g.syn.websocket, g.fluxus and g.fluxus.websocket,
        g.http and g.http.websocket,
    }
    wsLibScanDone = true
    for i, lib in ipairs(c) do
        if type(lib) == "table" or type(lib) == "userdata" then
            if lib.connect or lib.Connect then
                print("[Boombox] WS lib found at slot " .. i .. " (" .. tostring(lib) .. ")")
                wsLibCache = lib
                return lib
            end
        end
    end
    for i, lib in ipairs(c) do
        if lib ~= nil then
            print("[Boombox] WS candidate slot " .. i .. ": type=" .. type(lib)
                .. " connect=" .. tostring(lib.connect ~= nil)
                .. " Connect=" .. tostring(lib.Connect ~= nil)
                .. " send=" .. tostring(lib.send ~= nil))
        end
    end
    return nil
end

local function bindEvent(obj, name, cb)
    if not obj then return end
    local ok, v = pcall(function() return obj[name] end)
    if not ok or v == nil then pcall(function() obj[name] = cb end) return end
    if type(v) == "function" then pcall(v, cb) else pcall(function() bind(v, cb) end) end
end

local function wsSend(conn, text)
    if not conn then return false end
    if conn.style == "id" then
        if conn.send then return pcall(function() conn.send(conn.id, text) end) end
        if conn.lib and conn.lib.send then return pcall(function() conn.lib.send(conn.id, text) end) end
        if conn.lib and conn.lib.Send then return pcall(function() conn.lib.Send(conn.id, text) end) end
    else
        local h = conn.obj
        if h then
            if h.Send then return pcall(function() h:Send(text) end) end
            if h.send then return pcall(function() h:send(text) end) end
        end
        if conn.send then return pcall(function() conn.send(h, text) end) end
        if conn.lib and conn.lib.send then return pcall(function() conn.lib.send(h, text) end) end
    end
    return false
end

local function wsClose(conn)
    if not conn then return false end
    if conn.style == "id" then
        if conn.close then return pcall(function() conn.close(conn.id) end) end
        if conn.lib and conn.lib.close then return pcall(function() conn.lib.close(conn.id) end) end
        if conn.lib and conn.lib.Close then return pcall(function() conn.lib.Close(conn.id) end) end
    else
        local h = conn.obj
        if h then
            if h.Close then return pcall(function() h:Close() end) end
            if h.close then return pcall(function() h:close() end) end
        end
        if conn.close then return pcall(function() conn.close(h) end) end
        if conn.lib and conn.lib.close then return pcall(function() conn.lib.close(h) end) end
    end
    return false
end

local function sendMsg(data)
    if not ws then return false end
    local ok = pcall(function() wsSend(ws, Http:JSONEncode(data)) end)
    return ok
end

local handleMessage

-- ── handle introspection + event wiring (Delta object style) ─
local function wireEvent(h, name, fn)
    if not h then return end
    local ok, v = pcall(function() return h[name] end)
    if ok and v ~= nil then
        if type(v) == "function" then
            pcall(function() h[name] = fn end)
        elseif type(v) == "table" or type(v) == "userdata" then
            local okC = pcall(function() v:Connect(fn) end)
            if okC then return end
            local okc = pcall(function() v:connect(fn) end)
            if okc then return end
            pcall(function() h[name] = fn end)
        end
    end
    pcall(function() h[name] = fn end)
    pcall(function() h[name](h, fn) end)
    pcall(function() h:Connect(name, fn) end)
    pcall(function() h.Connect(h, name, fn) end)
end

local function wireEvents(h)
    local events = {
        { "OnOpen", function() setStatus(true) print("[Boombox] Connected to relay") end },
        { "OnMessage", function(msg) handleMessage(msg) end },
        { "OnClose", function() setStatus(false) ws = nil print("[Boombox] Disconnected") end },
        { "OnError", function(err) setStatus(false) ws = nil print("[Boombox] WS error: " .. tostring(err)) end },
    }
    for _, e in ipairs(events) do
        wireEvent(h, e[1], e[2])
        local lname = e[1]:gsub("^On", "on")
        if lname ~= e[1] then wireEvent(h, lname, e[2]) end
    end
end

local function pcallLog(label, fn)
    local ok, err = pcall(fn)
    if not ok then print("[Boombox] ERROR in " .. label .. ": " .. tostring(err)) end
    return ok, err
end

-- ── toast/status (toast prints to console; GUI built later) ─
local statusLabel, npLabel

local function toast(text)
    print("[Boombox] " .. tostring(text))
end

local function setStatus(ok)
    connected = ok
    if not statusLabel then return end
    statusLabel.Text = (ok and "● CONNECTED" or "● OFFLINE") .. "   " .. WS_URL
    statusLabel.TextColor3 = ok and Color3.fromRGB(90, 200, 120) or Color3.fromRGB(220, 90, 90)
end

-- ── audio ─────────────────────────────────────────────────
local function stopAudio()
    if currentSound then
        pcall(function() currentSound:Stop() currentSound:Destroy() end)
        currentSound = nil
    end
end

local function getAudioAttach()
    local char = LP.Character
    if char then
        local root = char:FindFirstChild("HumanoidRootPart")
        if root then return root end
        local head = char:FindFirstChild("Head")
        if head then return head end
    end
    return SoundService
end

local function playLocal(id, name)
    stopAudio()
    currentSound = Instance.new("Sound")
    currentSound.SoundId = "rbxassetid://" .. id
    currentSound.Volume = volume
    currentSound.Name = "BoomboxSound"
    currentSound.Parent = getAudioAttach()
    pcall(function() currentSound:Play() end)
    nowPlaying = name or ("Audio " .. id)
    if npLabel then npLabel.Text = "Now playing: " .. nowPlaying end
    task.spawn(function()
        pcall(function() currentSound.Ended:Wait() end)
        if currentSound then stopAudio() end
        nowPlaying = ""
        if npLabel then npLabel.Text = "Now playing: —" end
    end)
end

local rebuildList

local function addToPlaylist(id, name)
    id = tostring(id)
    for _, e in ipairs(playlist) do
        if tostring(e.id) == id then return false end
    end
    local entry = { id = id, name = name or "Audio " .. id }
    playlist[#playlist + 1] = entry
    savePlaylist()
    task.spawn(function()
        local n = fetchName(id)
        entry.name = n
        savePlaylist()
        if rebuildList then rebuildList() end
    end)
    return true
end

local function playAudio(id, name, fromNetwork)
    local clean = tostring(id):match("(%d+)")
    if not clean then return end
    playLocal(clean, name)
    if not fromNetwork then
        sendMsg({ type = "play", id = clean, name = name, user = displayName() })
        toast("▶ Now playing: " .. (name or clean))
        addToPlaylist(clean, name)
    end
end

handleMessage = function(raw)
    local ok, data = pcall(function() return Http:JSONDecode(raw) end)
    if not ok or type(data) ~= "table" then return end
    if data.type == "play" and data.id then
        playAudio(data.id, data.name, true)
        toast((data.user or "Someone") .. " ▶ " .. (data.name or data.id))
    elseif data.type == "stop" then
        stopAudio()
        toast((data.user or "Someone") .. " stopped the music")
    elseif data.type == "join" then
        toast((data.user or "Someone") .. " joined the room")
    end
end

local objHangs = false

local function connectToServer()
    local lib = getWsLib()
    if not lib then return false end
    local connectFn = lib.connect or lib.Connect
    local sendFn = lib.send or lib.Send
    local closeFn = lib.close or lib.Close
    print("[Boombox] connecting to " .. WS_URL)

    local callbacks = {
        onOpen = function() setStatus(true) print("[Boombox] Connected to relay") end,
        onMessage = function(msg) handleMessage(msg) end,
        onClose = function() setStatus(false) ws = nil print("[Boombox] Disconnected") end,
        onError = function(err) setStatus(false) ws = nil print("[Boombox] WS error: " .. tostring(err)) end,
        OnOpen = function() setStatus(true) print("[Boombox] Connected to relay") end,
        OnMessage = function(msg) handleMessage(msg) end,
        OnClose = function() setStatus(false) ws = nil print("[Boombox] Disconnected") end,
        OnError = function(err) setStatus(false) ws = nil print("[Boombox] WS error: " .. tostring(err)) end,
    }

    local resB = nil
    local okB, errB = pcall(function() resB = connectFn(WS_URL, callbacks) end)
    if okB and resB ~= nil then
        print("[Boombox] connect returned handle=" .. tostring(resB))
        pcallLog("wireEvents", function() wireEvents(resB) end)
        ws = { style = "obj", obj = resB, lib = lib, send = sendFn, close = closeFn }
        setStatus(true)
        print("[Boombox] Connected to relay")
        sendMsg({ type = "join", user = displayName() })
        return true
    end
    if not okB then print("[Boombox] callback-table connect failed: " .. tostring(errB)) end

    if objHangs then
        print("[Boombox] skipping object-style connect (it hung before)")
        return false
    end

    local done, resA = false, nil
    task.spawn(function()
        local ok, r = pcall(function() return connectFn(WS_URL) end)
        done = true
        if ok then resA = r end
    end)
    local t0 = tick()
    while not done and tick() - t0 < 4 do task.wait(0.05) end
    if not done then
        objHangs = true
        print("[Boombox] object-style connect blocked 4s — skipping it from now on")
        return false
    end
    if resA == nil then
        print("[Boombox] object-style connect returned nil")
        return false
    end
    print("[Boombox] plain connect returned handle=" .. tostring(resA))
    pcallLog("wireEvents", function() wireEvents(resA) end)
    ws = { style = "obj", obj = resA, lib = lib, send = sendFn, close = closeFn }
    return true
end

local libWarned = false
task.spawn(function()
    while BB.Running do
        pcallLog("reconnect-loop", function()
            if not ws then
                local bad = WS_URL:find("YOUR%-URL") ~= nil
                if bad then
                    setStatus(false)
                    toast("Put your relay URL at WS_URL in the script!")
                else
                    if not getWsLib() then
                        if not libWarned then
                            libWarned = true
                            print("[Boombox] No websocket lib found (checked websocket/WebSocket/syn/fluxus/http)")
                        end
                    else
                        connectToServer()
                        if not connected then task.wait(1) end
                    end
                end
            end
        end)
        task.wait(5)
    end
end)

-- ══════════════════════════════════════════════════════════
--  GUI — MM2PepsiMenu style (drag + mobile + sidebar tabs)
-- ══════════════════════════════════════════════════════════
local isMobile = UIS.TouchEnabled and not UIS.KeyboardEnabled

local UG = Instance.new("ScreenGui")
UG.ResetOnSpawn = false
UG.Name = "BoomboxGui"
pcall(function() UG.Parent = game:GetService("CoreGui") end)
if not UG.Parent then UG.Parent = LP:WaitForChild("PlayerGui") end

local mobileGui
if isMobile then
    mobileGui = Instance.new("ScreenGui")
    mobileGui.Name = "BoomboxMobile"
    mobileGui.ResetOnSpawn = false
    mobileGui.DisplayOrder = 999
    pcall(function() mobileGui.Parent = game:GetService("CoreGui") end)
    if not mobileGui.Parent then mobileGui.Parent = LP:WaitForChild("PlayerGui") end
end

local function Make(class, parent, props)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        if k ~= "Parent" then inst[k] = v end
    end
    if parent then inst.Parent = parent end
    return inst
end

local camV = workspace.CurrentCamera
local VIEWPORT = camV and camV.ViewportSize or Vector2.new(1280, 720)
local WINDOW_W = isMobile and math.clamp(VIEWPORT.X - 24, 280, 380) or 580
local WINDOW_H = isMobile and math.clamp(VIEWPORT.Y * 0.55, 240, 320) or 460
local TAB_W = math.floor(WINDOW_W * 0.24)
local FONT = Enum.Font.Gotham
local FONT_BOLD = Enum.Font.GothamBold

local function clampWinToScreen(w)
    if not w then return end
    local sz = w.AbsoluteSize
    if sz.X <= 0 or sz.Y <= 0 then return end
    local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or VIEWPORT
    local x = math.clamp(w.AbsolutePosition.X, -sz.X + 40, vp.X - 40)
    local y = math.clamp(w.AbsolutePosition.Y, 16, vp.Y - 40)
    w.Position = UDim2.new(0, x, 0, y)
end

local TXT = Color3.fromRGB(200, 200, 200)
local TXT_TITLE = Color3.fromRGB(230, 230, 230)

local function RoundedFrame(parent, color, radius)
    local f = Make("Frame", parent, {
        BackgroundColor3 = color,
        BorderSizePixel = 0,
        ClipsDescendants = true
    })
    Make("UICorner", f, { CornerRadius = UDim.new(0, radius or 4) })
    return f
end

local _order = 0
local function NextOrder() _order = _order + 1 return _order end

local GRAD_NORM = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(40, 40, 40)),
    ColorSequenceKeypoint.new(0.75, Color3.fromRGB(60, 60, 60)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(130, 130, 130))
})
local GRAD_HOVER = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(55, 55, 55)),
    ColorSequenceKeypoint.new(0.75, Color3.fromRGB(75, 75, 75)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 150, 150))
})
local GRAD_DOWN = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(30, 30, 30)),
    ColorSequenceKeypoint.new(0.75, Color3.fromRGB(45, 45, 45)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(100, 100, 100))
})

local function GradientBtn(parent, text, size)
    local f = RoundedFrame(parent, Color3.new(1, 1, 1), 4)
    f.Size = size or UDim2.new(1, 0, 0, isMobile and 34 or 26)
    f.LayoutOrder = NextOrder()
    local g = Make("UIGradient", f, {
        Color = GRAD_NORM,
        Rotation = 270
    })
    Make("UIStroke", f, { Color = Color3.new(0, 0, 0), Thickness = 1 })
    Make("TextLabel", f, {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = TXT,
        TextSize = 14,
        Font = FONT,
        TextXAlignment = Enum.TextXAlignment.Center,
        TextYAlignment = Enum.TextYAlignment.Center
    })
    local click = Make("TextButton", f, {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = ""
    })
    bind(click.MouseEnter, function() g.Color = GRAD_HOVER end)
    bind(click.MouseLeave, function() g.Color = GRAD_NORM end)
    bind(click.MouseButton1Down, function() g.Color = GRAD_DOWN end)
    bind(click.MouseButton1Up, function() g.Color = GRAD_HOVER end)
    return f, click
end

local function Slider(parent, text, min, max, default)
    min = min or 0
    max = max or 10
    default = default or 1
    local f = Make("Frame", parent, {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundTransparency = 1,
        LayoutOrder = NextOrder()
    })
    local valLabel = Make("TextLabel", f, {
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1,
        Text = text .. " - " .. default,
        TextColor3 = TXT,
        TextSize = 13,
        Font = FONT,
        TextXAlignment = Enum.TextXAlignment.Left
    })
    local track = RoundedFrame(f, Color3.fromRGB(40, 40, 40), 2)
    track.Size = UDim2.new(1, 0, 0, 4)
    track.Position = UDim2.new(0, 0, 0, 16)
    local fill = RoundedFrame(track, Color3.fromRGB(60, 140, 240), 2)
    fill.Size = UDim2.new((default - min) / (max - min), 0, 1, 0)
    local thumb = Make("Frame", track, {
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        Size = UDim2.new(0, 12, 0, 12),
        Position = UDim2.new((default - min) / (max - min), -6, 0.5, -6)
    })
    Make("UICorner", thumb, { CornerRadius = UDim.new(0, 6) })
    Make("UIStroke", thumb, { Color = Color3.fromRGB(50, 50, 50), Thickness = 1 })
    Make("UIGradient", thumb, {
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(180, 180, 180)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 120, 120))
        }),
        Rotation = 270
    })
    local curVal = default
    local callback = nil
    local function updateSlider(inputX)
        local abs = track.AbsolutePosition.X
        local siz = track.AbsoluteSize.X
        local pct = math.clamp((inputX - abs) / siz, 0, 1)
        curVal = min + pct * (max - min)
        curVal = math.floor(curVal * 10 + 0.5) / 10
        pct = (curVal - min) / (max - min)
        fill.Size = UDim2.new(pct, 0, 1, 0)
        thumb.Position = UDim2.new(pct, -6, 0.5, -6)
        valLabel.Text = text .. " - " .. curVal
        if callback then callback(curVal) end
    end
    local sliding = false
    local thumbBtn = Make("TextButton", thumb, {
        Size = UDim2.new(1, 8, 1, 8),
        Position = UDim2.new(0, -4, 0, -4),
        BackgroundTransparency = 1,
        Text = ""
    })
    bind(thumbBtn.MouseButton1Down, function() sliding = true end)
    local trackBtn = Make("TextButton", track, {
        Size = UDim2.new(1, 0, 1, 16),
        Position = UDim2.new(0, 0, 0, -8),
        BackgroundTransparency = 1,
        Text = ""
    })
    bind(trackBtn.MouseButton1Down, function()
        sliding = true
        local mouse = UIS:GetMouseLocation()
        updateSlider(mouse.X)
    end)
    bind(UIS.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            sliding = false
        end
    end)
    bind(UIS.InputChanged, function(input)
        if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            updateSlider(input.Position.X)
        end
    end)
    local function SetCallback(cb) callback = cb end
    local function SetValue(val)
        curVal = math.clamp(val, min, max)
        curVal = math.floor(curVal * 10 + 0.5) / 10
        local pct = (curVal - min) / (max - min)
        fill.Size = UDim2.new(pct, 0, 1, 0)
        thumb.Position = UDim2.new(pct, -6, 0.5, -6)
        valLabel.Text = text .. " - " .. curVal
        if callback then callback(curVal) end
    end
    return f, function() return curVal end, SetCallback, SetValue
end

local function Seeker(parent)
    local f = Make("Frame", parent, {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundTransparency = 1,
        LayoutOrder = NextOrder()
    })
    local valLabel = Make("TextLabel", f, {
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1,
        Text = "Time - 0:00 / 0:00",
        TextColor3 = TXT,
        TextSize = 13,
        Font = FONT,
        TextXAlignment = Enum.TextXAlignment.Left
    })
    local track = RoundedFrame(f, Color3.fromRGB(40, 40, 40), 2)
    track.Size = UDim2.new(1, 0, 0, 4)
    track.Position = UDim2.new(0, 0, 0, 16)
    local fill = RoundedFrame(track, Color3.fromRGB(60, 140, 240), 2)
    fill.Size = UDim2.new(0, 0, 1, 0)
    local thumb = Make("Frame", track, {
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        Size = UDim2.new(0, 12, 0, 12),
        Position = UDim2.new(0, -6, 0.5, -6)
    })
    Make("UICorner", thumb, { CornerRadius = UDim.new(0, 6) })
    Make("UIStroke", thumb, { Color = Color3.fromRGB(50, 50, 50), Thickness = 1 })
    local sliding = false
    local function fmt(s)
        s = math.floor(math.max(s, 0))
        return math.floor(s / 60) .. ":" .. string.format("%02d", s % 60)
    end
    local function setPct(pct, seek)
        pct = math.clamp(pct, 0, 1)
        fill.Size = UDim2.new(pct, 0, 1, 0)
        thumb.Position = UDim2.new(pct, -6, 0.5, -6)
        if seek then
            local snd = currentSound
            if snd then
                pcall(function()
                    snd.TimePosition = pct * (snd.TimeLength or 0)
                end)
            end
        end
    end
    local function fromX(inputX)
        local abs = track.AbsolutePosition.X
        local siz = track.AbsoluteSize.X
        return math.clamp((inputX - abs) / siz, 0, 1)
    end
    local function refresh()
        local snd = currentSound
        if not snd then
            valLabel.Text = "Time - 0:00 / 0:00"
            setPct(0, false)
            return
        end
        local len = snd.TimeLength or 0
        if len <= 0 then return end
        local pos = snd.TimePosition or 0
        valLabel.Text = "Time - " .. fmt(pos) .. " / " .. fmt(len)
        if not sliding then setPct(pos / len, false) end
    end
    local thumbBtn = Make("TextButton", thumb, {
        Size = UDim2.new(1, 8, 1, 8),
        Position = UDim2.new(0, -4, 0, -4),
        BackgroundTransparency = 1,
        Text = ""
    })
    bind(thumbBtn.MouseButton1Down, function() sliding = true end)
    local trackBtn = Make("TextButton", track, {
        Size = UDim2.new(1, 0, 1, 16),
        Position = UDim2.new(0, 0, 0, -8),
        BackgroundTransparency = 1,
        Text = ""
    })
    bind(trackBtn.MouseButton1Down, function()
        sliding = true
        local mouse = UIS:GetMouseLocation()
        setPct(fromX(mouse.X), true)
        refresh()
    end)
    bind(UIS.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            if sliding then
                sliding = false
                refresh()
            end
        end
    end)
    bind(UIS.InputChanged, function(input)
        if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local pct = fromX(input.Position.X)
            setPct(pct, true)
            refresh()
        end
    end)
    task.spawn(function()
        while true do
            task.wait(0.5)
            refresh()
        end
    end)
    return f
end

local function TextInput(parent, text, placeholder)
    local f = Make("Frame", parent, {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundTransparency = 1,
        LayoutOrder = NextOrder()
    })
    if text ~= "" then
        Make("TextLabel", f, {
            Size = UDim2.new(0, 80, 1, 0),
            BackgroundTransparency = 1,
            Text = text,
            TextColor3 = TXT,
            TextSize = 13,
            Font = FONT,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Center
        })
    end
    local box = Make("TextBox", f, {
        Size = UDim2.new(1, text ~= "" and -86 or 0, 1, -4),
        Position = UDim2.new(0, text ~= "" and 84 or 0, 0, 2),
        BackgroundColor3 = Color3.fromRGB(35, 35, 35),
        TextColor3 = TXT,
        TextSize = 13,
        Font = FONT,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        Text = "",
        PlaceholderText = placeholder or "",
        PlaceholderColor3 = Color3.fromRGB(100, 100, 100)
    })
    Make("UIStroke", box, { Color = Color3.fromRGB(60, 60, 60), Thickness = 1 })
    Make("UICorner", box, { CornerRadius = UDim.new(0, 3) })
    Make("UIPadding", box, { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) })
    return f, box
end

local function ConfigLabel(parent, text)
    local f = Make("Frame", parent, {
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        LayoutOrder = NextOrder()
    })
    Make("TextLabel", f, {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = TXT,
        TextSize = 12,
        Font = FONT,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center
    })
    return f
end

-- ══════════════════════════════════════════════════════════
--  WINDOW
-- ══════════════════════════════════════════════════════════
local TBAR_H = 22
local win = RoundedFrame(nil, Color3.fromRGB(56, 56, 56), 4)
win.Size = UDim2.new(0, WINDOW_W, 0, WINDOW_H)
win.Position = UDim2.new(0.5, -WINDOW_W / 2, 0.5, -WINDOW_H / 2)
win.BackgroundTransparency = 0.4
win.Parent = UG
local winStroke = Make("UIStroke", win, { Color = Color3.new(0, 0, 0), Thickness = 1 })

-- TITLEBAR
local tbar = Make("Frame", win, {
    BackgroundColor3 = Color3.fromRGB(45, 45, 45),
    BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, TBAR_H),
    BackgroundTransparency = 0.3
})
Make("TextLabel", tbar, {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1,
    Text = "🎧 Boombox",
    TextColor3 = TXT_TITLE,
    TextSize = 13,
    Font = FONT_BOLD,
    TextXAlignment = Enum.TextXAlignment.Center,
    TextYAlignment = Enum.TextYAlignment.Center
})

-- ══════════════════════════════════════════════════════════
--  DRAG — copied 1:1 from MM2PepsiMenu
-- ══════════════════════════════════════════════════════════
local dragBtn = Make("TextButton", win, {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1,
    Text = "",
    ZIndex = 1
})

local dragging = false
local dragOffset = Vector2.new()

local function isInteractive(obj)
    while obj and obj ~= win do
        if obj ~= dragBtn and (obj:IsA("TextButton") or obj:IsA("ImageButton") or obj:IsA("TextBox")) then
            return true
        end
        obj = obj.Parent
    end
    return false
end

bind(dragBtn.MouseButton1Down, function()
    local mouse = UIS:GetMouseLocation()
    local hit = LP.PlayerGui:GetGuiObjectsAtPosition(mouse.X, mouse.Y)
    for _, v in ipairs(hit) do
        if isInteractive(v) then return end
    end
    dragging = true
    dragOffset = Vector2.new(mouse.X - win.AbsolutePosition.X, mouse.Y - win.AbsolutePosition.Y)
    winStroke.Color = Color3.new(1, 1, 1)
end)

bind(UIS.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        if dragging then
            dragging = false
            winStroke.Color = Color3.new(0, 0, 0)
        end
    end
end)

bind(UIS.InputChanged, function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local mouse = UIS:GetMouseLocation()
        win.Position = UDim2.new(0, mouse.X - dragOffset.X, 0, mouse.Y - dragOffset.Y)
        clampWinToScreen(win)
    end
end)

-- TITLEBAR GRAB — same pattern as the MM2 mobile toggle button (InputBegan +
-- GetMouseLocation), so it fires reliably on touch as well as mouse. It shares
-- the same dragging/dragOffset state as the dragBtn above, so both paths work.
local tbarDragBtn = Make("TextButton", win, {
    Size = UDim2.new(1, 0, 0, TBAR_H),
    BackgroundTransparency = 1,
    Text = "",
    ZIndex = 2
})
bind(tbarDragBtn.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
        local mouse = UIS:GetMouseLocation()
        dragOffset = Vector2.new(mouse.X - win.AbsolutePosition.X, mouse.Y - win.AbsolutePosition.Y)
        dragging = true
        winStroke.Color = Color3.new(1, 1, 1)
    end
end)

-- SIDEBAR
local tabArea
if isMobile then
    tabArea = Make("ScrollingFrame", win, {
        BackgroundColor3 = Color3.fromRGB(56, 56, 56),
        BorderSizePixel = 0,
        Size = UDim2.new(0, TAB_W, 1, -TBAR_H),
        Position = UDim2.new(0, 0, 0, TBAR_H),
        BackgroundTransparency = 0.4,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = Color3.fromRGB(80, 80, 80),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y
    })
    Make("UIListLayout", tabArea, { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder })
    Make("UIPadding", tabArea, { PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) })
else
    tabArea = Make("Frame", win, {
        BackgroundColor3 = Color3.fromRGB(56, 56, 56),
        BorderSizePixel = 0,
        Size = UDim2.new(0, TAB_W, 1, -TBAR_H),
        Position = UDim2.new(0, 0, 0, TBAR_H),
        BackgroundTransparency = 0.4
    })
end

Make("Frame", win, {
    Size = UDim2.new(0, 1, 1, -TBAR_H),
    Position = UDim2.new(0, TAB_W, 0, TBAR_H),
    BackgroundColor3 = Color3.fromRGB(180, 180, 180),
    BorderSizePixel = 0,
    BackgroundTransparency = 0.5
})

local content = Make("Frame", win, {
    BackgroundColor3 = Color3.fromRGB(50, 50, 50),
    BorderSizePixel = 0,
    Size = UDim2.new(0, WINDOW_W - TAB_W - 1, 1, -TBAR_H),
    Position = UDim2.new(0, TAB_W + 1, 0, TBAR_H),
    BackgroundTransparency = 0.4
})

-- TABS
local tabNames = { "Player", "Playlist" }
local tabFrames = {}
local TAB_SEL_GRAD = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(35, 35, 35)),
    ColorSequenceKeypoint.new(0.75, Color3.fromRGB(55, 55, 55)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 120, 120))
})

for i, name in ipairs(tabNames) do
    local sel = (i == 1)
    local f = RoundedFrame(tabArea, Color3.new(1, 1, 1), 3)
    if isMobile then
        f.Size = UDim2.new(1, -8, 0, 34)
        f.LayoutOrder = i
    else
        f.Size = UDim2.new(1, -14, 0, 26)
        f.Position = UDim2.new(0, 7, 0, (i - 1) * 30 + 6)
    end
    Make("UIStroke", f, { Color = Color3.new(0, 0, 0), Thickness = 1 })
    local tg = Make("UIGradient", f, { Color = sel and TAB_SEL_GRAD or GRAD_NORM, Rotation = 270 })
    Make("TextLabel", f, {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = name,
        TextColor3 = sel and TXT_TITLE or TXT,
        TextSize = 16,
        Font = sel and FONT_BOLD or FONT,
        TextXAlignment = Enum.TextXAlignment.Center,
        TextYAlignment = Enum.TextYAlignment.Center
    })
    local click = Make("TextButton", f, {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = ""
    })
    if not sel then
        bind(click.MouseEnter, function() tg.Color = GRAD_HOVER end)
        bind(click.MouseLeave, function() tg.Color = GRAD_NORM end)
    end
    tabFrames[i] = { frame = f, click = click, tg = tg, name = name }
end

-- CONTENT PAGES
local pages = {}
for i = 1, #tabNames do
    local page = Make("ScrollingFrame", content, {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = Color3.fromRGB(80, 80, 80),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        BorderSizePixel = 0,
        Visible = (i == 1)
    })
    Make("UIListLayout", page, { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder })
    Make("UIPadding", page, { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) })
    pages[i] = page
end

-- Tab switching
for i = 1, #tabNames do
    bind(tabFrames[i].click.MouseButton1Click, function()
        for j = 1, #tabNames do
            pages[j].Visible = (j == i)
            tabFrames[j].tg.Color = (j == i) and TAB_SEL_GRAD or GRAD_NORM
            local lbl = tabFrames[j].frame:FindFirstChildOfClass("TextLabel")
            if lbl then
                lbl.TextColor3 = (j == i) and TXT_TITLE or TXT
                lbl.Font = (j == i) and FONT_BOLD or FONT
            end
        end
    end)
end

-- ══════════════════════════════════════════════════════════
--  PLAYER PAGE
-- ══════════════════════════════════════════════════════════
local playerPage = pages[1]
local playlistPage = pages[2]

local stFrame = ConfigLabel(playerPage, "Status: ...")
statusLabel = stFrame:FindFirstChildOfClass("TextLabel")

local npFrame = ConfigLabel(playerPage, "Now playing: —")
npLabel = npFrame:FindFirstChildOfClass("TextLabel")

local _, idBox = TextInput(playerPage, "Audio ID", "Enter audio ID...")

local playRow = Make("Frame", playerPage, {
    Size = UDim2.new(1, 0, 0, isMobile and 38 or 30),
    BackgroundTransparency = 1,
    LayoutOrder = NextOrder()
})
Make("UIListLayout", playRow, {
    FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 6),
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    SortOrder = Enum.SortOrder.LayoutOrder
})
local _, playClick = GradientBtn(playRow, "▶ Play", UDim2.new(0.5, -4, 1, 0))
local _, stopClick = GradientBtn(playRow, "■ Stop", UDim2.new(0.5, -4, 1, 0))

local _, _, volSetCb, _ = Slider(playerPage, "Volume", 0, 10, 10)
volSetCb(function(v)
    volume = v / 10
    if currentSound then pcall(function() currentSound.Volume = volume end) end
end)

Seeker(playerPage)

-- ══════════════════════════════════════════════════════════
--  PLAYLIST PAGE
-- ══════════════════════════════════════════════════════════
local listRow = Make("Frame", playlistPage, {
    Size = UDim2.new(1, 0, 0, isMobile and 38 or 30),
    BackgroundTransparency = 1,
    LayoutOrder = NextOrder()
})
Make("UIListLayout", listRow, {
    FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 6),
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    SortOrder = Enum.SortOrder.LayoutOrder
})
local _, saveClick = GradientBtn(listRow, "＋ Save ID", UDim2.new(0.5, -4, 1, 0))
local _, clearClick = GradientBtn(listRow, "✕ Clear", UDim2.new(0.5, -4, 1, 0))

local rows = {}
rebuildList = function()
    for _, r in ipairs(rows) do if r and r.Parent then r:Destroy() end end
    rows = {}
    for _, entry in ipairs(playlist) do
        local row = RoundedFrame(playlistPage, Color3.new(1, 1, 1), 3)
        row.Size = UDim2.new(1, 0, 0, 36)
        row.LayoutOrder = NextOrder()
        Make("UIStroke", row, { Color = Color3.new(0, 0, 0), Thickness = 1 })
        Make("TextLabel", row, {
            Size = UDim2.new(1, -64, 0, 16),
            Position = UDim2.new(0, 6, 0, 2),
            BackgroundTransparency = 1,
            Text = entry.name or ("Audio " .. entry.id),
            TextColor3 = TXT,
            TextSize = 13,
            Font = FONT,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd
        })
        Make("TextLabel", row, {
            Size = UDim2.new(1, -64, 0, 13),
            Position = UDim2.new(0, 6, 0, 19),
            BackgroundTransparency = 1,
            Text = tostring(entry.id),
            TextColor3 = Color3.fromRGB(120, 120, 120),
            TextSize = 10,
            Font = FONT,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd
        })
        local playB = Make("TextButton", row, {
            Size = UDim2.new(0, 26, 0, 26),
            Position = UDim2.new(1, -60, 0, 5),
            BackgroundColor3 = Color3.fromRGB(50, 50, 50),
            Text = "▶",
            TextColor3 = TXT,
            TextSize = 12,
            Font = FONT_BOLD,
            AutoButtonColor = true
        })
        Make("UICorner", playB, { CornerRadius = UDim.new(0, 3) })
        local delB = Make("TextButton", row, {
            Size = UDim2.new(0, 26, 0, 26),
            Position = UDim2.new(1, -30, 0, 5),
            BackgroundColor3 = Color3.fromRGB(40, 40, 40),
            Text = "✕",
            TextColor3 = Color3.fromRGB(230, 90, 90),
            TextSize = 12,
            Font = FONT_BOLD,
            AutoButtonColor = true
        })
        Make("UICorner", delB, { CornerRadius = UDim.new(0, 3) })
        bind(playB.MouseButton1Click, function() playAudio(entry.id, entry.name) end)
        bind(delB.MouseButton1Click, function()
            playlist[entry] = nil
            local clean = {}
            for _, e in ipairs(playlist) do if e then clean[#clean + 1] = e end end
            playlist = clean
            savePlaylist()
            rebuildList()
        end)
        rows[#rows + 1] = row
    end
end

-- ══════════════════════════════════════════════════════════
--  ACTIONS
-- ══════════════════════════════════════════════════════════
bind(playClick.MouseButton1Click, function()
    local id = tostring(idBox.Text):match("(%d+)")
    if not id then return toast("Enter an audio ID first") end
    playAudio(id)
end)

bind(stopClick.MouseButton1Click, function()
    stopAudio()
    sendMsg({ type = "stop", user = displayName() })
end)

bind(saveClick.MouseButton1Click, function()
    local id = tostring(idBox.Text):match("(%d+)")
    if not id then return toast("Enter an audio ID first") end
    for _, e in ipairs(playlist) do
        if tostring(e.id) == id then return toast("Already in playlist") end
    end
    local entry = { id = id, name = "Audio " .. id }
    playlist[#playlist + 1] = entry
    rebuildList()
    savePlaylist()
    toast("Saving...")
    task.spawn(function()
        local n = fetchName(id)
        entry.name = n
        savePlaylist()
        rebuildList()
        toast("Saved: " .. n)
    end)
end)

bind(clearClick.MouseButton1Click, function()
    playlist = {}
    savePlaylist()
    rebuildList()
end)

-- ══════════════════════════════════════════════════════════
--  MOBILE TOGGLE BUTTON — copied 1:1 from MM2PepsiMenu
-- ══════════════════════════════════════════════════════════
if isMobile then
    local mobileBtn = Make("TextButton", mobileGui, {
        Name = "BoomboxToggle",
        Size = UDim2.new(0, 50, 0, 50),
        Position = UDim2.new(0.5, 0, 0, 10),
        AnchorPoint = Vector2.new(0.5, 0),
        BackgroundColor3 = Color3.fromRGB(35, 35, 35),
        BackgroundTransparency = 0.3,
        BorderSizePixel = 0,
        Text = "🎧",
        TextColor3 = Color3.fromRGB(200, 200, 200),
        TextSize = 22,
        Font = FONT,
        ZIndex = 100,
        AutoButtonColor = true
    })
    Make("UICorner", mobileBtn, { CornerRadius = UDim.new(1, 0) })
    Make("UIStroke", mobileBtn, { Color = Color3.fromRGB(100, 100, 100), Thickness = 1 })
    Make("UIAspectRatioConstraint", mobileBtn, { AspectRatio = 1 })

    local guiHidden = false
    local function toggleGui()
        guiHidden = not guiHidden
        UG.Enabled = not guiHidden
        if not guiHidden then
            win.Position = UDim2.new(0.5, -WINDOW_W / 2, 0, 70)
            clampWinToScreen(win)
        end
        toast(guiHidden and "GUI hidden" or "GUI shown")
    end

    local btnDragging = false
    local btnStartPos = Vector2.new()
    local btnDragOffset = Vector2.new()

    bind(mobileBtn.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            btnStartPos = UIS:GetMouseLocation()
            btnDragOffset = Vector2.new(btnStartPos.X - mobileBtn.AbsolutePosition.X, btnStartPos.Y - mobileBtn.AbsolutePosition.Y)
            btnDragging = true
        end
    end)

    bind(UIS.InputChanged, function(input)
        if not btnDragging then return end
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseMovement then
            local pos = UIS:GetMouseLocation()
            mobileBtn.Position = UDim2.new(0, pos.X - btnDragOffset.X, 0, pos.Y - btnDragOffset.Y)
            mobileBtn.AnchorPoint = Vector2.new(0, 0)
        end
    end)

    bind(mobileBtn.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            if btnDragging then
                btnDragging = false
                local endPos = UIS:GetMouseLocation()
                local moved = (Vector2.new(endPos.X, endPos.Y) - btnStartPos).Magnitude
                if moved < 15 then
                    toggleGui()
                end
            end
        end
    end)
end

-- keyboard toggle (desktop)
bind(UIS.InputBegan, function(input, processed)
    if processed then return end
    if input.KeyCode == TOGGLE_KEY then
        if not UG.Enabled then
            win.Position = UDim2.new(0.5, -WINDOW_W / 2, 0, 70)
            clampWinToScreen(win)
        end
        UG.Enabled = not UG.Enabled
    end
end)

-- ══════════════════════════════════════════════════════════
--  START
-- ══════════════════════════════════════════════════════════
loadPlaylist()
rebuildList()
setStatus(connected)
toast("Boombox loaded")

BB.Cleanup = function()
    BB.Running = false
    local conns = _cleanup
    _cleanup = {}
    for i = #conns, 1, -1 do pcall(conns[i]) end
    stopAudio()
    pcall(function() if UG then UG:Destroy() end end)
    pcall(function() if mobileGui then mobileGui:Destroy() end end)
end

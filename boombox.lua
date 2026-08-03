--[[
  ════════════════════════════════════════════════════════════
   Delta Boombox — websocket relayed audio player (with playlist)
   ────────────────────────────────────────────────────────────
   ▶ Everyone who runs this (executor OR web player) connects
     to the same relay server. When anyone plays a song, the
     relay broadcasts it and everyone hears it.
   ▶ Playlist is saved locally (writefile) and shows song names.

   SET THE URL BELOW to your relay server, then execute.
   ════════════════════════════════════════════════════════════
]]

getgenv().Boombox = getgenv().Boombox or {}
if getgenv().Boombox.Running then return end
getgenv().Boombox.Running = true

local Players    = game:GetService("Players")
local Tween      = game:GetService("TweenService")
local Http       = game:GetService("HttpService")
local UIS        = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")

local LP = Players.LocalPlayer

local WS_URL   = "wss://YOUR-URL-HERE"      -- <<< YOUR RELAY URL
local SAVE_FILE = "boombox_playlist.json"

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
    local body = httpGet("https://catalog.roblox.com/v1/catalog-items/details?assetTypeId=3&subcategoryType=3&itemIds=" .. id)
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

-- ── websocket (works with Delta / Synapse / Fluxus style) ─
local function getWsLib()
    local g = getgenv()
    local c = {
        g.WebSocket, g.syn and g.syn.websocket, g.fluxus and g.fluxus.websocket,
        g.http and g.http.websocket,
    }
    for _, lib in ipairs(c) do
        if (type(lib) == "table" or type(lib) == "userdata") and lib.connect then
            return lib
        end
    end
    return nil
end

local function bindEvent(obj, name, cb)
    if not obj then return end
    local ok, v = pcall(function() return obj[name] end)
    if not ok or v == nil then pcall(function() obj[name] = cb end) return end
    if type(v) == "function" then pcall(v, cb) else pcall(function() v:Connect(cb) end) end
end

local function wsSend(obj, text)
    if obj.Send then obj:Send(text) elseif obj.send then obj:send(text) end
end

local function wsClose(obj)
    if obj.Close then obj:Close() elseif obj.close then obj:close() end
end

local function sendMsg(data)
    if not ws then return false end
    local ok = pcall(function() wsSend(ws, Http:JSONEncode(data)) end)
    return ok
end

-- ── toast + status ────────────────────────────────────────
local toastLabel, statusDot, statusText

local function toast(text)
    if not toastLabel then return end
    toastLabel.Text = text
    toastLabel.TextTransparency = 0
    toastLabel.BackgroundTransparency = 0.25
    local ti = Tween:Create(toastLabel, TweenInfo.new(2.2), { TextTransparency = 1, BackgroundTransparency = 1 })
    ti:Play()
    task.delay(2.2, function() ti:Cancel() toastLabel.TextTransparency = 1 toastLabel.BackgroundTransparency = 1 end)
end

local function setStatus(ok)
    connected = ok
    if not statusDot or not statusText then return end
    statusDot.BackgroundColor3 = ok and Color3.fromRGB(34, 197, 94) or Color3.fromRGB(239, 68, 68)
    statusText.Text = ok and "CONNECTED" or "OFFLINE"
end

-- ── audio ─────────────────────────────────────────────────
local function stopAudio()
    if currentSound then
        pcall(function() currentSound:Stop() currentSound:Destroy() end)
        currentSound = nil
    end
end

local function playLocal(id, name)
    stopAudio()
    currentSound = Instance.new("Sound")
    currentSound.SoundId = "rbxassetid://" .. id
    currentSound.Volume = volume
    currentSound.Name = "BoomboxSound"
    currentSound.Parent = SoundService
    pcall(function() currentSound:Play() end)
    nowPlaying = name or ("Audio " .. id)
    task.spawn(function()
        pcall(function() currentSound.Ended:Wait() end)
        if currentSound then stopAudio() end
        nowPlaying = ""
    end)
end

local function playAudio(id, name, fromNetwork)
    local clean = tostring(id):match("(%d+)")
    if not clean then return end
    playLocal(clean, name)
    if not fromNetwork then
        sendMsg({ type = "play", id = clean, name = name, user = displayName() })
        toast("▶ Now playing: " .. (name or clean))
    end
end

local function handleMessage(raw)
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

local function connectToServer()
    local lib = getWsLib()
    if not lib then return false end
    local ok, obj = pcall(function() return lib.connect(WS_URL) end)
    if not ok or not obj then return false end
    ws = obj
    bindEvent(obj, "OnMessage", handleMessage)
    bindEvent(obj, "OnOpen", function() setStatus(true) toast("Connected to relay") end)
    bindEvent(obj, "OnClose", function() setStatus(false) ws = nil end)
    bindEvent(obj, "OnError", function() setStatus(false) ws = nil end)
    return true
end

task.spawn(function()
    while getgenv().Boombox.Running do
        if not ws then
            local bad = WS_URL:find("YOUR%-URL") ~= nil
            if bad then
                setStatus(false)
                toast("Put your relay URL at WS_URL in the script!")
            else
                connectToServer()
                if not connected then task.wait(1) end
            end
        end
        task.wait(5)
    end
end)

-- ── GUI ───────────────────────────────────────────────────
local C = {
    bg = Color3.fromRGB(15, 18, 26),
    panel = Color3.fromRGB(24, 29, 40),
    row = Color3.fromRGB(32, 39, 54),
    acc = Color3.fromRGB(0, 229, 255),
    ok = Color3.fromRGB(34, 197, 94),
    bad = Color3.fromRGB(239, 68, 68),
    txt = Color3.fromRGB(232, 238, 247),
    dim = Color3.fromRGB(139, 148, 167),
    border = Color3.fromRGB(46, 58, 82),
}

local screen = Instance.new("ScreenGui")
screen.Name = "BoomboxGui"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = LP:WaitForChild("PlayerGui")

local function corner(r)
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r); return c
end
local function stroke()
    local s = Instance.new("UIStroke"); s.Color = C.border; s.Thickness = 1; return s
end
local function makeBtn(name, col)
    local b = Instance.new("TextButton")
    b.Name = name
    b.BackgroundColor3 = col
    b.Text = name
    b.TextColor3 = Color3.fromRGB(8, 19, 26)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 14
    b.AutoButtonColor = true
    b.Parent = nil
    return b
end

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(350, 520)
main.Position = UDim2.fromScale(0.5, 0.5)
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.BackgroundColor3 = C.bg
main.ClipsDescendants = true
corner(14).Parent = main
stroke().Parent = main
main.Parent = screen

local titlebar = Instance.new("Frame")
titlebar.Size = UDim2.new(1, 0, 0, 44)
titlebar.BackgroundColor3 = C.panel
titlebar.Parent = main
corner(14).Parent = titlebar

local titlebarUnder = Instance.new("Frame")
titlebarUnder.Size = UDim2.new(1, 0, 0, 14)
titlebarUnder.Position = UDim2.new(0, 0, 0, 30)
titlebarUnder.BackgroundColor3 = C.panel
titlebarUnder.ZIndex = -1
titlebarUnder.Parent = main

local logo = Instance.new("TextLabel")
logo.Size = UDim2.new(1, -60, 0, 44)
logo.BackgroundTransparency = 1
logo.Text = "🎧  BOOMBOX"
logo.Font = Enum.Font.GothamBold
logo.TextSize = 18
logo.TextColor3 = C.txt
logo.TextXAlignment = Enum.TextXAlignment.Left
logo.Parent = titlebar

statusDot = Instance.new("Frame")
statusDot.Size = UDim2.fromOffset(10, 10)
statusDot.Position = UDim2.new(1, -92, 0, 10)
statusDot.AnchorPoint = Vector2.new(1, 0)
statusDot.BackgroundColor3 = C.bad
corner(5).Parent = statusDot
statusDot.Parent = titlebar

statusText = Instance.new("TextLabel")
statusText.Size = UDim2.fromOffset(60, 20)
statusText.Position = UDim2.new(1, -72, 0, 12)
statusText.AnchorPoint = Vector2.new(1, 0)
statusText.BackgroundTransparency = 1
statusText.Text = "OFFLINE"
statusText.Font = Enum.Font.GothamBold
statusText.TextSize = 11
statusText.TextColor3 = C.dim
statusText.TextXAlignment = Enum.TextXAlignment.Right
statusText.Parent = titlebar

-- draggable
local dragConn1, dragConn2
titlebar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        local startPos = main.Position
        local startInput = input.Position
        dragConn1 = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                if dragConn1 then dragConn1:Disconnect() end
                if dragConn2 then dragConn2:Disconnect() end
            end
        end)
        dragConn2 = UIS.InputChanged:Connect(function(ci)
            if (ci == input) and (ci.UserInputType == Enum.UserInputType.MouseMovement or ci.UserInputType == Enum.UserInputType.Touch) then
                local delta = ci.Position - startInput
                main.Position = UDim2.fromScale(
                    math.clamp(startPos.X.Scale + delta.X / screen.AbsoluteSize.X, 0, 1),
                    math.clamp(startPos.Y.Scale + delta.Y / screen.AbsoluteSize.Y, 0, 1)
                )
            end
        end)
    end
end)

local body = Instance.new("Frame")
body.Position = UDim2.new(0, 0, 0, 44)
body.Size = UDim2.new(1, 0, 1, -44)
body.BackgroundTransparency = 1
body.Parent = main

local pad = Instance.new("UIPadding")
pad.PaddingTop = UDim.new(0, 12)
pad.PaddingBottom = UDim.new(0, 12)
pad.PaddingLeft = UDim.new(0, 12)
pad.PaddingRight = UDim.new(0, 12)
pad.Parent = body

local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 8)
layout.Parent = body

-- id input row
local inputRow = Instance.new("Frame")
inputRow.Size = UDim2.new(1, 0, 0, 40)
inputRow.BackgroundTransparency = 1
inputRow.LayoutOrder = 1
inputRow.Parent = body

local idBox = Instance.new("TextBox")
idBox.Size = UDim2.new(1, 0, 1, 0)
idBox.BackgroundColor3 = C.row
idBox.PlaceholderText = "Enter audio ID..."
idBox.Text = ""
idBox.TextColor3 = C.txt
idBox.PlaceholderColor3 = C.dim
idBox.Font = Enum.Font.Gotham
idBox.TextSize = 15
idBox.ClearTextOnFocus = false
corner(8).Parent = idBox
stroke().Parent = idBox
idBox.Parent = inputRow

-- buttons row
local btnRow = Instance.new("Frame")
btnRow.Size = UDim2.new(1, 0, 0, 40)
btnRow.BackgroundTransparency = 1
btnRow.LayoutOrder = 2
btnRow.Parent = body

local btnLayout = Instance.new("UIListLayout")
btnLayout.SortOrder = Enum.SortOrder.LayoutOrder
btnLayout.Padding = UDim.new(0, 6)
btnLayout.FillDirection = Enum.FillDirection.Horizontal
btnLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
btnLayout.VerticalAlignment = Enum.VerticalAlignment.Center
btnLayout.Parent = btnRow

local function addBtn(text, color, w)
    local b = makeBtn(text, color)
    b.Size = UDim2.new(0, w, 0, 34)
    b.LayoutOrder = #btnRow:GetChildren() - 1
    b.Parent = btnRow
    corner(8).Parent = b
    return b
end

local playBtn = addBtn("▶ Play", C.acc, 96)
local saveBtn = addBtn("＋ Save", C.ok, 96)
local stopBtn = addBtn("■ Stop", C.bad, 84)

-- volume
local volRow = Instance.new("Frame")
volRow.Size = UDim2.new(1, 0, 0, 28)
volRow.BackgroundTransparency = 1
volRow.LayoutOrder = 3
volRow.Parent = body

local volLabel = Instance.new("TextLabel")
volLabel.Size = UDim2.fromOffset(34, 28)
volLabel.BackgroundTransparency = 1
volLabel.Text = "Vol"
volLabel.Font = Enum.Font.GothamBold
volLabel.TextSize = 13
volLabel.TextColor3 = C.dim
volLabel.Parent = volRow

local volBar = Instance.new("Frame")
volBar.Position = UDim2.new(0, 40, 0, 10)
volBar.Size = UDim2.new(1, -40, 0, 8)
volBar.BackgroundColor3 = C.row
corner(4).Parent = volBar
volBar.Parent = volRow

local volFill = Instance.new("Frame")
volFill.Size = UDim2.new(1, 0, 1, 0)
volFill.BackgroundColor3 = C.acc
corner(4).Parent = volFill
volFill.Parent = volBar

local pctLabel = Instance.new("TextLabel")
pctLabel.Size = UDim2.fromOffset(40, 28)
pctLabel.Position = UDim2.new(1, -40, 0, 0)
pctLabel.BackgroundTransparency = 1
pctLabel.Text = "100%"
pctLabel.Font = Enum.Font.Gotham
pctLabel.TextSize = 12
pctLabel.TextColor3 = C.dim
pctLabel.TextXAlignment = Enum.TextXAlignment.Right
pctLabel.Parent = volRow

local draggingVol = false
local function setVolFromX(x)
    local ax = volBar.AbsolutePosition.X
    local aw = volBar.AbsoluteSize.X
    if aw <= 0 then return end
    volume = math.clamp((x - ax) / aw, 0, 1)
    volFill.Size = UDim2.new(volume, 0, 1, 0)
    pctLabel.Text = math.floor(volume * 100) .. "%"
    if currentSound then pcall(function() currentSound.Volume = volume end) end
end
volBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        draggingVol = true
        setVolFromX(input.Position.X)
    end
end)
volBar.InputChanged:Connect(function(input)
    if draggingVol and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        setVolFromX(input.Position.X)
    end
end)
volBar.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        draggingVol = false
    end
end)

-- playlist header
local headRow = Instance.new("Frame")
headRow.Size = UDim2.new(1, 0, 0, 22)
headRow.BackgroundTransparency = 1
headRow.LayoutOrder = 4
headRow.Parent = body

local listTitle = Instance.new("TextLabel")
listTitle.Size = UDim2.new(1, 0, 1, 0)
listTitle.BackgroundTransparency = 1
listTitle.Text = "PLAYLIST (0)"
listTitle.Font = Enum.Font.GothamBold
listTitle.TextSize = 13
listTitle.TextColor3 = C.txt
listTitle.TextXAlignment = Enum.TextXAlignment.Left
listTitle.Parent = headRow

local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.fromOffset(48, 22)
clearBtn.Position = UDim2.new(1, -48, 0, 0)
clearBtn.BackgroundColor3 = C.row
clearBtn.Text = "Clear"
clearBtn.Font = Enum.Font.GothamBold
clearBtn.TextSize = 12
clearBtn.TextColor3 = C.bad
corner(6).Parent = clearBtn
clearBtn.Parent = headRow

-- playlist list
local listFrame = Instance.new("ScrollingFrame")
listFrame.Size = UDim2.new(1, 0, 0, 260)
listFrame.LayoutOrder = 5
listFrame.BackgroundColor3 = C.panel
listFrame.ScrollBarThickness = 4
listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
listFrame.ScrollBarImageColor3 = C.acc
corner(10).Parent = listFrame
stroke().Parent = listFrame
listFrame.Parent = body

local listPad = Instance.new("UIPadding")
listPad.PaddingTop = UDim.new(0, 8)
listPad.PaddingBottom = UDim.new(0, 8)
listPad.PaddingLeft = UDim.new(0, 8)
listPad.PaddingRight = UDim.new(0, 8)
listPad.Parent = listFrame

local listLayout = Instance.new("UIListLayout")
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Padding = UDim.new(0, 6)
listLayout.Parent = listFrame

-- toast
toastLabel = Instance.new("TextLabel")
toastLabel.Size = UDim2.new(1, -24, 0, 34)
toastLabel.Position = UDim2.new(0, 12, 1, -46)
toastLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
toastLabel.BackgroundTransparency = 1
toastLabel.TextTransparency = 1
toastLabel.Text = ""
toastLabel.Font = Enum.Font.GothamBold
toastLabel.TextSize = 13
toastLabel.TextColor3 = C.txt
toastLabel.TextWrapped = true
corner(8).Parent = toastLabel
toastLabel.ZIndex = 5
toastLabel.Parent = main

-- ── playlist rendering ────────────────────────────────────
local rows = {}

local function rebuildList()
    for _, r in ipairs(rows) do if r and r.Parent then r:Destroy() end end
    rows = {}
    for i, entry in ipairs(playlist) do
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, 0, 0, 36)
        row.BackgroundColor3 = C.row
        row.LayoutOrder = i
        row.Parent = listFrame
        corner(8).Parent = row

        local nameLbl = Instance.new("TextLabel")
        nameLbl.Size = UDim2.new(1, -70, 0, 18)
        nameLbl.Position = UDim2.new(0, 10, 0, 2)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Text = entry.name or ("Audio " .. entry.id)
        nameLbl.Font = Enum.Font.Gotham
        nameLbl.TextSize = 13
        nameLbl.TextColor3 = C.txt
        nameLbl.TextXAlignment = Enum.TextXAlignment.Left
        nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
        nameLbl.Parent = row

        local idLbl = Instance.new("TextLabel")
        idLbl.Size = UDim2.new(1, -70, 0, 14)
        idLbl.Position = UDim2.new(0, 10, 0, 20)
        idLbl.BackgroundTransparency = 1
        idLbl.Text = tostring(entry.id)
        idLbl.Font = Enum.Font.Gotham
        idLbl.TextSize = 10
        idLbl.TextColor3 = C.dim
        idLbl.TextXAlignment = Enum.TextXAlignment.Left
        idLbl.TextTruncate = Enum.TextTruncate.AtEnd
        idLbl.Parent = row

        local del = Instance.new("TextButton")
        del.Size = UDim2.fromOffset(26, 26)
        del.Position = UDim2.new(1, -32, 0, 5)
        del.BackgroundTransparency = 1
        del.Text = "✕"
        del.Font = Enum.Font.GothamBold
        del.TextSize = 13
        del.TextColor3 = C.bad
        del.Parent = row

        local hit = Instance.new("TextButton")
        hit.Size = UDim2.new(1, 0, 1, 0)
        hit.BackgroundTransparency = 1
        hit.Text = ""
        hit.Parent = row

        hit.Activated:Connect(function() playAudio(entry.id, entry.name) end)
        del.Activated:Connect(function()
            playlist[entry] = nil
            local clean = {}
            for _, e in ipairs(playlist) do if e then clean[#clean + 1] = e end end
            playlist = clean
            savePlaylist()
            rebuildList()
        end)

        rows[#rows + 1] = row
    end
    listTitle.Text = "PLAYLIST (" .. #playlist .. ")"
end

-- ── actions ───────────────────────────────────────────────
playBtn.Activated:Connect(function()
    local id = tostring(idBox.Text):match("(%d+)")
    if not id then return toast("Enter an audio ID first") end
    playAudio(id)
end)

saveBtn.Activated:Connect(function()
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

stopBtn.Activated:Connect(function()
    stopAudio()
    sendMsg({ type = "stop", user = displayName() })
end)

clearBtn.Activated:Connect(function()
    playlist = {}
    savePlaylist()
    rebuildList()
end)

-- ── start ─────────────────────────────────────────────────
loadPlaylist()
rebuildList()
setStatus(false)
toast("Boombox loaded — set WS_URL to connect")

print("[Boombox] loaded. WS_URL = " .. WS_URL)

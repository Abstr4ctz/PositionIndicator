-- PositionIndicator for UnitXP SP3
-- Uses Lua OnUpdate polling with public UnitXP API

local UnitExists = UnitExists
local UnitCanAttack = UnitCanAttack
local UnitIsDead = UnitIsDead
local UnitXP = UnitXP
local pairs = pairs
local tostring = tostring
local strfind = string.find
local strlower = string.lower
local strsub = string.sub
local tonumber = tonumber

local TEXTURE_OUT = "Interface\\AddOns\\PositionIndicator\\textures\\out_of_range"
local TEXTURE_IN = "Interface\\AddOns\\PositionIndicator\\textures\\in_range"
local TEXTURE_BEHIND = "Interface\\AddOns\\PositionIndicator\\textures\\in_range_behind"

local FADE_TIME = 0.15
local DEFAULT_SIZE = 64
local DEFAULT_POLL_INTERVAL = 0.2  -- 200ms

local DEBUG = false

-- Create frame and textures in Lua (no XML needed)
local frame = CreateFrame("Frame", nil, UIParent)
frame:SetFrameStrata("HIGH")
frame:SetMovable(true)
frame:SetWidth(DEFAULT_SIZE)
frame:SetHeight(DEFAULT_SIZE)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
frame:Hide()

local fadeTex = frame:CreateTexture(nil, "BACKGROUND")
fadeTex:SetWidth(DEFAULT_SIZE)
fadeTex:SetHeight(DEFAULT_SIZE)
fadeTex:SetPoint("CENTER", frame, "CENTER", 0, 0)
fadeTex:Hide()

local mainTex = frame:CreateTexture(nil, "ARTWORK")
mainTex:SetWidth(DEFAULT_SIZE)
mainTex:SetHeight(DEFAULT_SIZE)
mainTex:SetPoint("CENTER", frame, "CENTER", 0, 0)

-- State variables
local enabled = true
local locked = false
local inMelee = false
local isBehind = false
local currentState = "hidden"
local isFading = false
local fadeElapsed = 0
local fadeFrom, fadeTo

-- Polling state
local isTracking = false
local pollElapsed = 0
local pollInterval = DEFAULT_POLL_INTERVAL
local hasValidTarget = false

local defaults = { enabled=true, locked=false, size=64, posX=0, posY=-150, pollInterval=0.2 }

-- Debug print
local function D(msg)
    if DEBUG then DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[PosiLua]|r "..tostring(msg)) end
end

-- Get texture path for state
local function GetTexturePath(state)
    if state == "out" then return TEXTURE_OUT
    elseif state == "in" then return TEXTURE_IN
    elseif state == "behind" then return TEXTURE_BEHIND
    end
    return nil
end

local function SetSize()
    local s = PositionIndicatorDB and PositionIndicatorDB.size or DEFAULT_SIZE
    mainTex:SetWidth(s)
    mainTex:SetHeight(s)
    fadeTex:SetWidth(s)
    fadeTex:SetHeight(s)
    frame:SetWidth(s)
    frame:SetHeight(s)
end

-- Transition to new state with crossfade
local function Transition(newState)
    if currentState == newState then return end
    if DEBUG then D("Transition: "..tostring(currentState).." -> "..tostring(newState)) end

    local newTexPath = GetTexturePath(newState)
    local oldTexPath = GetTexturePath(currentState)

    if newState == "hidden" then
        -- Fade out to hidden
        if oldTexPath then
            fadeTex:SetTexture(oldTexPath)
            fadeTex:SetAlpha(1)
            fadeTex:Show()
        end
        mainTex:Hide()
        isFading = true
        fadeElapsed = 0
        fadeFrom = oldTexPath
        fadeTo = nil
    elseif currentState == "hidden" then
        -- Fade in from hidden
        mainTex:SetTexture(newTexPath)
        mainTex:SetAlpha(0)
        mainTex:Show()
        fadeTex:Hide()
        isFading = true
        fadeElapsed = 0
        fadeFrom = nil
        fadeTo = newTexPath
        frame:Show()
    else
        -- Crossfade between visible states
        if oldTexPath then
            fadeTex:SetTexture(oldTexPath)
            fadeTex:SetAlpha(1)
            fadeTex:Show()
        end
        mainTex:SetTexture(newTexPath)
        mainTex:SetAlpha(0)
        mainTex:Show()
        isFading = true
        fadeElapsed = 0
        fadeFrom = oldTexPath
        fadeTo = newTexPath
    end
    currentState = newState
end

local function UpdateFade(elapsed)
    if not isFading then return end
    fadeElapsed = fadeElapsed + elapsed
    local progress = fadeElapsed / FADE_TIME
    if progress >= 1 then
        isFading = false
        if fadeTo then
            mainTex:SetAlpha(1)
            mainTex:Show()
        else
            frame:Hide()
        end
        fadeTex:Hide()
    else
        if fadeTo then mainTex:SetAlpha(progress) end
        if fadeFrom then fadeTex:SetAlpha(1 - progress) end
    end
end

local function UpdateVisualState()
    if not enabled or not hasValidTarget then
        Transition("hidden")
        return
    end

    -- Determine visual state based on flags
    local newState
    if not inMelee then
        newState = "out"
    elseif isBehind then
        newState = "behind"
    else
        newState = "in"
    end

    if DEBUG then D("UpdateVisualState: inMelee="..tostring(inMelee).." isBehind="..tostring(isBehind).." -> "..newState) end
    Transition(newState)
end

-- Forward declaration for StopTracking
local StopTracking

-- Poll position state using public UnitXP API
local function PollPositionState()
    -- Target existence/attackability cached by events, only check death
    if UnitIsDead("target") then
        StopTracking()
        return
    end

    -- Check melee range using public API
    -- Returns 0 when in melee range, positive distance when out, nil on error
    local dist = UnitXP("distanceBetween", "player", "target", "meleeAutoAttack")
    if dist == nil then return end  -- Error from API
    local newInMelee = (dist < 0.01)

    -- Check behind only when in melee
    local newIsBehind = false
    if newInMelee then
        -- API returns boolean: true = behind, false = in front, nil = error
        local behind = UnitXP("behind", "player", "target")
        newIsBehind = (behind == true)
    end

    -- Only update visual if state actually changed
    if newInMelee ~= inMelee or newIsBehind ~= isBehind then
        if DEBUG then D("State change: melee "..tostring(inMelee).."->"..tostring(newInMelee).." behind "..tostring(isBehind).."->"..tostring(newIsBehind)) end
        inMelee = newInMelee
        isBehind = newIsBehind
        UpdateVisualState()
    end
end

-- Start tracking with Lua polling
local function StartTracking()
    if DEBUG then D("StartTracking called") end
    if not enabled then return end
    isTracking = true
    hasValidTarget = true  -- Caller already validated target
    pollElapsed = pollInterval  -- Trigger immediate first poll
    inMelee = false
    isBehind = false
    UpdateVisualState()
end

-- Stop tracking
StopTracking = function()
    if DEBUG then D("StopTracking called") end
    isTracking = false
    hasValidTarget = false
    inMelee = false
    isBehind = false
    Transition("hidden")
end

local function SavePosition()
    local x, y
    -- Get frame center position relative to screen center
    local frameX, frameY = frame:GetCenter()
    local screenX, screenY = UIParent:GetCenter()
    if frameX and screenX then
        x = frameX - screenX
        y = frameY - screenY
    else
        x = 0
        y = -150
    end
    if DEBUG then D("Saving center-relative pos: "..tostring(x)..", "..tostring(y)) end
    PositionIndicatorDB.posX = x
    PositionIndicatorDB.posY = y
end

local function SlashHandler(msg)
    msg = strlower(msg or "")

    if msg == "" then
        enabled = not enabled
        PositionIndicatorDB.enabled = enabled
        DEFAULT_CHAT_FRAME:AddMessage("PositionIndicator "..(enabled and "ON" or "OFF"))
        if enabled and UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target") then
            StartTracking()
        else
            StopTracking()
        end

    elseif msg == "debug" then
        DEBUG = not DEBUG
        DEFAULT_CHAT_FRAME:AddMessage("Debug "..(DEBUG and "ON" or "OFF"))

    elseif msg == "status" then
        DEFAULT_CHAT_FRAME:AddMessage("Lua state: inMelee="..tostring(inMelee).." isBehind="..tostring(isBehind).." state="..tostring(currentState))
        DEFAULT_CHAT_FRAME:AddMessage("Tracking: "..tostring(isTracking).." pollInterval="..tostring(pollInterval).."s")

    elseif msg == "lock" then
        locked = true
        PositionIndicatorDB.locked = true
        frame:EnableMouse(false)
        DEFAULT_CHAT_FRAME:AddMessage("Locked")

    elseif msg == "unlock" then
        locked = false
        PositionIndicatorDB.locked = false
        frame:EnableMouse(true)
        DEFAULT_CHAT_FRAME:AddMessage("Unlocked")

    elseif strfind(msg, "^size ") then
        local s = tonumber(strsub(msg, 6))
        if s then
            if s < 32 then s = 32 end
            if s > 128 then s = 128 end
            PositionIndicatorDB.size = s
            SetSize()
            DEFAULT_CHAT_FRAME:AddMessage("Size: "..s)
        end

    elseif strfind(msg, "^interval ") then
        local n = tonumber(strsub(msg, 10))
        if n then
            if n < 0.05 then n = 0.05 end
            if n > 0.5 then n = 0.5 end
            pollInterval = n
            PositionIndicatorDB.pollInterval = n
            DEFAULT_CHAT_FRAME:AddMessage("Poll interval: "..n.."s ("..(1/n).." Hz)")
        else
            DEFAULT_CHAT_FRAME:AddMessage("Usage: /posi interval N (0.05-0.5 seconds)")
        end

    elseif msg == "reset" then
        PositionIndicatorDB = { enabled=true, locked=false, size=64, posX=0, posY=-150, pollInterval=0.2 }
        enabled = true
        locked = false
        pollInterval = 0.2
        frame:EnableMouse(true)
        SetSize()
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
        DEFAULT_CHAT_FRAME:AddMessage("Reset")

    else
        DEFAULT_CHAT_FRAME:AddMessage("/posi - toggle on/off")
        DEFAULT_CHAT_FRAME:AddMessage("/posi debug - toggle debug output")
        DEFAULT_CHAT_FRAME:AddMessage("/posi status - show current state")
        DEFAULT_CHAT_FRAME:AddMessage("/posi lock/unlock - lock frame position")
        DEFAULT_CHAT_FRAME:AddMessage("/posi size N - set icon size (32-128)")
        DEFAULT_CHAT_FRAME:AddMessage("/posi interval N - set poll interval (0.05-0.5s)")
        DEFAULT_CHAT_FRAME:AddMessage("/posi reset - reset to defaults")
    end
end

-- Event handler
local function OnEvent()
    if event == "VARIABLES_LOADED" then
        if not PositionIndicatorDB then PositionIndicatorDB = {} end
        for k, v in pairs(defaults) do
            if PositionIndicatorDB[k] == nil then PositionIndicatorDB[k] = v end
        end
        enabled = PositionIndicatorDB.enabled
        locked = PositionIndicatorDB.locked
        pollInterval = PositionIndicatorDB.pollInterval or DEFAULT_POLL_INTERVAL
        frame:EnableMouse(not locked)
        SetSize()
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER",
            PositionIndicatorDB.posX or 0, PositionIndicatorDB.posY or -150)
        SLASH_POSI1 = "/posi"
        SlashCmdList["POSI"] = SlashHandler
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00PositionIndicator|r loaded. /posi for help")

    elseif event == "PLAYER_TARGET_CHANGED" then
        if UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target") then
            StartTracking()
        else
            StopTracking()
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if enabled and UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target") then
            StartTracking()
        else
            StopTracking()
        end

    elseif event == "PLAYER_DEAD" then
        StopTracking()

    elseif event == "PLAYER_UNGHOST" then
        if enabled and UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target") then
            StartTracking()
        end
    end
end

-- OnUpdate handler
local function OnUpdate()
    -- Early exit when completely idle (no tracking, no fading)
    if not isTracking and not isFading then return end

    -- Throttled polling (only when tracking)
    if isTracking then
        pollElapsed = pollElapsed + arg1
        if pollElapsed >= pollInterval then
            pollElapsed = 0
            PollPositionState()
        end
    end

    -- Fade animation (only when fading)
    if isFading then
        UpdateFade(arg1)
    end
end

-- Set up frame scripts
frame:SetScript("OnEvent", OnEvent)
frame:SetScript("OnUpdate", OnUpdate)
frame:SetScript("OnDragStart", function()
    if not locked then this:StartMoving() end
end)
frame:SetScript("OnDragStop", function()
    this:StopMovingOrSizing()
    if not locked then
        SavePosition()
    end
end)

-- Register events and enable dragging (replaces OnLoad)
frame:RegisterForDrag("LeftButton")
frame:RegisterEvent("VARIABLES_LOADED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("PLAYER_UNGHOST")

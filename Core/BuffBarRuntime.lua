local VFlow = _G.VFlow
if not VFlow then return end

local BuffBarRuntime = {}
VFlow.BuffBarRuntime = BuffBarRuntime

local frame = CreateFrame("Frame")
local enabled = false
local dirty = true
local burst = 0
local nextUpdate = 0
local handlers = nil

local cachedFrames = {}
local cachedLayoutIndex = {}
local cachedCount = 0

local BURST_TICKS = 5
local BURST_THROTTLE = 0.033
local WATCHDOG_THROTTLE = 0.25

local function cacheVisible(visible)
    wipe(cachedFrames)
    wipe(cachedLayoutIndex)
    cachedCount = #visible
    for i = 1, cachedCount do
        local bar = visible[i]
        cachedFrames[i] = bar
        cachedLayoutIndex[i] = bar.layoutIndex or 0
    end
end

local function hasVisibleChanged(visible)
    if cachedCount ~= #visible then
        return true
    end
    for i = 1, #visible do
        local bar = visible[i]
        if cachedFrames[i] ~= bar then
            return true
        end
        if cachedLayoutIndex[i] ~= (bar.layoutIndex or 0) then
            return true
        end
    end
    return false
end

function BuffBarRuntime.setHandlers(v)
    handlers = v
end

function BuffBarRuntime.markDirty()
    dirty = true
    burst = BURST_TICKS
    nextUpdate = 0
end

function BuffBarRuntime.disable()
    if enabled then
        frame:SetScript("OnUpdate", nil)
        enabled = false
    end
    dirty = true
    burst = 0
    nextUpdate = 0
    cachedCount = 0
    wipe(cachedFrames)
    wipe(cachedLayoutIndex)
end

function BuffBarRuntime.enable()
    if enabled then return end
    enabled = true
    frame:SetScript("OnUpdate", function()
        if not handlers then
            BuffBarRuntime.disable()
            return
        end

        local viewer = handlers.getViewer and handlers.getViewer() or nil
        local cfg = handlers.getConfig and handlers.getConfig() or nil
        if not viewer or not cfg then
            BuffBarRuntime.disable()
            return
        end
        if not viewer:IsShown() then return end
        if viewer._vf_refreshing then return end

        -- 只在动态布局时运行
        if not cfg.dynamicLayout then
            BuffBarRuntime.disable()
            return
        end

        local now = GetTime()
        local throttle = (dirty or burst > 0) and BURST_THROTTLE or WATCHDOG_THROTTLE
        if now < nextUpdate then return end
        nextUpdate = now + throttle

        local visible = handlers.collectVisible and handlers.collectVisible(viewer) or {}
        local changed = dirty or hasVisibleChanged(visible)
        if changed then
            if handlers.refresh then
                handlers.refresh(viewer, cfg)
            end
            cacheVisible(visible)
            dirty = false
            burst = BURST_TICKS
            return
        end

        if burst > 0 then
            burst = burst - 1
        end
    end)
end

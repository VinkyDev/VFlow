local VFlow = _G.VFlow
if not VFlow then return end

local Profiler = VFlow.Profiler

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
local cachedChildCount = 0

-- viewer/cfg 缓存（避免每帧调 getViewer/getConfig）
local cachedViewer = nil
local cachedCfg = nil
local needRefetchRefs = true

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
    needRefetchRefs = true
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
    cachedViewer = nil
    cachedCfg = nil
    needRefetchRefs = true
    wipe(cachedFrames)
    wipe(cachedLayoutIndex)
end

function BuffBarRuntime.enable()
    if enabled then return end
    enabled = true
    needRefetchRefs = true
    frame:SetScript("OnUpdate", function()
        local _pt = Profiler.start("BuffBarRT:OnUpdate")
        if not handlers then
            BuffBarRuntime.disable()
            Profiler.stop(_pt)
            return
        end

        -- 只在 dirty 或首次时重新获取 viewer/cfg 引用
        if needRefetchRefs then
            cachedViewer = handlers.getViewer and handlers.getViewer() or nil
            cachedCfg = handlers.getConfig and handlers.getConfig() or nil
            needRefetchRefs = false
        end

        local viewer = cachedViewer
        local cfg = cachedCfg
        if not viewer or not cfg then
            BuffBarRuntime.disable()
            Profiler.stop(_pt)
            return
        end
        if not viewer:IsShown() then Profiler.stop(_pt) return end
        if viewer._vf_refreshing then Profiler.stop(_pt) return end

        -- 只在动态布局时运行
        if not cfg.dynamicLayout then
            BuffBarRuntime.disable()
            Profiler.stop(_pt)
            return
        end

        local now = GetTime()
        local throttle = (dirty or burst > 0) and BURST_THROTTLE or WATCHDOG_THROTTLE
        if now < nextUpdate then Profiler.stop(_pt) return end
        nextUpdate = now + throttle

        -- 快速路径：watchdog 阶段只检查 children 数量
        if not dirty and burst == 0 then
            local cc = select('#', viewer:GetChildren())
            if cc == cachedChildCount then
                Profiler.stop(_pt)
                return
            end
        end

        local visible = handlers.collectVisible and handlers.collectVisible(viewer, dirty) or {}
        local changed = dirty or hasVisibleChanged(visible)
        if changed then
            if handlers.refresh then
                handlers.refresh(viewer, cfg)
            end
            cacheVisible(visible)
            cachedChildCount = select('#', viewer:GetChildren())
            dirty = false
            burst = BURST_TICKS
            Profiler.stop(_pt)
            return
        end

        if burst > 0 then
            burst = burst - 1
        end
        Profiler.stop(_pt)
    end)
end

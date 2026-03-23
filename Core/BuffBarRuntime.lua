-- =========================================================
-- SECTION 1: 模块入口
-- BuffBarRuntime — BUFF 条 Viewer 运行时监控
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local Profiler = VFlow.Profiler

local BuffBarRuntime = {}
VFlow.BuffBarRuntime = BuffBarRuntime

-- =========================================================
-- SECTION 2: 本地状态与常量
-- =========================================================

local frame = CreateFrame("Frame")
local enabled = false
local dirty = true
local burst = 0
local nextUpdate = 0
local handlers = nil

-- 快照缓存：用于检测可见帧集合是否变化
local cachedFrames = {}
local cachedLayoutIndex = {}
local cachedCount = 0
local cachedShownCount = 0  -- 追踪可见帧数量（Release不改变children数量，但会改变shown数量）

-- viewer/cfg 缓存（避免每帧调 getViewer/getConfig）
local cachedViewer = nil
local cachedCfg = nil
local needRefetchRefs = true

-- 样式版本：配置变更时递增，用于检测是否需要重新应用样式
local styleVersion = 0

local BURST_TICKS = 8
local BURST_THROTTLE = 0.033
local WATCHDOG_THROTTLE = 0.20

-- =========================================================
-- SECTION 3: 可见条快照
-- =========================================================

local function SnapshotVisible(visible)
    wipe(cachedFrames)
    wipe(cachedLayoutIndex)
    cachedCount = #visible
    for i = 1, cachedCount do
        local bar = visible[i]
        cachedFrames[i] = bar
        cachedLayoutIndex[i] = bar.layoutIndex or 0
    end
end

local function HasVisibleChanged(visible)
    local count = #visible
    if cachedCount ~= count then
        return true
    end
    for i = 1, count do
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

-- =========================================================
-- SECTION 4: 公共接口
-- =========================================================

function BuffBarRuntime.setHandlers(v)
    handlers = v
end

function BuffBarRuntime.bumpStyleVersion()
    styleVersion = styleVersion + 1
end

function BuffBarRuntime.getStyleVersion()
    return styleVersion
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
    cachedShownCount = 0
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

        local now = GetTime()
        local throttle = (dirty or burst > 0) and BURST_THROTTLE or WATCHDOG_THROTTLE
        if now < nextUpdate then Profiler.stop(_pt) return end
        nextUpdate = now + throttle

        -- 快速路径：watchdog 阶段检查可见帧数量变化
        -- 注意：不能只检查 children 数量，因为 Release 只是隐藏帧而不移除子级
        if not dirty and burst == 0 then
            local shownCount = 0
            if viewer.itemFramePool then
                for f in viewer.itemFramePool:EnumerateActive() do
                    if f and f.IsShown and f:IsShown() then
                        shownCount = shownCount + 1
                    end
                end
            else
                for _, f in ipairs({ viewer:GetChildren() }) do
                    if f and f.IsShown and f:IsShown() then
                        shownCount = shownCount + 1
                    end
                end
            end
            if shownCount == cachedShownCount then
                Profiler.stop(_pt)
                return
            end
        end

        -- 收集可见帧并检测变化
        local visible = handlers.collectVisible and handlers.collectVisible(viewer, dirty) or {}
        local changed = dirty or HasVisibleChanged(visible)

        if changed then
            if handlers.refresh then
                handlers.refresh(viewer, cfg)
            end
            -- refresh 后重新收集可见帧来更新快照（refresh可能改变了可见状态）
            local refreshedVisible = handlers.collectVisible and handlers.collectVisible(viewer, false) or visible
            SnapshotVisible(refreshedVisible)
            cachedShownCount = #refreshedVisible
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

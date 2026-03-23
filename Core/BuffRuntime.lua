-- =========================================================
-- SECTION 1: 模块入口
-- BuffRuntime — BUFF Viewer 轻量 OnUpdate 调度
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local Profiler = VFlow.Profiler
local StyleLayout = VFlow.StyleLayout

local BuffRuntime = {}
VFlow.BuffRuntime = BuffRuntime

-- =========================================================
-- SECTION 2: 本地状态与常量
-- =========================================================

local frame = CreateFrame("Frame")
local enabled = false
local dirty = true
local burst = 0
local nextUpdate = 0
local handlers = nil

local cachedFrames = {}
local cachedLayoutIndex = {}
local cachedSlot = {}
local cachedCount = 0
local cachedChildCount = 0  -- 快速路径：viewer 子级数量
local cachedPoolCount = 0   -- 快速路径：itemFramePool 活动数（池帧不一定挂在 viewer 子级下）

-- viewer/cfg 缓存（避免每帧调 getViewer/getConfig）
local cachedViewer = nil
local cachedCfg = nil
local needRefetchRefs = true

local BURST_TICKS = 5
local BURST_THROTTLE = 0.033
local WATCHDOG_THROTTLE = 0.30

local function cacheVisible(visible)
    wipe(cachedFrames)
    wipe(cachedLayoutIndex)
    wipe(cachedSlot)
    cachedCount = #visible
    for i = 1, cachedCount do
        local icon = visible[i]
        cachedFrames[i] = icon
        cachedLayoutIndex[i] = icon.layoutIndex or 0
        cachedSlot[i] = icon._vf_slot or 0
    end
end

-- =========================================================
-- SECTION 3: 可见集快照
-- =========================================================

local function hasVisibleChanged(visible)
    if cachedCount ~= #visible then
        return true
    end
    for i = 1, #visible do
        local icon = visible[i]
        if cachedFrames[i] ~= icon then
            return true
        end
        if cachedLayoutIndex[i] ~= (icon.layoutIndex or 0) then
            return true
        end
        if cachedSlot[i] ~= (icon._vf_slot or 0) then
            return true
        end
    end
    return false
end

-- =========================================================
-- SECTION 4: 公共接口
-- =========================================================

function BuffRuntime.setHandlers(v)
    handlers = v
end

function BuffRuntime.markDirty()
    dirty = true
    needRefetchRefs = true
end

function BuffRuntime.disable()
    if not enabled then return end
    enabled = false
    frame:SetScript("OnUpdate", nil)
    cachedViewer = nil
    cachedCfg = nil
    needRefetchRefs = true
end

function BuffRuntime.enable()
    if enabled then return end
    enabled = true
    frame:SetScript("OnUpdate", function()
        if not handlers then
            BuffRuntime.disable()
            return
        end

        -- 只在 dirty 或首次时重新获取 viewer/cfg
        if needRefetchRefs then
            cachedViewer = handlers.getViewer and handlers.getViewer() or nil
            cachedCfg = handlers.getConfig and handlers.getConfig() or nil
            needRefetchRefs = false
        end

        local viewer = cachedViewer
        local cfg = cachedCfg
        if not viewer or not cfg then
            BuffRuntime.disable()
            return
        end

        local now = GetTime()
        if not viewer:IsShown() then
            if now < nextUpdate then return end
            nextUpdate = now + WATCHDOG_THROTTLE
            return
        end
        if viewer._vf_refreshing then
            if now < nextUpdate then return end
            nextUpdate = now + BURST_THROTTLE
            return
        end

        local throttle = (dirty or burst > 0) and BURST_THROTTLE or WATCHDOG_THROTTLE
        if now < nextUpdate then return end
        nextUpdate = now + throttle

        local _pt = Profiler.start("BuffRT:OnUpdate")

        -- 快速路径：watchdog 阶段（非 dirty 且 burst=0）只比对子级数 + 池活动数
        if not dirty and burst == 0 and StyleLayout and StyleLayout.PoolActiveCount then
            local cc = select('#', viewer:GetChildren())
            local pn = StyleLayout.PoolActiveCount(viewer.itemFramePool)
            if cc == cachedChildCount and pn == cachedPoolCount then
                Profiler.stop(_pt)
                return
            end
        end

        local visible = handlers.collectVisible and handlers.collectVisible(viewer, dirty) or {}
        cachedChildCount = select('#', viewer:GetChildren())
        cachedPoolCount = (StyleLayout and StyleLayout.PoolActiveCount)
            and StyleLayout.PoolActiveCount(viewer.itemFramePool) or 0

        local changed = dirty or hasVisibleChanged(visible)
        if changed then
            if handlers.refresh then
                handlers.refresh(viewer, cfg)
            end
            cacheVisible(visible)
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

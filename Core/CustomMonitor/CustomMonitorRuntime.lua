-- =========================================================
-- VFlow CustomMonitorRuntime — 自定义图形监控运行时（主入口）
-- 职责：在容器帧内创建真实的 StatusBar / 环 / 阈值堆栈，并驱动动画
-- 支持：技能冷却 / 充能、BUFF 持续时间、BUFF 堆叠层数
--
-- 生命周期由 CustomMonitorGroups 驱动：
--   onContainerReady(storeKey, spellID, cfg, container)
--   onContainerDestroyed(storeKey, spellID)
-- Runtime 不监听 Store，消除与 Groups 的执行顺序竞争。
--
-- 已按职责拆分为 Runtime/ 子模块：
--   Constants / State / Visibility / Fonts          公共内核
--   CdmRegistry / AuraTracker                       CDM/Aura 追踪
--   Segments / BarFrame                             StatusBar 与帧构造
--   Renderers/{Cooldown,Duration,Stack}             三种渲染模式
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CUSTOM_ENABLED then return end

local Profiler = VFlow.Profiler

local Runtime = VFlow.CustomMonitor and VFlow.CustomMonitor.Runtime
if not Runtime then return end

local Constants = Runtime.Constants
local State = Runtime.State
local Visibility = Runtime.Visibility
local Segments = Runtime.Segments
local CdmRegistry = Runtime.CdmRegistry
local AuraTracker = Runtime.AuraTracker
local BarFrame = Runtime.BarFrame
local Renderers = Runtime.Renderers
local CooldownRenderer = Renderers.Cooldown
local DurationRenderer = Renderers.Duration
local StackRenderer = Renderers.Stack

-- =========================================================
-- SECTION 1: 内联辅助
-- =========================================================

local UPDATE_INTERVAL = Constants.UPDATE_INTERVAL
local SetBarTickState = Segments.setBarTickState
local ShouldRenderGraphics = Segments.shouldRenderGraphics
local CreateSegments = Segments.create
local ClearSegments = Segments.clear
local InnerBarSignature = Segments.innerBarSignature
local SegmentLayoutSignature = Segments.segmentLayoutSignature
local CreateBarFrame = BarFrame.create
local ShouldShowBar = Visibility.shouldShowBar
local IsHiddenForSystemEditOnly = Visibility.isHiddenForSystemEditOnly
local ApplyMonitorContainerVisibility = Visibility.applyContainerVisibility
local ScanCDMViewers = CdmRegistry.scanCDMViewers
local UpdateRegularCooldownBar = CooldownRenderer.updateRegular
local UpdateChargeBar = CooldownRenderer.updateCharge
local UpdateDurationBar = DurationRenderer.update
local UpdateStackBar = StackRenderer.update
local BindBarToCDMFrame = AuraTracker.bindBarToCDMFrame
local UnlinkBarFromAura = AuraTracker.unlinkBar
local ClearAllHooks = AuraTracker.clearAllHooks
local PP = VFlow.PixelPerfect

-- =========================================================
-- SECTION 2: BUFF 派发索引
-- =========================================================

local function RemoveBuffFromDispatchIndex(barFrame)
    if not barFrame then return end
    local spellID = barFrame._spellID
    if not spellID then return end
    State.buffProbeBars[spellID] = nil
    State.buffWatchedBars.player[spellID] = nil
    State.buffWatchedBars.pet[spellID] = nil
    State.buffWatchedBars.target[spellID] = nil
end

local function SyncBuffDispatchIndex(barFrame)
    if not barFrame or barFrame._storeKey ~= "buffs" then return end
    RemoveBuffFromDispatchIndex(barFrame)
    local unit = barFrame._trackedUnit
    if barFrame._lastKnownActive and unit and State.buffWatchedBars[unit] then
        State.buffWatchedBars[unit][barFrame._spellID] = barFrame
    else
        State.buffProbeBars[barFrame._spellID] = barFrame
    end
end

-- =========================================================
-- SECTION 3: 可见性 / 段重建
-- =========================================================

local function ApplyBgColor(barFrame)
    local cfg = barFrame._cfg
    if not ShouldRenderGraphics(cfg) then return end
    local bgc = cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }
    if barFrame._bg then
        if cfg.shape == "ring" then
            barFrame._bg:SetColorTexture(0, 0, 0, 0)
        else
            barFrame._bg:SetColorTexture(bgc.r, bgc.g, bgc.b, bgc.a)
        end
    end
    if barFrame._chargeBG then
        barFrame._chargeBG:SetColorTexture(bgc.r, bgc.g, bgc.b, bgc.a)
    end
    if barFrame._segBGs then
        for _, bg in ipairs(barFrame._segBGs) do
            if cfg.shape == "ring" then
                bg:SetVertexColor(bgc.r, bgc.g, bgc.b, bgc.a)
            else
                bg:SetColorTexture(bgc.r, bgc.g, bgc.b, bgc.a)
            end
        end
    end
end

local function ResolveBarVisibility(barFrame)
    if not barFrame then return false end
    local isBuffActive = (barFrame._storeKey == "buffs") and (barFrame._lastKnownActive or false) or false
    local shouldShow = ShouldShowBar(barFrame._cfg, isBuffActive)
    if shouldShow and IsHiddenForSystemEditOnly(barFrame._cfg) then
        shouldShow = false
    end
    return shouldShow
end

local function RefreshBarSegmentsIfNeeded(barFrame, count, isStack, isRing)
    if not barFrame or not barFrame._segsDirty then return end
    local cw = barFrame._segContainer and barFrame._segContainer:GetWidth()
    if cw and cw > 0 then
        CreateSegments(barFrame, count, barFrame._cfg, isStack, isRing)
    end
end

-- =========================================================
-- SECTION 4: Tick 调度
-- =========================================================

local RefreshSkillBar
local RefreshBuffBar

local function RefreshUpdateFrameState()
    if State.tickBarCount > 0 then
        State.updateFrame:Show()
    else
        State.updateFrame:Hide()
    end
end

local function AddTickBar(barFrame)
    if not barFrame or barFrame._isTicking then return end
    State.tickBars[barFrame] = true
    barFrame._isTicking = true
    State.tickBarCount = State.tickBarCount + 1
    RefreshUpdateFrameState()
end

local function RemoveTickBar(barFrame)
    if not barFrame or not barFrame._isTicking then return end
    State.tickBars[barFrame] = nil
    barFrame._isTicking = false
    if State.tickBarCount > 0 then
        State.tickBarCount = State.tickBarCount - 1
    end
    RefreshUpdateFrameState()
end

local function ReconcileBarTicker(barFrame)
    if barFrame and barFrame._isVisible and barFrame._tickMode then
        AddTickBar(barFrame)
    else
        RemoveTickBar(barFrame)
    end
end

local function ApplyBarVisibility(barFrame, shouldShow)
    if not barFrame then return end
    barFrame._isVisible = shouldShow == true
    ApplyMonitorContainerVisibility(barFrame._container, barFrame._isVisible)
    ReconcileBarTicker(barFrame)
end

local function TickBar(barFrame)
    if not barFrame then return end
    local mode = barFrame._tickMode
    if not mode then
        RemoveTickBar(barFrame)
        return
    end

    -- 12.0 下 DurationObject 可能携带 secret value。
    -- tick 阶段不读取/比较剩余时间，只重新走对应条目的安全刷新链路。
    if mode == "buff_duration" then
        RefreshBuffBar(barFrame, "tick")
        return
    end

    RefreshSkillBar(barFrame, "tick")
end

local function UpdateFrameOnUpdate(_, dt)
    State.elapsed = State.elapsed + dt
    if State.elapsed < UPDATE_INTERVAL then return end
    State.elapsed = 0

    local count = 0
    for barFrame in pairs(State.tickBars) do
        count = count + 1
        State.tickScratch[count] = barFrame
    end
    for i = 1, count do
        local barFrame = State.tickScratch[i]
        State.tickScratch[i] = nil
        TickBar(barFrame)
    end
end
State.updateFrame:SetScript("OnUpdate", UpdateFrameOnUpdate)

-- =========================================================
-- SECTION 5: 单条刷新
-- =========================================================

RefreshSkillBar = function(barFrame)
    if not barFrame then return end
    ApplyBgColor(barFrame)
    if barFrame._cfg.isChargeSpell then
        UpdateChargeBar(barFrame, barFrame._spellID)
    else
        RefreshBarSegmentsIfNeeded(barFrame, barFrame._segsNeedCount or 1, false, false)
        UpdateRegularCooldownBar(barFrame, barFrame._spellID)
    end
    ApplyBarVisibility(barFrame, ResolveBarVisibility(barFrame))
end

RefreshBuffBar = function(barFrame)
    if not barFrame then return end
    ApplyBgColor(barFrame)
    local isStack = barFrame._monitorType == "stacks"
    local isRing = (barFrame._cfg.shape == "ring") and not isStack
    RefreshBarSegmentsIfNeeded(barFrame, barFrame._segsNeedCount or 1, isStack, isRing)
    if isStack then
        UpdateStackBar(barFrame, barFrame._spellID, barFrame._barKey)
    else
        UpdateDurationBar(barFrame, barFrame._spellID, barFrame._barKey)
    end
    SyncBuffDispatchIndex(barFrame)
    ApplyBarVisibility(barFrame, ResolveBarVisibility(barFrame))
end

-- AuraTracker 在 Hook 触发时复用上面两个 Refresh
AuraTracker.bindRenderers(RefreshBuffBar, UpdateStackBar, UpdateDurationBar)

local function UpdateSkillBars()
    for _, barFrame in pairs(State.activeSkillBars) do
        RefreshSkillBar(barFrame, "sweep")
    end
end

local function UpdateBuffBars()
    for _, barFrame in pairs(State.activeBuffBars) do
        RefreshBuffBar(barFrame, "sweep")
    end
end

local function UpdateAllBars()
    UpdateSkillBars()
    UpdateBuffBars()
end

local function RefreshBuffBarsForUnit(unit)
    local count = 0
    local watched = State.buffWatchedBars[unit]
    if watched then
        for _, barFrame in pairs(watched) do
            count = count + 1
            State.refreshScratch[count] = barFrame
        end
    end
    for _, barFrame in pairs(State.buffProbeBars) do
        count = count + 1
        State.refreshScratch[count] = barFrame
    end
    for i = 1, count do
        local barFrame = State.refreshScratch[i]
        State.refreshScratch[i] = nil
        RefreshBuffBar(barFrame, "unit_aura")
    end
end

-- =========================================================
-- SECTION 6: 创建 / 销毁
-- =========================================================

local function DestroyBar(storeKey, spellID)
    local tbl = (storeKey == "skills") and State.activeSkillBars or State.activeBuffBars
    local barFrame = tbl[spellID]
    if not barFrame then return end

    RemoveTickBar(barFrame)
    SetBarTickState(barFrame, nil)

    if storeKey == "buffs" then
        local barKey = "buffs/" .. spellID
        BindBarToCDMFrame(barFrame, nil, barKey)
        UnlinkBarFromAura(barKey)
        RemoveBuffFromDispatchIndex(barFrame)
    end

    local container = barFrame:GetParent()
    if container and container._bar then container._bar:Show() end

    ClearSegments(barFrame)

    if barFrame._chargeBG then
        barFrame._chargeBG:Hide()
        barFrame._chargeBG = nil
    end
    if barFrame._chargeBar then
        barFrame._chargeBar:Hide()
        barFrame._chargeBar:SetParent(nil)
        barFrame._chargeBar = nil
    end
    if barFrame._refreshCharge then
        barFrame._refreshCharge:Hide()
        barFrame._refreshCharge:SetParent(nil)
        barFrame._refreshCharge = nil
        barFrame._refreshChargeText = nil
    end
    barFrame._lastChargeWasFull = false
    if barFrame._chargeBorders then
        for _, borderFrame in ipairs(barFrame._chargeBorders) do
            PP.HideBorder(borderFrame)
            borderFrame:Hide()
            borderFrame:SetParent(nil)
        end
        barFrame._chargeBorders = nil
    end

    barFrame:Hide()
    barFrame:SetParent(nil)
    if barFrame._iconFrame then
        barFrame._iconFrame:Hide()
        barFrame._iconFrame:SetParent(nil)
    end
    tbl[spellID] = nil
end

local function EnsureBar(storeKey, spellID, cfg, container)
    if storeKey == "buffs" then
        cfg.isChargeSpell = false
    end
    local tbl = (storeKey == "skills") and State.activeSkillBars or State.activeBuffBars
    if tbl[spellID] then DestroyBar(storeKey, spellID) end

    local barFrame = CreateBarFrame(spellID, cfg, container)
    barFrame._container = container
    barFrame._storeKey = storeKey
    barFrame._innerSig = InnerBarSignature(cfg)
    barFrame._isVisible = true
    if storeKey == "buffs" then
        local monitorType = cfg.monitorType or "duration"
        barFrame._monitorType = monitorType
        barFrame._barKey = "buffs/" .. spellID
        State.buffProbeBars[spellID] = barFrame
    end
    tbl[spellID] = barFrame

    barFrame._segsDirty = true
    barFrame._segsNeedCount = 1
    barFrame:Show()
    return barFrame
end

-- =========================================================
-- SECTION 7: 全局可见性切换
-- =========================================================

local function RefreshVisibilitySensitiveBars()
    UpdateAllBars()
end

VFlow.State.watch("systemEditMode", "CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)
VFlow.State.watch("internalEditMode", "CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)
VFlow.State.watch("inCombat", "CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)
VFlow.State.watch("isMounted", "CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)
VFlow.State.watch("isSkyriding", "CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)
VFlow.State.watch("inVehicle", "CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)
VFlow.State.watch("inPetBattle", "CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)
VFlow.State.watch("hasTarget", "CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)

-- =========================================================
-- SECTION 8: 事件响应
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "CustomMonitorRuntime", function()
    C_Timer.After(1.6, function()
        if not next(State.activeSkillBars) and not next(State.activeBuffBars) then
            return
        end
        for _, barFrame in pairs(State.activeSkillBars) do
            barFrame._needsChargeRefresh = true
        end
        ClearAllHooks()
        ScanCDMViewers()
        UpdateAllBars()
    end)
end)

local function HandleSpecOrTalentChange()
    ClearAllHooks()
    ScanCDMViewers()
    for _, barFrame in pairs(State.activeSkillBars) do
        barFrame._needsChargeRefresh = true
        barFrame._cachedMaxCharges = 0
    end
    for _, barFrame in pairs(State.activeBuffBars) do
        barFrame._trackedAuraInstanceID = nil
        barFrame._trackedUnit = nil
        barFrame._lastKnownActive = false
        barFrame._lastKnownStacks = 0
        SyncBuffDispatchIndex(barFrame)
    end
    UpdateAllBars()
end

VFlow.on("PLAYER_SPECIALIZATION_CHANGED", "CustomMonitorRuntime", HandleSpecOrTalentChange)
VFlow.on("TRAIT_CONFIG_UPDATED", "CustomMonitorRuntime", HandleSpecOrTalentChange)

VFlow.on("PLAYER_REGEN_ENABLED", "CustomMonitorRuntime", function()
    ClearAllHooks()
    ScanCDMViewers()
    for _, barFrame in pairs(State.activeSkillBars) do
        barFrame._needsChargeRefresh = true
    end
    for _, barFrame in pairs(State.activeBuffBars) do
        SyncBuffDispatchIndex(barFrame)
    end
    UpdateAllBars()
end)

VFlow.on("SPELL_UPDATE_COOLDOWN", "CustomMonitorRuntime", function()
    for _, barFrame in pairs(State.activeSkillBars) do
        if not barFrame._cfg.isChargeSpell then
            RefreshSkillBar(barFrame, "spell_cd_event")
        end
    end
end)

VFlow.on("SPELL_UPDATE_CHARGES", "CustomMonitorRuntime", function()
    for _, barFrame in pairs(State.activeSkillBars) do
        if barFrame._cfg.isChargeSpell then
            barFrame._needsChargeRefresh = true
            RefreshSkillBar(barFrame, "spell_charge_event")
        end
    end
end)

VFlow.on("UNIT_AURA", "CustomMonitorRuntime", function(_, unit)
    if unit ~= "player" and unit ~= "pet" and unit ~= "target" then
        return
    end
    RefreshBuffBarsForUnit(unit)
end, "player,pet,target")

-- =========================================================
-- SECTION 9: Profiler 注册
-- =========================================================

if Profiler and Profiler.registerCount then
    Profiler.registerCount("CMR:ShouldShowBar", function()
        return ShouldShowBar
    end, function(fn)
        ShouldShowBar = fn
    end)
end

if Profiler and Profiler.registerScope then
    Profiler.registerScope("CMR:ScanCDMViewers", function()
        return ScanCDMViewers
    end, function(fn)
        ScanCDMViewers = fn
    end)
    Profiler.registerScope("CMR:CreateSegments", function()
        return CreateSegments
    end, function(fn)
        CreateSegments = fn
    end)
    Profiler.registerScope("CMR:UpdateSkillBars", function()
        return UpdateSkillBars
    end, function(fn)
        UpdateSkillBars = fn
    end)
    Profiler.registerScope("CMR:UpdateBuffBars", function()
        return UpdateBuffBars
    end, function(fn)
        UpdateBuffBars = fn
    end)
    Profiler.registerScope("CMR:UpdateAllBars", function()
        return UpdateAllBars
    end, function(fn)
        UpdateAllBars = fn
    end)
    Profiler.registerScope("CMR:UpdateAllBars_OnUpdate", function()
        return UpdateFrameOnUpdate
    end, function(fn)
        UpdateFrameOnUpdate = fn
        State.updateFrame:SetScript("OnUpdate", fn)
    end)
end

-- =========================================================
-- SECTION 10: 公共接口（由 CustomMonitorGroups 调用）
-- =========================================================

--- 配置变化时按「内线框 / 分段」签名增量更新，无需 Store 键正则维护。
local function SyncBarConfig(storeKey, spellID, cfg)
    if not cfg then return end
    local tbl = (storeKey == "skills") and State.activeSkillBars or State.activeBuffBars
    local barFrame = tbl[spellID]
    if not barFrame then return end

    if storeKey == "buffs" then
        cfg.isChargeSpell = false
    end

    local newInner = InnerBarSignature(cfg)
    if newInner ~= barFrame._innerSig then
        barFrame = EnsureBar(storeKey, spellID, cfg, barFrame._container)
        if not barFrame then return end
        if storeKey == "buffs" then
            RefreshBuffBar(barFrame, "config_rebuild")
        else
            RefreshSkillBar(barFrame, "config_rebuild")
        end
        return
    end

    barFrame._cfg = cfg

    if storeKey == "buffs" then
        local monitorType = cfg.monitorType or "duration"
        if barFrame._monitorType ~= monitorType then
            barFrame._monitorType = monitorType
            barFrame._segsDirty = true
        end
    elseif cfg.isChargeSpell then
        barFrame._needsChargeRefresh = true
    end

    local newSeg = SegmentLayoutSignature(cfg, barFrame)
    if newSeg ~= (barFrame._segSig or "") then
        barFrame._segsDirty = true
        if barFrame._segsNeedCount == nil then
            barFrame._segsNeedCount = 1
        end
    end

    if storeKey == "buffs" then
        RefreshBuffBar(barFrame, "config")
    else
        RefreshSkillBar(barFrame, "config")
    end
end

VFlow.CustomMonitorRuntime = {
    onContainerReady = function(storeKey, spellID, cfg, container)
        local barFrame = EnsureBar(storeKey, spellID, cfg, container)
        if storeKey == "buffs" then
            RefreshBuffBar(barFrame, "container_ready")
        else
            RefreshSkillBar(barFrame, "container_ready")
        end
    end,

    onContainerDestroyed = function(storeKey, spellID)
        DestroyBar(storeKey, spellID)
    end,

    --- 容器像素尺寸变化（如同步技能条宽度）：段几何需重建
    notifyContainerGeometryChanged = function(storeKey, spellID)
        local tbl = storeKey == "skills" and State.activeSkillBars or State.activeBuffBars
        local barFrame = spellID and tbl[spellID]
        if not barFrame then return end
        barFrame._segsDirty = true
        barFrame._needsChargeRefresh = true
        if barFrame._segsNeedCount == nil then
            barFrame._segsNeedCount = 1
        end
        if storeKey == "buffs" then
            RefreshBuffBar(barFrame, "geometry")
        else
            RefreshSkillBar(barFrame, "geometry")
        end
    end,

    syncBarConfig = SyncBarConfig,
}

-- =========================================================
-- VFlow CustomMonitor Runtime — AuraTracker
-- 职责：Aura 实例追踪（unit + auraInstanceID）+ CDM 帧 RefreshData/Apply Hook，
--       同帧合并刷新到关联的 BUFF 监控条。
--       stacks/duration 共用底层 Hook，渲染层通过 Lifecycle 回调入口分发。
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CUSTOM_ENABLED then return end

VFlow.CustomMonitor = VFlow.CustomMonitor or {}
VFlow.CustomMonitor.Runtime = VFlow.CustomMonitor.Runtime or {}

local State = VFlow.CustomMonitor.Runtime.State
local CdmRegistry = VFlow.CustomMonitor.Runtime.CdmRegistry

local AuraTracker = {}
VFlow.CustomMonitor.Runtime.AuraTracker = AuraTracker

local HasAuraInstanceID = CdmRegistry.hasAuraInstanceID
local AuraInstanceIDForAPI = CdmRegistry.auraInstanceIDForAPI

-- =========================================================
-- SECTION 1: bar ↔ aura 连接管理
-- =========================================================

local function BuildAuraKey(unit, auraInstanceID)
    if not HasAuraInstanceID(auraInstanceID) then return nil end
    local u = (type(unit) == "string" and unit ~= "") and unit or "player"
    return u .. "#" .. tostring(auraInstanceID)
end

local function UnlinkBarFromAura(barKey)
    local oldAuraKey = State.barToAuraKey[barKey]
    if not oldAuraKey then return end
    local bars = State.auraKeyToBars[oldAuraKey]
    if bars then
        bars[barKey] = nil
        if not next(bars) then State.auraKeyToBars[oldAuraKey] = nil end
    end
    State.barToAuraKey[barKey] = nil
end

local function LinkBarToAura(barFrame, barKey, unit, auraInstanceID)
    auraInstanceID = AuraInstanceIDForAPI(auraInstanceID)
    local auraKey = BuildAuraKey(unit, auraInstanceID)
    if not auraKey then return end
    local oldKey = State.barToAuraKey[barKey]
    if oldKey ~= auraKey then UnlinkBarFromAura(barKey) end
    if not State.auraKeyToBars[auraKey] then State.auraKeyToBars[auraKey] = {} end
    State.auraKeyToBars[auraKey][barKey] = true
    State.barToAuraKey[barKey] = auraKey
    barFrame._trackedAuraInstanceID = auraInstanceID
    barFrame._trackedUnit = unit
end

-- 按优先级在多个单位上查找 aura（展开版，避免闭包分配）
local function GetAuraDataByInstanceID(auraInstanceID, preferredUnit, secondUnit)
    auraInstanceID = AuraInstanceIDForAPI(auraInstanceID)
    if not HasAuraInstanceID(auraInstanceID) then return nil, nil end
    local data
    if preferredUnit and preferredUnit ~= "" then
        data = C_UnitAuras.GetAuraDataByAuraInstanceID(preferredUnit, auraInstanceID)
        if data then return data, preferredUnit end
    end
    if secondUnit and secondUnit ~= "" and secondUnit ~= preferredUnit then
        data = C_UnitAuras.GetAuraDataByAuraInstanceID(secondUnit, auraInstanceID)
        if data then return data, secondUnit end
    end
    if preferredUnit ~= "player" and secondUnit ~= "player" then
        data = C_UnitAuras.GetAuraDataByAuraInstanceID("player", auraInstanceID)
        if data then return data, "player" end
    end
    if preferredUnit ~= "pet" and secondUnit ~= "pet" then
        data = C_UnitAuras.GetAuraDataByAuraInstanceID("pet", auraInstanceID)
        if data then return data, "pet" end
    end
    return nil, nil
end

-- =========================================================
-- SECTION 2: 渲染回调入口（由 Lifecycle 注入实现）
-- =========================================================

-- AuraTracker 不直接调用 UpdateStackBar/UpdateDurationBar/RefreshBuffBar，
-- 而是由 Lifecycle 在装载完成后注册回调，避免模块加载顺序耦合。
local refreshBuffBarFn      -- function(barFrame, reason)
local updateStackBarFn      -- function(barFrame, spellID, barKey)
local updateDurationBarFn   -- function(barFrame, spellID, barKey)

local function DispatchBuffBarRefresh(barFrame, spellID, barKey, reason)
    if refreshBuffBarFn then
        refreshBuffBarFn(barFrame, reason)
        return
    end
    if barFrame._monitorType == "stacks" then
        if updateStackBarFn then updateStackBarFn(barFrame, spellID, barKey) end
    else
        if updateDurationBarFn then updateDurationBarFn(barFrame, spellID, barKey) end
    end
end

-- =========================================================
-- SECTION 3: CDM 同帧合并 Hook
-- =========================================================

-- CDM 清空槽位时立刻同步层数条
local function OnCDMClearAuraInstanceInfo(cdmFrame)
    if not cdmFrame then return end
    local barKeys = State.frameToBarKeys[cdmFrame]
    if not barKeys then return end
    for _, barKey in ipairs(barKeys) do
        local spellID = tonumber(barKey:match("^buffs/(%d+)$"))
        local barFrame = spellID and State.activeBuffBars[spellID]
        if barFrame then
            barFrame._nilCount = 0
            barFrame._lastKnownActive = false
            barFrame._lastKnownStacks = 0
            barFrame._trackedAuraInstanceID = nil
            barFrame._trackedUnit = nil
            UnlinkBarFromAura(barKey)
            DispatchBuffBarRefresh(barFrame, spellID, barKey, "cdm_clear")
        end
    end
end

local function FlushCDMFrameChanges()
    local batchCount = 0
    for frame in pairs(State.cdmFlushPending) do
        batchCount = batchCount + 1
        State.cdmFlushScratch[batchCount] = frame
    end
    for i = 1, batchCount do
        local frame = State.cdmFlushScratch[i]
        State.cdmFlushScratch[i] = nil
        State.cdmFlushPending[frame] = nil
        local slot = State.cdmFlushLastAura[frame]
        State.cdmFlushLastAura[frame] = nil

        local auraInstanceID = slot and slot[1]
        local auraUnit = slot and slot[2]
        if not HasAuraInstanceID(auraInstanceID) and frame.auraInstanceID then
            if HasAuraInstanceID(frame.auraInstanceID) then
                auraInstanceID = frame.auraInstanceID
            end
        end
        if (not auraUnit or auraUnit == "") and frame.auraDataUnit then
            auraUnit = frame.auraDataUnit
        end

        local barKeys = State.frameToBarKeys[frame]
        if barKeys then
            for _, barKey in ipairs(barKeys) do
                local spellID = tonumber(barKey:match("^buffs/(%d+)$"))
                local barFrame = spellID and State.activeBuffBars[spellID]
                if barFrame then
                    if auraInstanceID then
                        local trackedUnit = auraUnit or frame.auraDataUnit
                            or barFrame._trackedUnit or "player"
                        LinkBarToAura(barFrame, barKey, trackedUnit, auraInstanceID)
                    end
                    DispatchBuffBarRefresh(barFrame, spellID, barKey, "cdm_flush")
                end
            end
        end
    end
end

local function DeferCDMFrameChanged(frame, ...)
    if not frame then return end
    local barKeysEarly = State.frameToBarKeys[frame]
    if not barKeysEarly then return end

    local auraInstanceID, auraUnit
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if not auraInstanceID and HasAuraInstanceID(v) then auraInstanceID = v end
        if not auraUnit and type(v) == "string" and v ~= "" then auraUnit = v end
    end

    local slot = State.cdmFlushLastAura[frame]
    if not slot then
        slot = {}
        State.cdmFlushLastAura[frame] = slot
    end
    if HasAuraInstanceID(auraInstanceID) then slot[1] = auraInstanceID end
    if auraUnit and auraUnit ~= "" then slot[2] = auraUnit end

    State.cdmFlushPending[frame] = true
    State.cdmFlushFrame:Show()
end

State.cdmFlushFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    if next(State.cdmFlushPending) then
        FlushCDMFrameChanges()
    end
end)

-- =========================================================
-- SECTION 4: bar ↔ CDM 帧绑定
-- =========================================================

local function RemoveBarKeyFromFrame(cdmFrame, barKey)
    if not cdmFrame or not barKey then return end
    local hookState = State.hookedFrames[cdmFrame]
    if not hookState or not hookState.barIDs or not hookState.barIDs[barKey] then
        return
    end

    hookState.barIDs[barKey] = nil

    local barKeys = State.frameToBarKeys[cdmFrame]
    if barKeys then
        for i = #barKeys, 1, -1 do
            if barKeys[i] == barKey then
                table.remove(barKeys, i)
                break
            end
        end
        if #barKeys == 0 then
            State.frameToBarKeys[cdmFrame] = nil
            State.cdmFlushPending[cdmFrame] = nil
            State.cdmFlushLastAura[cdmFrame] = nil
        end
    end

    if not next(hookState.barIDs) then
        State.hookedFrames[cdmFrame] = nil
    end
end

local function HookCDMFrame(cdmFrame, barKey)
    if not cdmFrame then return end
    if not State.hookedFrames[cdmFrame] then
        State.hookedFrames[cdmFrame] = { barIDs = {} }
        State.frameToBarKeys[cdmFrame] = {}
    end
    if not State.everHookedFrames[cdmFrame] then
        if cdmFrame.RefreshData then
            hooksecurefunc(cdmFrame, "RefreshData", DeferCDMFrameChanged)
        end
        if cdmFrame.RefreshApplications then
            hooksecurefunc(cdmFrame, "RefreshApplications", DeferCDMFrameChanged)
        end
        if cdmFrame.SetAuraInstanceInfo then
            hooksecurefunc(cdmFrame, "SetAuraInstanceInfo", DeferCDMFrameChanged)
        end
        if cdmFrame.ClearAuraInstanceInfo then
            hooksecurefunc(cdmFrame, "ClearAuraInstanceInfo", OnCDMClearAuraInstanceInfo)
        end
        State.everHookedFrames[cdmFrame] = true
    end
    if not State.hookedFrames[cdmFrame].barIDs[barKey] then
        State.hookedFrames[cdmFrame].barIDs[barKey] = true
        table.insert(State.frameToBarKeys[cdmFrame], barKey)
    end
end

local function BindBarToCDMFrame(barFrame, cdmFrame, barKey)
    if not barFrame then return end
    local prevFrame = barFrame._hookedCDMFrame
    if prevFrame and prevFrame ~= cdmFrame then
        RemoveBarKeyFromFrame(prevFrame, barKey)
    end
    if cdmFrame then
        HookCDMFrame(cdmFrame, barKey)
        barFrame._hookedCDMFrame = cdmFrame
    else
        if prevFrame then
            RemoveBarKeyFromFrame(prevFrame, barKey)
        end
        barFrame._hookedCDMFrame = nil
    end
end

local function ClearAllHooks()
    for frame in pairs(State.cdmFlushPending) do
        State.cdmFlushPending[frame] = nil
    end
    for frame in pairs(State.cdmFlushLastAura) do
        State.cdmFlushLastAura[frame] = nil
    end
    State.cdmFlushFrame:Hide()
    for frame in pairs(State.hookedFrames) do
        State.hookedFrames[frame] = nil
        State.frameToBarKeys[frame] = nil
    end
    wipe(State.auraKeyToBars)
    wipe(State.barToAuraKey)
    wipe(State.spellToCooldownID)
    wipe(State.cooldownIDToFrame)
    wipe(State.spellMapRetryAt)
    wipe(State.buffProbeBars)
    wipe(State.buffWatchedBars.player)
    wipe(State.buffWatchedBars.pet)
    wipe(State.buffWatchedBars.target)
    for _, barFrame in pairs(State.activeBuffBars) do
        barFrame._hookedCDMFrame = nil
    end
end

-- =========================================================
-- SECTION 5: 公共接口
-- =========================================================

AuraTracker.buildAuraKey = BuildAuraKey
AuraTracker.linkBar = LinkBarToAura
AuraTracker.unlinkBar = UnlinkBarFromAura
AuraTracker.getAuraDataByInstanceID = GetAuraDataByInstanceID
AuraTracker.bindBarToCDMFrame = BindBarToCDMFrame
AuraTracker.removeBarKeyFromFrame = RemoveBarKeyFromFrame
AuraTracker.flushCDMFrameChanges = FlushCDMFrameChanges
AuraTracker.clearAllHooks = ClearAllHooks

-- 由 Lifecycle 在 Renderer 装载后注入
function AuraTracker.bindRenderers(refreshBuffBar, updateStackBar, updateDurationBar)
    refreshBuffBarFn = refreshBuffBar
    updateStackBarFn = updateStackBar
    updateDurationBarFn = updateDurationBar
end

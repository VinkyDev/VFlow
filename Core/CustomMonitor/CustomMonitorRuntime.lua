-- CustomMonitorRuntime - 调度引擎、CDM 扫描、生命周期、事件响应
-- 由 CustomMonitorGroups 驱动：
--   onContainerReady / onContainerDestroyed / syncBarConfig / notifyContainerGeometryChanged

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.CustomMonitor"
local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CUSTOM_ENABLED then return end

local PP  = VFlow.PixelPerfect
local BFK = VFlow.BarFrameKit
local Bar  = VFlow.CustomMonitorBar
local Ring = VFlow.CustomMonitorRing

local HasAuraInstanceID    = Bar.HasAuraInstanceID
local AuraInstanceIDForAPI = Bar.AuraInstanceIDForAPI
local SetBarTickState      = Bar.SetBarTickState
local ClearSegments        = Bar.ClearSegments
local CreateSegments       = Bar.CreateSegments
local CreateBarFrame       = Bar.CreateBarFrame
local ApplyBgColor         = Bar.ApplyBgColor
local innerBarSignature    = Bar.innerBarSignature
local segmentLayoutSignature = Bar.segmentLayoutSignature
local UpdateRegularCooldownBar = Bar.UpdateRegularCooldownBar
local UpdateChargeBar      = Bar.UpdateChargeBar
local UpdateDurationBar    = Ring.UpdateDurationBar
local UpdateStackBar       = Ring.UpdateStackBar

-- =========================================================
-- SECTION 1: 常量与状态
-- =========================================================

local UPDATE_INTERVAL = 0.1
local MAP_RETRY_INTERVAL = 1.5
local BUFF_VIEWERS = {
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
}

local _activeSkillBars    = {}
local _activeBuffBars     = {}
local _buffProbeBars      = {}
local _buffWatchedBars    = { player = {}, pet = {}, target = {} }
local _tickBars           = {}
local _tickBarCount       = 0

local _spellToCooldownID = {}
local _cooldownIDToFrame = {}

local _hookedFrames    = setmetatable({}, { __mode = "k" })
local _everHookedFrames = setmetatable({}, { __mode = "k" })
local _frameToBarKeys  = setmetatable({}, { __mode = "k" })
local _auraKeyToBars   = {}
local _barToAuraKey    = {}
local _spellMapRetryAt = {}

local _cdmFlushPending  = setmetatable({}, { __mode = "k" })
local _cdmFlushLastAura = setmetatable({}, { __mode = "k" })
local _cdmFlushScratch  = {}
local _cdmFlushFrame = CreateFrame("Frame")
_cdmFlushFrame:Hide()

-- =========================================================
-- SECTION 2: 显示条件
-- =========================================================

local function ShouldShowBar(cfg, isBuffActive)
    local mode = cfg.visibilityMode or "hide"
    local conditionMet = false
    if cfg.hideInCombat and VFlow.State.get("inCombat") then conditionMet = true end
    if cfg.hideOnMount and VFlow.State.get("isMounted") then conditionMet = true end
    if cfg.hideOnSkyriding and VFlow.State.get("isSkyriding") then conditionMet = true end
    if cfg.hideInSpecial and (VFlow.State.get("inVehicle") or VFlow.State.get("inPetBattle")) then conditionMet = true end
    if cfg.hideNoTarget and not VFlow.State.get("hasTarget") then conditionMet = true end
    if cfg.hideWhenInactive and not isBuffActive then conditionMet = true end
    if mode == "show" then return conditionMet end
    return not conditionMet
end

--- 仅暴雪编辑预览阶段隐藏，内部编辑模式仍显示
local function IsHiddenForSystemEditOnly(cfg)
    if not cfg or not cfg.hideInSystemEditMode then return false end
    local sys = VFlow.State.systemEditMode or false
    local internal = VFlow.State.internalEditMode or false
    return sys and not internal
end

-- =========================================================
-- SECTION 3: CDM 帧扫描 & spellID→cooldownID 映射
-- =========================================================

local function GetCooldownIDFromFrame(frame)
    local cdID = frame.cooldownID
    if not cdID and frame.cooldownInfo then cdID = frame.cooldownInfo.cooldownID end
    return cdID
end

local function IsUsableNonSecretSpellId(id)
    if not id or type(id) ~= "number" then return false end
    if issecretvalue and issecretvalue(id) then return false end
    return id > 0
end

local function SafeSpellIdEquals(a, b)
    local ok, eq = pcall(function() return a == b end)
    return ok and eq
end

local function ResolveSpellID(info)
    if not info then return nil end
    local linked = info.linkedSpellIDs and info.linkedSpellIDs[1]
    if IsUsableNonSecretSpellId(linked) then return linked end
    if IsUsableNonSecretSpellId(info.overrideSpellID) then return info.overrideSpellID end
    if IsUsableNonSecretSpellId(info.spellID) then return info.spellID end
    return nil
end

local function RegisterCDMFrame(frame)
    local cdID = GetCooldownIDFromFrame(frame)
    if not cdID then return end
    _cooldownIDToFrame[cdID] = frame
    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
    if not info then return end
    local sid = ResolveSpellID(info)
    if sid and not _spellToCooldownID[sid] then
        _spellToCooldownID[sid] = cdID
    end
    if info.linkedSpellIDs then
        for _, lid in ipairs(info.linkedSpellIDs) do
            if IsUsableNonSecretSpellId(lid) and not _spellToCooldownID[lid] then
                _spellToCooldownID[lid] = cdID
            end
        end
    end
    if IsUsableNonSecretSpellId(info.spellID) and not _spellToCooldownID[info.spellID] then
        _spellToCooldownID[info.spellID] = cdID
    end
end

local function ScanCDMViewers()
    if InCombatLockdown() then return end
    wipe(_spellToCooldownID)
    wipe(_cooldownIDToFrame)
    wipe(_spellMapRetryAt)
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            if viewer.itemFramePool then
                for frame in viewer.itemFramePool:EnumerateActive() do RegisterCDMFrame(frame) end
            else
                for _, child in ipairs({ viewer:GetChildren() }) do RegisterCDMFrame(child) end
            end
        end
    end
end

-- 战斗中为单个 spellID 补建映射
local function TryMapSpellID(spellID)
    local now = GetTime and GetTime() or 0
    local retryAt = _spellMapRetryAt[spellID]
    if retryAt and now < retryAt then return end
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            local function check(frame)
                local cdID = GetCooldownIDFromFrame(frame)
                if not cdID then return false end
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                if not info then return false end
                local sid = ResolveSpellID(info)
                if SafeSpellIdEquals(sid, spellID) or SafeSpellIdEquals(info.spellID, spellID) then
                    RegisterCDMFrame(frame); return true
                end
                if info.linkedSpellIDs then
                    for _, lid in ipairs(info.linkedSpellIDs) do
                        if SafeSpellIdEquals(lid, spellID) then RegisterCDMFrame(frame); return true end
                    end
                end
                return false
            end
            if viewer.itemFramePool then
                for frame in viewer.itemFramePool:EnumerateActive() do
                    if check(frame) then _spellMapRetryAt[spellID] = nil; return end
                end
            else
                for _, child in ipairs({ viewer:GetChildren() }) do
                    if check(child) then _spellMapRetryAt[spellID] = nil; return end
                end
            end
        end
    end
    _spellMapRetryAt[spellID] = now + MAP_RETRY_INTERVAL
end

local function FindCDMFrame(cooldownID)
    if not cooldownID then return nil end
    local cached = _cooldownIDToFrame[cooldownID]
    if cached then return cached end
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            if viewer.itemFramePool then
                for frame in viewer.itemFramePool:EnumerateActive() do
                    local cdID = GetCooldownIDFromFrame(frame)
                    if cdID == cooldownID then _cooldownIDToFrame[cdID] = frame; return frame end
                end
            else
                for _, child in ipairs({ viewer:GetChildren() }) do
                    local cdID = GetCooldownIDFromFrame(child)
                    if cdID == cooldownID then _cooldownIDToFrame[cdID] = child; return child end
                end
            end
        end
    end
    return nil
end

-- =========================================================
-- SECTION 4: Aura 追踪
-- =========================================================

local function BuildAuraKey(unit, auraInstanceID)
    if not HasAuraInstanceID(auraInstanceID) then return nil end
    local u = (type(unit) == "string" and unit ~= "") and unit or "player"
    return u .. "#" .. tostring(auraInstanceID)
end

local function UnlinkBarFromAura(barKey)
    local oldAuraKey = _barToAuraKey[barKey]
    if not oldAuraKey then return end
    local bars = _auraKeyToBars[oldAuraKey]
    if bars then
        bars[barKey] = nil
        if not next(bars) then _auraKeyToBars[oldAuraKey] = nil end
    end
    _barToAuraKey[barKey] = nil
end

local function LinkBarToAura(barFrame, barKey, unit, auraInstanceID)
    auraInstanceID = AuraInstanceIDForAPI(auraInstanceID)
    local auraKey = BuildAuraKey(unit, auraInstanceID)
    if not auraKey then return end
    local oldKey = _barToAuraKey[barKey]
    if oldKey ~= auraKey then UnlinkBarFromAura(barKey) end
    if not _auraKeyToBars[auraKey] then _auraKeyToBars[auraKey] = {} end
    _auraKeyToBars[auraKey][barKey] = true
    _barToAuraKey[barKey] = auraKey
    barFrame._trackedAuraInstanceID = auraInstanceID
    barFrame._trackedUnit           = unit
end

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
-- SECTION 5: CDM Hook 管理
-- =========================================================

-- 前向声明
local RefreshSkillBar
local RefreshBuffBar

local function RemoveBarKeyFromFrame(cdmFrame, barKey)
    if not cdmFrame or not barKey then return end
    local hookState = _hookedFrames[cdmFrame]
    if not hookState or not hookState.barIDs or not hookState.barIDs[barKey] then return end

    hookState.barIDs[barKey] = nil
    local barKeys = _frameToBarKeys[cdmFrame]
    if barKeys then
        for i = #barKeys, 1, -1 do
            if barKeys[i] == barKey then table.remove(barKeys, i); break end
        end
        if #barKeys == 0 then
            _frameToBarKeys[cdmFrame] = nil
            _cdmFlushPending[cdmFrame] = nil
            _cdmFlushLastAura[cdmFrame] = nil
        end
    end
    if not next(hookState.barIDs) then _hookedFrames[cdmFrame] = nil end
end

local function BindBarToCDMFrame(barFrame, cdmFrame, barKey)
    if not barFrame then return end
    local prevFrame = barFrame._hookedCDMFrame
    if prevFrame and prevFrame ~= cdmFrame then
        RemoveBarKeyFromFrame(prevFrame, barKey)
    end
    if cdmFrame then
        -- HookCDMFrame inlined
        if not _hookedFrames[cdmFrame] then
            _hookedFrames[cdmFrame] = { barIDs = {} }
            _frameToBarKeys[cdmFrame] = {}
        end
        if not _everHookedFrames[cdmFrame] then
            local function DeferChanged(frame, ...)
                if not frame then return end
                local barKeysEarly = _frameToBarKeys[frame]
                if not barKeysEarly then return end
                local auraInstID, auraUnit
                for i = 1, select("#", ...) do
                    local v = select(i, ...)
                    if not auraInstID and HasAuraInstanceID(v) then auraInstID = v end
                    if not auraUnit and type(v) == "string" and v ~= "" then auraUnit = v end
                end
                local slot = _cdmFlushLastAura[frame]
                if not slot then slot = {}; _cdmFlushLastAura[frame] = slot end
                if HasAuraInstanceID(auraInstID) then slot[1] = auraInstID end
                if auraUnit and auraUnit ~= "" then slot[2] = auraUnit end
                _cdmFlushPending[frame] = true
                _cdmFlushFrame:Show()
            end
            local function OnClear(fr)
                if not fr then return end
                local bks = _frameToBarKeys[fr]
                if not bks then return end
                for _, bk in ipairs(bks) do
                    local sid = tonumber(bk:match("^buffs/(%d+)$"))
                    local bf = sid and _activeBuffBars[sid]
                    if bf then
                        bf._nilCount = 0
                        bf._lastKnownActive = false
                        bf._lastKnownStacks = 0
                        bf._trackedAuraInstanceID = nil
                        bf._trackedUnit = nil
                        UnlinkBarFromAura(bk)
                        if RefreshBuffBar then
                            RefreshBuffBar(bf)
                        elseif bf._monitorType == "stacks" then
                            UpdateStackBar(bf, sid, bk)
                        else
                            UpdateDurationBar(bf, sid, bk)
                        end
                    end
                end
            end
            if cdmFrame.RefreshData         then hooksecurefunc(cdmFrame, "RefreshData",         DeferChanged) end
            if cdmFrame.RefreshApplications then hooksecurefunc(cdmFrame, "RefreshApplications", DeferChanged) end
            if cdmFrame.SetAuraInstanceInfo then hooksecurefunc(cdmFrame, "SetAuraInstanceInfo",  DeferChanged) end
            if cdmFrame.ClearAuraInstanceInfo then hooksecurefunc(cdmFrame, "ClearAuraInstanceInfo", OnClear) end
            _everHookedFrames[cdmFrame] = true
        end
        if not _hookedFrames[cdmFrame].barIDs[barKey] then
            _hookedFrames[cdmFrame].barIDs[barKey] = true
            table.insert(_frameToBarKeys[cdmFrame], barKey)
        end
        barFrame._hookedCDMFrame = cdmFrame
    else
        if prevFrame then RemoveBarKeyFromFrame(prevFrame, barKey) end
        barFrame._hookedCDMFrame = nil
    end
end

local function FlushCDMFrameChanges()
    local batchCount = 0
    for frame in pairs(_cdmFlushPending) do
        batchCount = batchCount + 1
        _cdmFlushScratch[batchCount] = frame
    end
    for i = 1, batchCount do
        local frame = _cdmFlushScratch[i]
        _cdmFlushScratch[i] = nil
        _cdmFlushPending[frame] = nil
        local slot = _cdmFlushLastAura[frame]
        _cdmFlushLastAura[frame] = nil

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

        local barKeys = _frameToBarKeys[frame]
        if barKeys then
            for _, barKey in ipairs(barKeys) do
                local spellID  = tonumber(barKey:match("^buffs/(%d+)$"))
                local barFrame = spellID and _activeBuffBars[spellID]
                if barFrame then
                    if auraInstanceID then
                        local trackedUnit = auraUnit or frame.auraDataUnit
                            or barFrame._trackedUnit or "player"
                        LinkBarToAura(barFrame, barKey, trackedUnit, auraInstanceID)
                    end
                    if RefreshBuffBar then
                        RefreshBuffBar(barFrame)
                    elseif barFrame._monitorType == "stacks" then
                        UpdateStackBar(barFrame, spellID, barKey)
                    else
                        UpdateDurationBar(barFrame, spellID, barKey)
                    end
                end
            end
        end
    end
end

_cdmFlushFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    if next(_cdmFlushPending) then FlushCDMFrameChanges() end
end)

local function ClearAllHooks()
    for frame in pairs(_cdmFlushPending) do _cdmFlushPending[frame] = nil end
    for frame in pairs(_cdmFlushLastAura) do _cdmFlushLastAura[frame] = nil end
    _cdmFlushFrame:Hide()
    for frame in pairs(_hookedFrames) do
        _hookedFrames[frame] = nil
        _frameToBarKeys[frame] = nil
    end
    wipe(_auraKeyToBars)
    wipe(_barToAuraKey)
    wipe(_spellToCooldownID)
    wipe(_cooldownIDToFrame)
    wipe(_spellMapRetryAt)
    wipe(_buffProbeBars)
    wipe(_buffWatchedBars.player)
    wipe(_buffWatchedBars.pet)
    wipe(_buffWatchedBars.target)
    for _, barFrame in pairs(_activeBuffBars) do
        barFrame._hookedCDMFrame = nil
    end
end

-- =========================================================
-- SECTION 6: Ring LateBind（注入运行时依赖）
-- =========================================================

Ring.LateBind({
    spellToCooldownID   = _spellToCooldownID,
    TryMapSpellID       = TryMapSpellID,
    FindCDMFrame        = FindCDMFrame,
    BindBarToCDMFrame   = BindBarToCDMFrame,
    LinkBarToAura       = LinkBarToAura,
    UnlinkBarFromAura   = UnlinkBarFromAura,
    GetAuraDataByInstanceID = GetAuraDataByInstanceID,
})

-- =========================================================
-- SECTION 7: 生命周期与 Tick 管理
-- =========================================================

local _elapsed = 0
local _tickScratch = {}
local _refreshScratch = {}
local _updateFrame = CreateFrame("Frame")

local function ApplyMonitorContainerVisibility(container, shouldShow)
    if not container then return end
    -- 不 Hide：保持 Shown + Alpha=0，避免因 Hide 跳过更新
    container:Show()
    container:SetAlpha(shouldShow and 1 or 0)
end

local function RefreshUpdateFrameState()
    if _tickBarCount > 0 then _updateFrame:Show() else _updateFrame:Hide() end
end

local function AddTickBar(barFrame)
    if not barFrame or barFrame._isTicking then return end
    _tickBars[barFrame] = true
    barFrame._isTicking = true
    _tickBarCount = _tickBarCount + 1
    RefreshUpdateFrameState()
end

local function RemoveTickBar(barFrame)
    if not barFrame or not barFrame._isTicking then return end
    _tickBars[barFrame] = nil
    barFrame._isTicking = false
    if _tickBarCount > 0 then _tickBarCount = _tickBarCount - 1 end
    RefreshUpdateFrameState()
end

local function ReconcileBarTicker(barFrame)
    if barFrame and barFrame._isVisible and barFrame._tickMode then
        AddTickBar(barFrame)
    else
        RemoveTickBar(barFrame)
    end
end

local function RemoveBuffFromDispatchIndex(barFrame)
    if not barFrame then return end
    local spellID = barFrame._spellID
    if not spellID then return end
    _buffProbeBars[spellID] = nil
    _buffWatchedBars.player[spellID] = nil
    _buffWatchedBars.pet[spellID] = nil
    _buffWatchedBars.target[spellID] = nil
end

local function SyncBuffDispatchIndex(barFrame)
    if not barFrame or barFrame._storeKey ~= "buffs" then return end
    RemoveBuffFromDispatchIndex(barFrame)
    local unit = barFrame._trackedUnit
    if barFrame._lastKnownActive and unit and _buffWatchedBars[unit] then
        _buffWatchedBars[unit][barFrame._spellID] = barFrame
    else
        _buffProbeBars[barFrame._spellID] = barFrame
    end
end

local function ResolveBarVisibility(barFrame)
    if not barFrame then return false end
    local isBuffActive = (barFrame._storeKey == "buffs") and (barFrame._lastKnownActive or false) or false
    local shouldShow = ShouldShowBar(barFrame._cfg, isBuffActive)
    if shouldShow and IsHiddenForSystemEditOnly(barFrame._cfg) then shouldShow = false end
    return shouldShow
end

local function ApplyBarVisibility(barFrame, shouldShow)
    if not barFrame then return end
    barFrame._isVisible = shouldShow == true
    ApplyMonitorContainerVisibility(barFrame._container, barFrame._isVisible)
    ReconcileBarTicker(barFrame)
end

local function RefreshBarSegmentsIfNeeded(barFrame, count, isStack, isRing)
    if not barFrame or not barFrame._segsDirty then return end
    local cw = barFrame._segContainer and barFrame._segContainer:GetWidth()
    if cw and cw > 0 then
        CreateSegments(barFrame, count, barFrame._cfg, isStack, isRing)
    end
end

-- =========================================================
-- SECTION 8: 刷新调度器
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

local function TickBar(barFrame)
    if not barFrame then return end
    local mode = barFrame._tickMode
    if not mode then RemoveTickBar(barFrame); return end
    -- 12.0 DurationObject 可能含 secret，tick 阶段只走安全刷新链路
    if mode == "buff_duration" then
        RefreshBuffBar(barFrame)
    else
        RefreshSkillBar(barFrame)
    end
end

local function UpdateFrameOnUpdate(_, dt)
    _elapsed = _elapsed + dt
    if _elapsed < UPDATE_INTERVAL then return end
    _elapsed = 0
    local count = 0
    for barFrame in pairs(_tickBars) do
        count = count + 1
        _tickScratch[count] = barFrame
    end
    for i = 1, count do
        local barFrame = _tickScratch[i]
        _tickScratch[i] = nil
        TickBar(barFrame)
    end
end
_updateFrame:SetScript("OnUpdate", UpdateFrameOnUpdate)
_updateFrame:Hide()

local function UpdateSkillBars()
    for _, barFrame in pairs(_activeSkillBars) do RefreshSkillBar(barFrame) end
end

local function UpdateBuffBars()
    for _, barFrame in pairs(_activeBuffBars) do RefreshBuffBar(barFrame) end
end

local function UpdateAllBars()
    UpdateSkillBars()
    UpdateBuffBars()
end

local function RefreshBuffBarsForUnit(unit)
    local count = 0
    local watched = _buffWatchedBars[unit]
    if watched then
        for _, barFrame in pairs(watched) do
            count = count + 1
            _refreshScratch[count] = barFrame
        end
    end
    for _, barFrame in pairs(_buffProbeBars) do
        count = count + 1
        _refreshScratch[count] = barFrame
    end
    for i = 1, count do
        local barFrame = _refreshScratch[i]
        _refreshScratch[i] = nil
        RefreshBuffBar(barFrame)
    end
end

-- =========================================================
-- SECTION 9: 创建与销毁
-- =========================================================

local function DestroyBar(storeKey, spellID)
    local tbl = (storeKey == "skills") and _activeSkillBars or _activeBuffBars
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

    if barFrame._chargeBG then barFrame._chargeBG:Hide(); barFrame._chargeBG = nil end
    if barFrame._chargeBar then
        barFrame._chargeBar:Hide(); barFrame._chargeBar:SetParent(nil); barFrame._chargeBar = nil
    end
    if barFrame._refreshCharge then
        barFrame._refreshCharge:Hide(); barFrame._refreshCharge:SetParent(nil)
        barFrame._refreshCharge = nil; barFrame._refreshChargeText = nil
    end
    barFrame._lastChargeWasFull = false
    if barFrame._chargeBorders then
        for _, borderFrame in ipairs(barFrame._chargeBorders) do
            PP.HideBorder(borderFrame); borderFrame:Hide(); borderFrame:SetParent(nil)
        end
        barFrame._chargeBorders = nil
    end

    barFrame:Hide(); barFrame:SetParent(nil)
    if barFrame._iconFrame then barFrame._iconFrame:Hide(); barFrame._iconFrame:SetParent(nil) end
    tbl[spellID] = nil
end

local function EnsureBar(storeKey, spellID, cfg, container)
    if storeKey == "buffs" then cfg.isChargeSpell = false end
    local tbl = (storeKey == "skills") and _activeSkillBars or _activeBuffBars
    if tbl[spellID] then DestroyBar(storeKey, spellID) end

    local barFrame = CreateBarFrame(spellID, cfg, container)
    barFrame._container = container
    barFrame._storeKey = storeKey
    barFrame._innerSig = innerBarSignature(cfg)
    barFrame._isVisible = true
    if storeKey == "buffs" then
        barFrame._monitorType = cfg.monitorType or "duration"
        barFrame._barKey = "buffs/" .. spellID
        _buffProbeBars[spellID] = barFrame
    end
    tbl[spellID] = barFrame

    barFrame._segsDirty = true
    barFrame._segsNeedCount = 1
    barFrame:Show()
    return barFrame
end

-- =========================================================
-- SECTION 10: 事件驱动调度
-- =========================================================

local function RefreshVisibilitySensitiveBars() UpdateAllBars() end

VFlow.State.watch("systemEditMode",  "CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)
VFlow.State.watch("internalEditMode","CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)
VFlow.State.watch("inCombat",        "CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)
VFlow.State.watch("isMounted",       "CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)
VFlow.State.watch("isSkyriding",     "CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)
VFlow.State.watch("inVehicle",       "CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)
VFlow.State.watch("inPetBattle",     "CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)
VFlow.State.watch("hasTarget",       "CustomMonitorRuntime_Vis", RefreshVisibilitySensitiveBars)

-- =========================================================
-- SECTION 11: 事件响应
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "CustomMonitorRuntime", function()
    C_Timer.After(1.6, function()
        if not next(_activeSkillBars) and not next(_activeBuffBars) then return end
        for _, barFrame in pairs(_activeSkillBars) do
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
    for _, barFrame in pairs(_activeSkillBars) do
        barFrame._needsChargeRefresh = true
        barFrame._cachedMaxCharges = 0
    end
    for _, barFrame in pairs(_activeBuffBars) do
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
    for _, barFrame in pairs(_activeSkillBars) do
        barFrame._needsChargeRefresh = true
    end
    for _, barFrame in pairs(_activeBuffBars) do
        SyncBuffDispatchIndex(barFrame)
    end
    UpdateAllBars()
end)

VFlow.on("SPELL_UPDATE_COOLDOWN", "CustomMonitorRuntime", function()
    for _, barFrame in pairs(_activeSkillBars) do
        if not barFrame._cfg.isChargeSpell then RefreshSkillBar(barFrame) end
    end
end)

VFlow.on("SPELL_UPDATE_CHARGES", "CustomMonitorRuntime", function()
    for _, barFrame in pairs(_activeSkillBars) do
        if barFrame._cfg.isChargeSpell then
            barFrame._needsChargeRefresh = true
            RefreshSkillBar(barFrame)
        end
    end
end)

VFlow.on("UNIT_AURA", "CustomMonitorRuntime", function(_, unit)
    if unit ~= "player" and unit ~= "pet" and unit ~= "target" then return end
    RefreshBuffBarsForUnit(unit)
end, "player,pet,target")

-- =========================================================
-- SECTION 12: 公共接口
-- =========================================================

local function SyncBarConfig(storeKey, spellID, cfg)
    if not cfg then return end
    local tbl = (storeKey == "skills") and _activeSkillBars or _activeBuffBars
    local barFrame = tbl[spellID]
    if not barFrame then return end

    if storeKey == "buffs" then cfg.isChargeSpell = false end

    local newInner = innerBarSignature(cfg)
    if newInner ~= barFrame._innerSig then
        barFrame = EnsureBar(storeKey, spellID, cfg, barFrame._container)
        if not barFrame then return end
        if storeKey == "buffs" then RefreshBuffBar(barFrame) else RefreshSkillBar(barFrame) end
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

    local newSeg = segmentLayoutSignature(cfg, barFrame)
    if newSeg ~= (barFrame._segSig or "") then
        barFrame._segsDirty = true
        if barFrame._segsNeedCount == nil then barFrame._segsNeedCount = 1 end
    end

    if storeKey == "buffs" then RefreshBuffBar(barFrame) else RefreshSkillBar(barFrame) end
end

VFlow.CustomMonitorRuntime = {
    onContainerReady = function(storeKey, spellID, cfg, container)
        local barFrame = EnsureBar(storeKey, spellID, cfg, container)
        if storeKey == "buffs" then RefreshBuffBar(barFrame) else RefreshSkillBar(barFrame) end
    end,

    onContainerDestroyed = function(storeKey, spellID)
        DestroyBar(storeKey, spellID)
    end,

    notifyContainerGeometryChanged = function(storeKey, spellID)
        local tbl = storeKey == "skills" and _activeSkillBars or _activeBuffBars
        local barFrame = spellID and tbl[spellID]
        if not barFrame then return end
        barFrame._segsDirty = true
        barFrame._needsChargeRefresh = true
        if barFrame._segsNeedCount == nil then barFrame._segsNeedCount = 1 end
        if storeKey == "buffs" then RefreshBuffBar(barFrame) else RefreshSkillBar(barFrame) end
    end,

    syncBarConfig = SyncBarConfig,
}

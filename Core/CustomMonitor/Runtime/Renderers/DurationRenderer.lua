-- =========================================================
-- VFlow CustomMonitor Runtime — DurationRenderer
-- 职责：BUFF 持续时间更新（条形 / 环形）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CUSTOM_ENABLED then return end

VFlow.CustomMonitor = VFlow.CustomMonitor or {}
VFlow.CustomMonitor.Runtime = VFlow.CustomMonitor.Runtime or {}
VFlow.CustomMonitor.Runtime.Renderers = VFlow.CustomMonitor.Runtime.Renderers or {}

local Constants = VFlow.CustomMonitor.Runtime.Constants
local State = VFlow.CustomMonitor.Runtime.State
local Segments = VFlow.CustomMonitor.Runtime.Segments
local CdmRegistry = VFlow.CustomMonitor.Runtime.CdmRegistry
local AuraTracker = VFlow.CustomMonitor.Runtime.AuraTracker
local BFK = VFlow.BarFrameKit

local DurationRenderer = {}
VFlow.CustomMonitor.Runtime.Renderers.Duration = DurationRenderer

local ShouldRenderGraphics = Segments.shouldRenderGraphics
local ShouldRenderText = Segments.shouldRenderText
local SetRemainingText = Segments.setRemainingText
local FillDirection = Segments.fillDirection
local ApplyTimerDuration = Segments.applyTimerDuration
local SetBarTickState = Segments.setBarTickState
local CreateSegments = Segments.create
local HasAuraInstanceID = CdmRegistry.hasAuraInstanceID
local AuraInstanceIDForAPI = CdmRegistry.auraInstanceIDForAPI
local TryMapSpellID = CdmRegistry.tryMapSpellID
local FindCDMFrame = CdmRegistry.findCDMFrame
local BindBarToCDMFrame = AuraTracker.bindBarToCDMFrame

local function UpdateDurationBar(barFrame, spellID, barKey)
    local cfg = barFrame._cfg
    local showGraphics = ShouldRenderGraphics(cfg)
    local showText = ShouldRenderText(cfg)
    local tickDurObj = nil

    -- 若尚未有映射，尝试补建（找到后不再重复查，barKey 已缓存在 barFrame 上）
    if not State.spellToCooldownID[spellID] then
        TryMapSpellID(spellID)
    end

    local auraActive = false
    local auraInstanceID = nil
    local unit = nil

    -- 路径1：CDM 帧
    local cooldownID = State.spellToCooldownID[spellID]
    local cdmFrame = cooldownID and FindCDMFrame(cooldownID) or nil
    BindBarToCDMFrame(barFrame, cdmFrame, barKey)
    if cdmFrame and HasAuraInstanceID(cdmFrame.auraInstanceID) then
        auraActive = true
        auraInstanceID = AuraInstanceIDForAPI(cdmFrame.auraInstanceID)
        unit = cdmFrame.auraDataUnit or "player"
        barFrame._trackedAuraInstanceID = auraInstanceID
        barFrame._trackedUnit = unit
    end

    -- 路径2：上次记录的 auraInstanceID
    if not auraActive and HasAuraInstanceID(barFrame._trackedAuraInstanceID) then
        local tid = AuraInstanceIDForAPI(barFrame._trackedAuraInstanceID)
        local d
        d = C_UnitAuras.GetAuraDataByAuraInstanceID("player", tid)
        if d then
            unit = "player"
        else
            d = C_UnitAuras.GetAuraDataByAuraInstanceID("pet", tid)
            if d then unit = "pet" end
        end
        if d then
            auraActive = true
            auraInstanceID = tid
            barFrame._trackedAuraInstanceID = tid
            barFrame._trackedUnit = unit
        end
    end

    -- 路径3：按 spellID 直接扫描（首次触发 / CDM 尚未激活时兜底）
    -- 战斗中 spellId 是 secret value，pcall 比较失败时直接退出循环
    if not auraActive then
        for _, scanUnit in ipairs({ "player", "pet" }) do
            local auraData
            if C_UnitAuras.GetPlayerAuraBySpellID and scanUnit == "player" then
                auraData = C_UnitAuras.GetPlayerAuraBySpellID(spellID)
            end
            if not auraData then
                local index = 1
                while true do
                    local data = C_UnitAuras.GetAuraDataByIndex(scanUnit, index)
                    if not data then break end
                    local matched = false
                    local ok = pcall(function() matched = (data.spellId == spellID) end)
                    if not ok then break end -- secret value，战斗中放弃
                    if matched then auraData = data; break end
                    index = index + 1
                end
            end
            if auraData and HasAuraInstanceID(auraData.auraInstanceID) then
                unit = scanUnit
                auraInstanceID = auraData.auraInstanceID
                auraActive = true
                barFrame._trackedAuraInstanceID = auraInstanceID
                barFrame._trackedUnit = unit
                break
            end
        end
    end

    if not showGraphics then
        if auraActive and auraInstanceID and unit then
            barFrame._lastKnownActive = true
            if barFrame._text then
                local durObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
                if showText and durObj then
                    SetRemainingText(barFrame._text, durObj)
                    tickDurObj = durObj
                else
                    barFrame._text:SetText("")
                end
            end
        else
            barFrame._lastKnownActive = false
            barFrame._trackedAuraInstanceID = nil
            barFrame._trackedUnit = nil
            if barFrame._text then
                barFrame._text:SetText("")
            end
        end
        SetBarTickState(barFrame, tickDurObj and "buff_duration" or nil)
        return
    end

    -- 判断是否为环形
    local isRing = (cfg.shape == "ring")

    -- 检测形状变化，强制重建
    local needRebuild = false
    if barFrame._segments and #barFrame._segments == 1 then
        local seg = barFrame._segments[1]
        if isRing and not seg._isRing then
            needRebuild = true -- 从条形切换到环形
        elseif not isRing and seg._isRing then
            needRebuild = true -- 从环形切换到条形
        end
    end

    -- 单段
    if not barFrame._segments or #barFrame._segments ~= 1 or needRebuild then
        CreateSegments(barFrame, 1, cfg, false, isRing)
    end
    local seg = barFrame._segments and barFrame._segments[1]
    if not seg then
        SetBarTickState(barFrame, nil)
        return
    end

    if auraActive and auraInstanceID and unit then
        barFrame._lastKnownActive = true

        if isRing and seg._isRing then
            -- 环形模式：每帧更新，与条形的 SetTimerDuration 行为一致
            local durObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
            if durObj and seg.SetCooldownFromDurationObject then
                pcall(function()
                    seg:SetCooldownFromDurationObject(durObj)
                end)
                local rc = cfg.ringColor or { r = 0.2, g = 0.6, b = 1, a = 1 }
                seg:SetSwipeColor(rc.r, rc.g, rc.b, rc.a)
                seg._needsRefresh = false
            end
            if barFrame._text then
                if showText and durObj then
                    SetRemainingText(barFrame._text, durObj)
                    tickDurObj = durObj
                else
                    barFrame._text:SetText("")
                end
            end
        else
            -- 条形模式：使用 StatusBar
            local timerOK = pcall(function()
                local durObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
                if not durObj then return end
                ApplyTimerDuration(seg, durObj, Constants.INTERP_EASE_OUT, FillDirection(cfg.barFillMode))
                barFrame._lastFillMode = cfg.barFillMode
                if barFrame._text and showText then
                    SetRemainingText(barFrame._text, durObj)
                    tickDurObj = durObj
                elseif barFrame._text then
                    barFrame._text:SetText("")
                end
            end)
            if not timerOK then
                seg:SetMinMaxValues(0, 1); seg:SetValue(1)
                if barFrame._text then barFrame._text:SetText("") end
            end
            if BFK then BFK.SetReverseFill(seg, cfg.barReverse == true) end
        end
    else
        barFrame._lastKnownActive = false
        barFrame._trackedAuraInstanceID = nil
        barFrame._trackedUnit = nil

        if isRing and seg._isRing then
            if seg.Clear then
                seg:Clear()
            end
            seg._needsRefresh = true -- 下次激活时重新设置
        else
            seg:SetMinMaxValues(0, 1); seg:SetValue(0)
            if BFK then BFK.SetReverseFill(seg, cfg.barReverse == true) end
        end
        if barFrame._text then barFrame._text:SetText("") end
    end
    SetBarTickState(barFrame, tickDurObj and "buff_duration" or nil)
end

DurationRenderer.update = UpdateDurationBar

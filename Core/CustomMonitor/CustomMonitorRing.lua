-- CustomMonitorRing - BUFF 持续时间/堆叠层数更新逻辑
-- 包含环形进度渲染与条形 BUFF 渲染
-- 导出 VFlow.CustomMonitorRing 供 Runtime 消费

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CUSTOM_ENABLED then return end

local BFK = VFlow.BarFrameKit
local Bar = VFlow.CustomMonitorBar

local HasAuraInstanceID    = Bar.HasAuraInstanceID
local AuraInstanceIDForAPI = Bar.AuraInstanceIDForAPI
local SetRemainingText     = Bar.SetRemainingText
local FillDirection        = Bar.FillDirection
local ApplyTimerDuration   = Bar.ApplyTimerDuration
local SetBarTickState      = Bar.SetBarTickState
local ShouldRenderGraphics = Bar.ShouldRenderGraphics
local ShouldRenderText     = Bar.ShouldRenderText
local CreateSegments       = Bar.CreateSegments
local SetStackSegmentsValue = Bar.SetStackSegmentsValue
local INTERP_EASE_OUT      = Bar.INTERP_EASE_OUT

-- =========================================================
-- SECTION 1: 延迟绑定（Runtime 加载后注入）
-- =========================================================

local _spellToCooldownID
local TryMapSpellID
local FindCDMFrame
local BindBarToCDMFrame
local LinkBarToAura
local UnlinkBarFromAura
local GetAuraDataByInstanceID

local function LateBind(deps)
    _spellToCooldownID    = deps.spellToCooldownID
    TryMapSpellID         = deps.TryMapSpellID
    FindCDMFrame          = deps.FindCDMFrame
    BindBarToCDMFrame     = deps.BindBarToCDMFrame
    LinkBarToAura         = deps.LinkBarToAura
    UnlinkBarFromAura     = deps.UnlinkBarFromAura
    GetAuraDataByInstanceID = deps.GetAuraDataByInstanceID
end

-- =========================================================
-- SECTION 2: BUFF 持续时间更新
-- =========================================================

local function UpdateDurationBar(barFrame, spellID, barKey)
    local cfg = barFrame._cfg
    local showGraphics = ShouldRenderGraphics(cfg)
    local showText = ShouldRenderText(cfg)
    local tickDurObj, tickText

    if not _spellToCooldownID[spellID] then
        TryMapSpellID(spellID)
    end

    local auraActive     = false
    local auraInstanceID = nil
    local unit           = nil

    -- 路径1：CDM 帧
    local cooldownID = _spellToCooldownID[spellID]
    local cdmFrame = cooldownID and FindCDMFrame(cooldownID) or nil
    BindBarToCDMFrame(barFrame, cdmFrame, barKey)
    if cdmFrame and HasAuraInstanceID(cdmFrame.auraInstanceID) then
        auraActive     = true
        auraInstanceID = AuraInstanceIDForAPI(cdmFrame.auraInstanceID)
        unit           = cdmFrame.auraDataUnit or "player"
        barFrame._trackedAuraInstanceID = auraInstanceID
        barFrame._trackedUnit           = unit
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
            auraActive     = true
            auraInstanceID = tid
            barFrame._trackedAuraInstanceID = tid
            barFrame._trackedUnit = unit
        end
    end

    -- 路径3：按 spellID 直接扫描（兜底）
    -- 战斗中 spellId 是 secret value，pcall 比较失败时退出
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
                    if not ok then break end
                    if matched then auraData = data; break end
                    index = index + 1
                end
            end
            if auraData and HasAuraInstanceID(auraData.auraInstanceID) then
                unit           = scanUnit
                auraInstanceID = auraData.auraInstanceID
                auraActive     = true
                barFrame._trackedAuraInstanceID = auraInstanceID
                barFrame._trackedUnit           = unit
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
                    tickText = barFrame._text
                else
                    barFrame._text:SetText("")
                end
            end
        else
            barFrame._lastKnownActive = false
            barFrame._trackedAuraInstanceID = nil
            barFrame._trackedUnit = nil
            if barFrame._text then barFrame._text:SetText("") end
        end
        SetBarTickState(barFrame, tickDurObj and "buff_duration" or nil)
        return
    end

    local isRing = (cfg.shape == "ring")

    -- 检测形状变化，强制重建
    local needRebuild = false
    if barFrame._segments and #barFrame._segments == 1 then
        local seg = barFrame._segments[1]
        if isRing and not seg._isRing then
            needRebuild = true
        elseif not isRing and seg._isRing then
            needRebuild = true
        end
    end

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
            -- 环形模式
            local durObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
            if durObj and seg.SetCooldownFromDurationObject then
                pcall(function() seg:SetCooldownFromDurationObject(durObj) end)
                local rc = cfg.ringColor or { r = 0.2, g = 0.6, b = 1, a = 1 }
                seg:SetSwipeColor(rc.r, rc.g, rc.b, rc.a)
                seg._needsRefresh = false
            end
            if barFrame._text then
                if showText and durObj then
                    SetRemainingText(barFrame._text, durObj)
                    tickDurObj = durObj
                    tickText = barFrame._text
                else
                    barFrame._text:SetText("")
                end
            end
        else
            -- 条形模式
            local timerOK = pcall(function()
                local durObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
                if not durObj then return end
                ApplyTimerDuration(seg, durObj, INTERP_EASE_OUT, FillDirection(cfg.barFillMode))
                barFrame._lastFillMode = cfg.barFillMode
                if barFrame._text and showText then
                    SetRemainingText(barFrame._text, durObj)
                    tickDurObj = durObj
                    tickText = barFrame._text
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
        barFrame._trackedUnit           = nil

        if isRing and seg._isRing then
            if seg.Clear then seg:Clear() end
            seg._needsRefresh = true
        else
            seg:SetMinMaxValues(0, 1); seg:SetValue(0)
            if BFK then BFK.SetReverseFill(seg, cfg.barReverse == true) end
        end
        if barFrame._text then barFrame._text:SetText("") end
    end
    SetBarTickState(barFrame, tickDurObj and "buff_duration" or nil)
end

-- =========================================================
-- SECTION 3: BUFF 堆叠层数更新
-- =========================================================

local function UpdateStackBar(barFrame, spellID, barKey)
    local cfg       = barFrame._cfg
    local showGraphics = ShouldRenderGraphics(cfg)
    local showText = ShouldRenderText(cfg)
    local maxStacks = tonumber(cfg.maxStacks) or 5
    if maxStacks < 1 then maxStacks = 1 end
    SetBarTickState(barFrame, nil)

    local stacks     = 0
    local auraActive = false

    if not _spellToCooldownID[spellID] then
        TryMapSpellID(spellID)
    end

    local cooldownID = _spellToCooldownID[spellID]
    local cdmFrame = cooldownID and FindCDMFrame(cooldownID) or nil
    BindBarToCDMFrame(barFrame, cdmFrame, barKey)
    if cdmFrame and HasAuraInstanceID(cdmFrame.auraInstanceID) then
        local baseUnit = cdmFrame.auraDataUnit or barFrame._trackedUnit or "player"
        local auraData, trackedUnit = GetAuraDataByInstanceID(
            cdmFrame.auraInstanceID, baseUnit, barFrame._trackedUnit)
        LinkBarToAura(barFrame, barKey, trackedUnit or baseUnit, cdmFrame.auraInstanceID)
        if auraData then
            auraActive = true
            stacks     = auraData.applications or 0
        end
    end

    if not auraActive and HasAuraInstanceID(barFrame._trackedAuraInstanceID) then
        local auraData, trackedUnit = GetAuraDataByInstanceID(
            barFrame._trackedAuraInstanceID, barFrame._trackedUnit, nil)
        if auraData then
            auraActive = true
            stacks     = auraData.applications or 0
            if trackedUnit then
                LinkBarToAura(barFrame, barKey, trackedUnit, barFrame._trackedAuraInstanceID)
            end
        end
    end

    if not auraActive then
        if barFrame._lastKnownActive then
            local cdmInstanceGone = not (cdmFrame and HasAuraInstanceID(cdmFrame.auraInstanceID))
            if cdmInstanceGone then
                barFrame._nilCount = 0
                barFrame._lastKnownActive = false
                barFrame._lastKnownStacks = 0
                barFrame._trackedAuraInstanceID = nil
                barFrame._trackedUnit = nil
                UnlinkBarFromAura(barKey)
                stacks = 0
            else
                barFrame._nilCount = (barFrame._nilCount or 0) + 1
                if barFrame._nilCount > 5 then
                    barFrame._nilCount             = 0
                    barFrame._lastKnownActive       = false
                    barFrame._lastKnownStacks       = 0
                    barFrame._trackedAuraInstanceID = nil
                    barFrame._trackedUnit           = nil
                    UnlinkBarFromAura(barKey)
                    stacks = 0
                else
                    return
                end
            end
        end
    else
        barFrame._nilCount = 0
    end

    if showGraphics and (not barFrame._segments or #barFrame._segments ~= maxStacks) then
        CreateSegments(barFrame, maxStacks, cfg, true)
    end
    if showGraphics and not barFrame._segments then return end

    local isSecret = issecretvalue and issecretvalue(stacks)

    if showGraphics then
        SetStackSegmentsValue(barFrame, stacks)
    end

    if auraActive then
        barFrame._lastKnownActive = true
        if not isSecret and type(stacks) == "number" then
            barFrame._lastKnownStacks = stacks
        end
    end

    if barFrame._text then
        if not showText then
            barFrame._text:SetText("")
            return
        end
        if isSecret then
            barFrame._text:SetText(stacks)
        elseif stacks == 0 then
            barFrame._text:SetText("")
        else
            barFrame._text:SetText(tostring(stacks))
        end
    end
end

-- =========================================================
-- SECTION 4: 导出
-- =========================================================

VFlow.CustomMonitorRing = {
    UpdateDurationBar = UpdateDurationBar,
    UpdateStackBar    = UpdateStackBar,
    LateBind          = LateBind,
}

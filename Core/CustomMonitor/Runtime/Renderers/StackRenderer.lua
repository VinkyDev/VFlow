-- =========================================================
-- VFlow CustomMonitor Runtime — StackRenderer
-- 职责：BUFF 堆叠层数更新（多段 + 阈值覆盖层）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CUSTOM_ENABLED then return end

VFlow.CustomMonitor = VFlow.CustomMonitor or {}
VFlow.CustomMonitor.Runtime = VFlow.CustomMonitor.Runtime or {}
VFlow.CustomMonitor.Runtime.Renderers = VFlow.CustomMonitor.Runtime.Renderers or {}

local State = VFlow.CustomMonitor.Runtime.State
local Segments = VFlow.CustomMonitor.Runtime.Segments
local CdmRegistry = VFlow.CustomMonitor.Runtime.CdmRegistry
local AuraTracker = VFlow.CustomMonitor.Runtime.AuraTracker

local StackRenderer = {}
VFlow.CustomMonitor.Runtime.Renderers.Stack = StackRenderer

local ShouldRenderGraphics = Segments.shouldRenderGraphics
local ShouldRenderText = Segments.shouldRenderText
local SetBarTickState = Segments.setBarTickState
local CreateSegments = Segments.create
local SetStackSegmentsValue = Segments.setStackValue
local HasAuraInstanceID = CdmRegistry.hasAuraInstanceID
local TryMapSpellID = CdmRegistry.tryMapSpellID
local FindCDMFrame = CdmRegistry.findCDMFrame
local BindBarToCDMFrame = AuraTracker.bindBarToCDMFrame
local GetAuraDataByInstanceID = AuraTracker.getAuraDataByInstanceID
local LinkBarToAura = AuraTracker.linkBar
local UnlinkBarFromAura = AuraTracker.unlinkBar

local function UpdateStackBar(barFrame, spellID, barKey)
    local cfg = barFrame._cfg
    local showGraphics = ShouldRenderGraphics(cfg)
    local showText = ShouldRenderText(cfg)
    local maxStacks = tonumber(cfg.maxStacks) or 5
    if maxStacks < 1 then maxStacks = 1 end
    SetBarTickState(barFrame, nil)

    local stacks = 0
    local auraActive = false

    if not State.spellToCooldownID[spellID] then
        TryMapSpellID(spellID)
    end

    local cooldownID = State.spellToCooldownID[spellID]
    local cdmFrame = cooldownID and FindCDMFrame(cooldownID) or nil
    BindBarToCDMFrame(barFrame, cdmFrame, barKey)
    if cdmFrame and HasAuraInstanceID(cdmFrame.auraInstanceID) then
        local baseUnit = cdmFrame.auraDataUnit or barFrame._trackedUnit or "player"
        local auraData, trackedUnit = GetAuraDataByInstanceID(
            cdmFrame.auraInstanceID, baseUnit, barFrame._trackedUnit)
        LinkBarToAura(barFrame, barKey, trackedUnit or baseUnit, cdmFrame.auraInstanceID)
        if auraData then
            auraActive = true
            stacks = auraData.applications or 0
        end
    end

    if not auraActive and HasAuraInstanceID(barFrame._trackedAuraInstanceID) then
        local auraData, trackedUnit = GetAuraDataByInstanceID(
            barFrame._trackedAuraInstanceID, barFrame._trackedUnit, nil)
        if auraData then
            auraActive = true
            stacks = auraData.applications or 0
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
                    barFrame._nilCount = 0
                    barFrame._lastKnownActive = false
                    barFrame._lastKnownStacks = 0
                    barFrame._trackedAuraInstanceID = nil
                    barFrame._trackedUnit = nil
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

StackRenderer.update = UpdateStackBar

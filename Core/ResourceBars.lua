-- =========================================================
-- SECTION 1: 模块入口
-- ResourceBars — 主/次资源条运行时、布局与分段渲染
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.Resources"
local EVENT_OWNER = "Core.ResourceBars.Runtime"
local Utils = VFlow.Utils
local CR = VFlow.ClassResourceMap
local CA = VFlow.ContainerAnchor
local RS = VFlow.ResourceStyles
local Profiler = VFlow.Profiler
local BFK = VFlow.BarFrameKit
local PP = VFlow.PixelPerfect
local E_PT = _G.Enum and Enum.PowerType

local rb = {}

-- =========================================================
-- SECTION 2: 运行时状态与资源解析
-- =========================================================

local lastStaggerPercent = 60
local runtimeEventsRegistered = false

local RESOURCE_BAR_POLL_INTERVAL = 0.2
local resourceBarPollDriver = nil

local function IsSecretValue(v)
    if v == nil or not issecretvalue then
        return false
    end
    return not not issecretvalue(v)
end

local function IsSecretNumber(v)
    return IsSecretValue(v)
end

local function IsPositivePlainNumber(v)
    return not IsSecretNumber(v) and type(v) == "number" and v > 0
end

local function BuildColorSignature(color, defaultR, defaultG, defaultB, defaultA)
    local r = color and color.r
    local g = color and color.g
    local b = color and color.b
    local a = color and color.a
    if r == nil then r = defaultR end
    if g == nil then g = defaultG end
    if b == nil then b = defaultB end
    if a == nil then a = defaultA end
    if IsSecretNumber(r) or IsSecretNumber(g) or IsSecretNumber(b) or IsSecretNumber(a) then
        return nil, r, g, b, a
    end
    return table.concat({
        tostring(r),
        tostring(g),
        tostring(b),
        tostring(a),
    }, "\031"), r, g, b, a
end

local function SetShownIfChanged(region, wantShown)
    if not region then
        return
    end
    if region:IsShown() ~= wantShown then
        region:SetShown(wantShown)
    end
end

local function SetTextIfChanged(fs, text)
    if not fs then
        return
    end
    if IsSecretValue(text) or IsSecretValue(fs._vf_textValue) then
        fs:SetText(text)
        fs._vf_textValue = nil
        return
    end
    if fs._vf_textValue ~= text then
        fs:SetText(text)
        fs._vf_textValue = text
    end
end

local function ApplyStatusBarColorCached(sb, color, defaultR, defaultG, defaultB, defaultA)
    if not sb then
        return
    end
    local colorSig, r, g, b, a = BuildColorSignature(color, defaultR or 1, defaultG or 1, defaultB or 1, defaultA or 1)
    if colorSig and sb._vf_fillColorSig == colorSig then
        return
    end
    sb:SetStatusBarColor(r, g, b, a)
    sb._vf_fillColorSig = colorSig
end

local function ApplyBarProgressCached(sb, minValue, maxValue, value, useSmooth)
    if not sb then
        return
    end
    local canCache = not IsSecretNumber(minValue) and not IsSecretNumber(maxValue) and not IsSecretNumber(value)
    local smoothFlag = useSmooth == true
    if canCache
        and sb._vf_progMin == minValue
        and sb._vf_progMax == maxValue
        and sb._vf_progValue == value
        and sb._vf_progSmooth == smoothFlag then
        return
    end
    if minValue == 0 and BFK and BFK.ApplyBarProgress then
        BFK.ApplyBarProgress(sb, maxValue, value, useSmooth)
    else
        sb:SetMinMaxValues(minValue, maxValue)
        sb:SetValue(value)
    end
    if canCache then
        sb._vf_progMin = minValue
        sb._vf_progMax = maxValue
        sb._vf_progValue = value
        sb._vf_progSmooth = smoothFlag
    else
        sb._vf_progMin = nil
        sb._vf_progMax = nil
        sb._vf_progValue = nil
        sb._vf_progSmooth = nil
    end
end

local function GetDb()
    return VFlow.getDBIfReady(MODULE_KEY)
end

local function CurrentSpecId()
    local specIndex = C_SpecializationInfo.GetSpecialization()
    return C_SpecializationInfo.GetSpecializationInfo(specIndex)
end

local function ResolveRuntimeResourceToken(resourceToken)
    if not resourceToken then
        return nil
    end
    if RS and RS.StyleKeyToRuntimeResource then
        return RS.StyleKeyToRuntimeResource(resourceToken)
    end
    return resourceToken
end

local function FindActiveResourceRow(specID, formID)
    local rows = CR and CR.GetRowsForPlayer and CR.GetRowsForPlayer() or nil
    if not rows then
        return nil
    end
    local fallbackRow
    for _, row in ipairs(rows) do
        if row.specId == specID then
            if row.formId == formID then
                return row
            end
            if row.formId == nil then
                fallbackRow = row
            end
        end
    end
    return fallbackRow
end

local function BuildRuntimeContext(db, forceRebuild)
    local existing = rb._vf_runtimeContext
    if existing and not forceRebuild and rb._vf_runtimeContextDirty ~= true then
        existing.db = db or GetDb()
        return existing
    end
    local specID = CurrentSpecId()
    local row = FindActiveResourceRow(specID, GetShapeshiftFormID())
    local primaryResource = ResolveRuntimeResourceToken(row and row.primary)
    local secondaryResource = ResolveRuntimeResourceToken(row and row.secondary)
    if primaryResource ~= nil and primaryResource == secondaryResource then
        secondaryResource = nil
    end
    rb._vf_runtimeContext = rb._vf_runtimeContext or {}
    local context = rb._vf_runtimeContext
    context.db = db or GetDb()
    context.specID = specID
    context.primaryResource = primaryResource
    context.secondaryResource = secondaryResource
    rb._vf_runtimeContextDirty = false
    return context
end

local function MarkRuntimeContextDirty()
    rb._vf_runtimeContextDirty = true
end

--- DK 符文
local runeCooldownSnapshot = {}
for _runeSnap = 1, 6 do
    runeCooldownSnapshot[_runeSnap] = { start = 0, duration = 0, runeReady = false }
end
local runeCdInfoPool = {}
for _runePool = 1, 6 do
    runeCdInfoPool[_runePool] = { index = 0, remaining = 0, frac = 0 }
end
local runeReadyScratch = {}
local runeCdScratch = {}
local runeOrderScratch = {}
local runeFillScratch = {}

local function GetRuneMaxCurrentAndFillSnapshot()
    if not E_PT then return nil, nil end
    local max = UnitPowerMax("player", E_PT.Runes)
    if not IsPositivePlainNumber(max) then return nil, nil end
    local current = 0
    for i = 1, max do
        local slot = runeCooldownSnapshot[i]
        local start, duration, runeReady = GetRuneCooldown(i)
        slot.start = start
        slot.duration = duration
        slot.runeReady = runeReady
        if runeReady then
            current = current + 1
        end
    end
    return max, current
end

local function GetPrimaryResourceValue(resource)
    if not resource then return nil, nil end
    if E_PT and resource == E_PT.Runes then
        return GetRuneMaxCurrentAndFillSnapshot()
    end
    local max = UnitPowerMax("player", resource)
    local cur = UnitPower("player", resource)
    if not IsSecretNumber(max) and type(max) == "number" and max <= 0 then
        return nil, nil
    end
    return max, cur
end

local function GetSecondaryResourceValue(resource)
    if not resource then return nil, nil end

    if resource == "STAGGER" then
        local stagger = UnitStagger("player") or 0
        local maxHealth = UnitHealthMax("player")
        if IsSecretNumber(stagger) or IsSecretNumber(maxHealth) then
            return maxHealth, stagger
        end
        if type(maxHealth) ~= "number" or maxHealth <= 0 then
            return nil, nil
        end
        lastStaggerPercent = (stagger / maxHealth) * 100
        return maxHealth, stagger
    end

    if resource == "SOUL_FRAGMENTS_VENGEANCE" then
        local current = 0
        if C_Spell and C_Spell.GetSpellCastCount then
            current = C_Spell.GetSpellCastCount(228477) or 0
        end
        return 6, current
    end

    if resource == "SOUL_FRAGMENTS" or resource == "DEVOURER_SOUL" then
        local auraData = C_UnitAuras.GetPlayerAuraBySpellID(1225789) or C_UnitAuras.GetPlayerAuraBySpellID(1227702)
        local current = auraData and auraData.applications or 0
        local max = (C_SpellBook and C_SpellBook.IsSpellKnown(1247534)) and 35 or 50
        return max, current
    end

    if E_PT and resource == E_PT.Runes then
        return GetRuneMaxCurrentAndFillSnapshot()
    end

    if resource == Enum.PowerType.SoulShards then
        local spec = C_SpecializationInfo.GetSpecialization()
        local specID = C_SpecializationInfo.GetSpecializationInfo(spec)
        -- 毁灭：UnitPower(..., true) 为整碎片*10 + 小数格，条与离散段需拆成浮点当前值。
        if specID == 267 then
            local raw = UnitPower("player", resource, true)
            if IsSecretNumber(raw) then
                local cur0 = UnitPower("player", resource, false)
                local max0 = UnitPowerMax("player", resource, false)
                if not IsPositivePlainNumber(max0) then return nil, nil end
                return max0, cur0
            end
            local r = tonumber(raw) or 0
            local curShards = math.floor(r / 10) + (r % 10) / 10
            local maxP = UnitPowerMax("player", resource, false) or 5
            if not IsPositivePlainNumber(maxP) then return nil, nil end
            return maxP, curShards
        end
        local cur = UnitPower("player", resource, false)
        local max = UnitPowerMax("player", resource, false)
        if not IsPositivePlainNumber(max) then return nil, nil end
        return max, cur
    end

    if resource == "MAELSTROM_WEAPON" then
        local auraData = C_UnitAuras.GetPlayerAuraBySpellID(344179)
        local current = auraData and auraData.applications or 0
        return 10, current
    end

    if resource == "TIP_OF_THE_SPEAR" then
        local auraData = C_UnitAuras.GetPlayerAuraBySpellID(260286)
        local current = auraData and auraData.applications or 0
        return 3, current
    end

    if resource == "ICICLES" then
        local auraData = C_UnitAuras.GetPlayerAuraBySpellID(205473)
        local current = auraData and auraData.applications or 0
        return 5, current
    end

    local cur = UnitPower("player", resource)
    local max = UnitPowerMax("player", resource)
    if not IsPositivePlainNumber(max) then return nil, nil end
    return max, cur
end

-- =========================================================
-- SECTION 3: 帧引用与外观工具
-- =========================================================

local primaryHost, secondaryHost
local primarySB, secondarySB
local primaryText, secondaryText
local initialized = false

local function OutlineToken(outline)
    if outline == "THICKOUTLINE" then
        return "THICKOUTLINE"
    end
    if outline == "OUTLINE" then
        return "OUTLINE"
    end
    return ""
end

local function ApplyTextFont(fs, tf)
    if not fs or not tf then return end
    local sz = tonumber(tf.size) or 12
    local fontSig = table.concat({
        tostring(tf.font),
        tostring(sz),
        tostring(tf.outline or ""),
    }, "\031")
    if fs._vf_fontSig ~= fontSig then
        local applyFont = VFlow.UI and VFlow.UI.applyFont
        if applyFont then
            applyFont(fs, tf.font, sz, OutlineToken(tf.outline))
        end
        fs._vf_fontSig = fontSig
    end
    local colorSig, r, g, b, a = BuildColorSignature(tf.color, 1, 1, 1, 1)
    if not colorSig or fs._vf_colorSig ~= colorSig then
        fs:SetTextColor(r, g, b, a)
        fs._vf_colorSig = colorSig
    end
    local position = tf.position or "CENTER"
    if position == "TOP" then
        position = "BOTTOM"
    elseif position == "TOPLEFT" then
        position = "BOTTOMLEFT"
    elseif position == "TOPRIGHT" then
        position = "BOTTOMRIGHT"
    elseif position == "BOTTOM" then
        position = "TOP"
    elseif position == "BOTTOMLEFT" then
        position = "TOPLEFT"
    elseif position == "BOTTOMRIGHT" then
        position = "TOPRIGHT"
    end
    local pointSig = table.concat({
        tostring(position),
        tostring(tf.offsetX or 0),
        tostring(tf.offsetY or 0),
    }, "\031")
    if fs._vf_pointSig ~= pointSig then
        fs:ClearAllPoints()
        fs:SetPoint(position, fs:GetParent(), position, tf.offsetX or 0, tf.offsetY or 0)
        fs._vf_pointSig = pointSig
    end
end

local function ResolveBarTierFillColor(resource, style, cur, max)
    return RS.TryResolveBarFillFromPowerPercent(resource, style) or RS.ResolveBarFillColor(style, cur, max, resource)
end

--- PowerType 阈值色可走 UnitPowerPercent；其余资源走 cur/max。
local function ApplyMainBarFillColor(sb, resource, style, cur, max)
    if not sb then
        return
    end
    local c = style and ResolveBarTierFillColor(resource, style, cur, max) or nil
    if not c then
        local fallback = RS and RS.ResolveStyle(nil, resource) or nil
        c = fallback and fallback.barColor or nil
    end
    if not c then
        return
    end
    local colorSig, r, g, b, a = BuildColorSignature(c, 1, 1, 1, 1)
    if colorSig and sb._vf_fillColorSig == colorSig then
        return
    end
    local tex = sb.GetStatusBarTexture and sb:GetStatusBarTexture()
    if tex then
        tex:SetVertexColor(r, g, b, a)
        sb._vf_fillColorSig = colorSig
        return
    end
    ApplyStatusBarColorCached(sb, c, 1, 1, 1, 1)
end

--- 精华：层数变化时重置下一格充能起点；未满且无起点时补上。
local function SyncEssenceRechargeClock(host, cur, max)
    if not host or IsSecretNumber(cur) or IsSecretNumber(max) then
        return
    end
    local c = math.floor(tonumber(cur) or 0)
    local m = math.floor(tonumber(max) or 0)
    if m <= 0 then
        return
    end
    local prev = host._vf_essencePrevCur
    if prev ~= c then
        host._vf_essencePrevCur = c
        if c < m then
            host._vf_essenceRechargeStart = GetTime()
        else
            host._vf_essenceRechargeStart = nil
        end
    end
    if c < m and not host._vf_essenceRechargeStart then
        host._vf_essenceRechargeStart = GetTime()
    end
    if c >= m then
        host._vf_essenceRechargeStart = nil
    end
end

--- gameSlot：该段在单位能量中的序号（1..max）。
local function GetEssencePipFill(host, gameSlot, curInt, maxInt)
    if gameSlot <= curInt then
        return 1
    end
    if gameSlot == curInt + 1 and curInt < maxInt then
        local rate = GetPowerRegenForPowerType(Enum.PowerType.Essence)
        if type(rate) == "number" and not IsSecretNumber(rate) and rate > 0 then
            host._vf_essenceLastRate = rate
        else
            rate = host._vf_essenceLastRate or 0.2
        end
        local rechargeTime = 1 / rate
        local now = GetTime()
        local start = host._vf_essenceRechargeStart or now
        local elapsed = now - start
        local p = rechargeTime > 0 and (elapsed / rechargeTime) or 0
        if p < 0 then p = 0 end
        if p > 1 then p = 1 end
        return p
    end
    return 0
end

--- 就绪符文优先，冷却中按剩余时间排序；只读 runeCooldownSnapshot（由 GetSecondaryResourceValue 填充）。
local function BuildRuneSegmentState(maxRunes)
    local readyList = runeReadyScratch
    for ri = #readyList, 1, -1 do
        readyList[ri] = nil
    end
    local cdList = runeCdScratch
    for ci = #cdList, 1, -1 do
        cdList[ci] = nil
    end
    local now = GetTime()
    local poolIdx = 1
    for i = 1, maxRunes do
        local cached = runeCooldownSnapshot[i]
        local start, duration, runeReady = cached.start, cached.duration, cached.runeReady
        if runeReady then
            readyList[#readyList + 1] = i
        else
            local info = runeCdInfoPool[poolIdx]
            poolIdx = poolIdx + 1
            info.index = i
            if start and duration and duration > 0 then
                local elapsed = now - start
                info.remaining = math.max(0, duration - elapsed)
                info.frac = math.min(1, math.max(0, elapsed / duration))
            else
                info.remaining = math.huge
                info.frac = 0
            end
            cdList[#cdList + 1] = info
        end
    end
    table.sort(cdList, function(a, b)
        return a.remaining < b.remaining
    end)
    local order = runeOrderScratch
    local fillByIndex = runeFillScratch
    for fi = 1, maxRunes do
        fillByIndex[fi] = nil
    end
    local orderLen = 0
    for _, idx in ipairs(readyList) do
        orderLen = orderLen + 1
        order[orderLen] = idx
        fillByIndex[idx] = 1
    end
    for _, info in ipairs(cdList) do
        orderLen = orderLen + 1
        order[orderLen] = info.index
        fillByIndex[info.index] = info.frac
    end
    return order, fillByIndex
end

local function RuntimeUsesSegmentRechargeColors(resource)
    if not E_PT then
        return RS.RuntimeUsesEssenceRechargeTicker(resource)
    end
    return RS.RuntimeUsesEssenceRechargeTicker(resource)
        or resource == E_PT.Runes
        or resource == E_PT.SoulShards
end

local function PipCellFillAmount(cur, pipIndex)
    if cur == nil or pipIndex < 1 then
        return 0
    end
    if IsSecretNumber(cur) then
        return 0
    end
    local c = tonumber(cur)
    if not c then
        return 0
    end
    return math.min(1, math.max(0, c - (pipIndex - 1)))
end

local function RuntimeUsesOverchargedComboPointColor(resource)
    return type(resource) == "number"
        and E_PT
        and resource == E_PT.ComboPoints
end

local function BuildChargedComboPointLookup(host, resource)
    if not RuntimeUsesOverchargedComboPointColor(resource) or not GetUnitChargedPowerPoints then
        if host then
            host._vf_chargedLookup = nil
            host._vf_chargedLookupSig = nil
        end
        return nil
    end
    local points = GetUnitChargedPowerPoints("player") or {}
    local signature = (#points > 0) and table.concat(points, ",") or ""
    if host and host._vf_chargedLookupSig == signature then
        return host._vf_chargedLookup
    end
    local lookup = (host and host._vf_chargedLookup) or {}
    wipe(lookup)
    for _, pointIndex in ipairs(points) do
        lookup[pointIndex] = true
    end
    lookup = next(lookup) and lookup or nil
    if host then
        host._vf_chargedLookup = lookup
        host._vf_chargedLookupSig = signature
    end
    return lookup
end

local function ComputeDiscretePipFill(resource, host, gameSlot, cur, max, runeOrder, runeFill)
    if RS.RuntimeUsesEssenceRechargeTicker(resource) then
        local curInt = math.floor(tonumber(cur) or 0)
        local maxInt = math.floor(tonumber(max) or 0)
        return GetEssencePipFill(host, gameSlot, curInt, maxInt)
    end
    if resource == E_PT.Runes and runeOrder and runeFill then
        local runeIdx = runeOrder[gameSlot]
        if not runeIdx then
            return 0
        end
        return runeFill[runeIdx] or 0
    end
    return PipCellFillAmount(cur, gameSlot)
end

--- 双态分段：满/就绪色与充能中色（精华、符文、毁灭术碎片等）。
local function SetDualColorForDiscreteSeg(segSb, resource, fill, gameSlot, cur, curIntEssence, rechargeCol, readyCol)
    if not rechargeCol or not readyCol then
        return false
    end
    if RS.RuntimeUsesEssenceRechargeTicker(resource) and curIntEssence then
        if gameSlot <= curIntEssence then
            ApplyStatusBarColorCached(segSb, readyCol, 1, 1, 1, 1)
        else
            ApplyStatusBarColorCached(segSb, rechargeCol, 1, 1, 1, 1)
        end
        return true
    end
    if resource == E_PT.Runes then
        if fill >= 1 - 1e-6 then
            ApplyStatusBarColorCached(segSb, readyCol, 1, 1, 1, 1)
        else
            ApplyStatusBarColorCached(segSb, rechargeCol, 1, 1, 1, 1)
        end
        return true
    end
    if resource == E_PT.SoulShards then
        local c = tonumber(cur) or 0
        local w = math.floor(c)
        if gameSlot <= w then
            ApplyStatusBarColorCached(segSb, readyCol, 1, 1, 1, 1)
        else
            ApplyStatusBarColorCached(segSb, rechargeCol, 1, 1, 1, 1)
        end
        return true
    end
    return false
end

local DISCRETE_SEGMENT_RESOURCES = E_PT and {
    [E_PT.ArcaneCharges] = true,
    [E_PT.Chi] = true,
    [E_PT.ComboPoints] = true,
    [E_PT.HolyPower] = true,
    [E_PT.Essence] = true,
    [E_PT.Runes] = true,
    [E_PT.SoulShards] = true,
    ["ICICLES"] = true,
    ["TIP_OF_THE_SPEAR"] = true,
    ["SOUL_FRAGMENTS_VENGEANCE"] = true,
    ["MAELSTROM_WEAPON"] = true,
} or {}

local function UsesDiscreteSegments(resource)
    return resource and DISCRETE_SEGMENT_RESOURCES[resource] == true
end

local function CurTooOpaqueForDiscretePips(cur, resource)
    if resource == "SOUL_FRAGMENTS_VENGEANCE" then
        return false
    end
    return cur ~= nil and IsSecretNumber(cur)
end

local function EnsureSegContainer(host)
    if host._vf_segContainer then
        return host._vf_segContainer
    end
    local c = CreateFrame("Frame", nil, host)
    c:SetFrameLevel((host:GetFrameLevel() or 0) + 1)
    c:SetAllPoints()
    c:EnableMouse(false)
    host._vf_segContainer = c
    host._vf_segFrames = {}
    return c
end

local function GetOrCreateSegFrame(host, index)
    host._vf_segFrames = host._vf_segFrames or {}
    local seg = host._vf_segFrames[index]
    if seg then
        return seg
    end
    seg = CreateFrame("Frame", nil, host._vf_segContainer)
    local base = (host._vf_segContainer:GetFrameLevel() or 0)
    seg:SetFrameLevel(base)
    seg._bg = seg:CreateTexture(nil, "BACKGROUND")
    seg._bg:SetAllPoints(seg)
    seg._sb = CreateFrame("StatusBar", nil, seg)
    seg._sb:SetFrameLevel(base + 1)
    seg._sb:SetAllPoints(seg)
    seg._border = CreateFrame("Frame", nil, seg)
    seg._border:SetFrameLevel(base + 4)
    seg._border:SetAllPoints(seg)
    seg._border:EnableMouse(false)
    host._vf_segFrames[index] = seg
    return seg
end

local function ClearSegmentUI(host)
    if not host then
        return
    end
    if host._vf_rechargeTicker then
        host._vf_rechargeTicker:Cancel()
        host._vf_rechargeTicker = nil
    end
    host._vf_segmentMode = false
    host._vf_segLastMax = nil
    host._vf_segLastResource = nil
    if host._vf_segContainer then
        host._vf_segContainer:Hide()
    end
    if host._vf_segFrames then
        for _, f in ipairs(host._vf_segFrames) do
            if f then
                f:Hide()
            end
        end
    end
    if host._vf_sb then
        host._vf_sb:Show()
    end
    host._vf_lastValueResource = nil
    host._vf_lastValueMax = nil
    host._vf_lastValueCur = nil
    host._vf_lastValueShowText = nil
    if host._vf_borderFrame and PP and PP.ShowBorder then
        PP.ShowBorder(host._vf_borderFrame)
    end
end

--- @param skipLayout boolean|nil
local function UpdateDiscreteSegmentDisplay(host, cfg, db, resource, max, cur, style, skipLayout)
    local sb = host._vf_sb
    local borderFrame = host._vf_borderFrame
    if not host or not cfg or not db or not sb or not borderFrame or not BFK or not PP then
        return false
    end

    local wantSeg = UsesDiscreteSegments(resource) and type(max) == "number" and max >= 2 and not CurTooOpaqueForDiscretePips(cur, resource)
    if not wantSeg then
        ClearSegmentUI(host)
        return false
    end

    if host._vf_segLastMax ~= max or host._vf_segLastResource ~= resource then
        skipLayout = false
    end

    local fullLayout = (not skipLayout) or (not host._vf_segmentMode)
    host._vf_segLastMax = max
    host._vf_segLastResource = resource

    if fullLayout then
        sb:Hide()
        PP.HideBorder(borderFrame)

        local container = EnsureSegContainer(host)
        container:Show()
        host._vf_segmentMode = true

        local totalW = host:GetWidth()
        local totalH = host:GetHeight()
        if totalW <= 0 or totalH <= 0 then
            return true
        end

        local dir = cfg.barDirection or "horizontal"
        local reverse = cfg.barReverse == true
        local texPath = BFK.ResolveBarTexture(cfg.barTexture)

        for pos = 1, max do
            GetOrCreateSegFrame(host, pos)
        end
        BFK.LayoutDiscreteBarSegmentFrames(container, cfg, max, dir, host._vf_segFrames, host)

        local curInt = (not IsSecretNumber(cur)) and math.floor(tonumber(cur) or 0) or nil
        local maxInt = (not IsSecretNumber(max)) and math.floor(tonumber(max) or 0) or nil
        if RS.RuntimeUsesEssenceRechargeTicker(resource) and curInt and maxInt then
            SyncEssenceRechargeClock(host, cur, max)
        end
        local runeOrder, runeFill
        if resource == E_PT.Runes and maxInt and maxInt > 0 then
            runeOrder, runeFill = BuildRuneSegmentState(maxInt)
        end
        local fillCol = ResolveBarTierFillColor(resource, style, cur, max)
        local rechargeCol = RS.ResolveRechargeColorForBase(style, fillCol)
        local readyCol = fillCol
        local useSmoothSeg = cfg and (cfg.smoothProgress == nil or cfg.smoothProgress == true)
        local useDual = RuntimeUsesSegmentRechargeColors(resource)
        local useOverchargedCombo = RuntimeUsesOverchargedComboPointColor(resource)
        local chargedLookup = BuildChargedComboPointLookup(host, resource)
        local chargedColor = chargedLookup and RS.ResolveOverchargedComboPointColor(style, fillCol) or nil
        local dimChargedColor = chargedColor and RS.DimBarColor(chargedColor, 0.5) or nil
        local comboCurrent = useOverchargedCombo and UnitPower("player", resource) or cur
        local dimFillCol = useOverchargedCombo and RS.DimBarColor(fillCol, 0.5) or nil
        local isSecret = IsSecretNumber(cur)

        local function StyleAndShowSegment(segFrame, pos)
            local segSb = segFrame._sb
            local chromeSig = table.concat({ tostring(texPath), tostring(dir) }, "\031")
            if segSb._vf_chromeSig ~= chromeSig then
                segSb:SetStatusBarTexture(texPath)
                segSb._vf_fillColorSig = nil
                BFK.ConfigureStatusBar(segSb)
                BFK.SetOrientation(segSb, dir)
                BFK.SetReverseFill(segSb, false)
                segSb._vf_chromeSig = chromeSig
            end
            BFK.ApplySegmentCellBorder(segFrame._border, cfg)

            local gameSlot = reverse and (max - pos + 1) or pos
            local fill = (not isSecret) and ComputeDiscretePipFill(resource, host, gameSlot, cur, max, runeOrder, runeFill) or 0
            local isCharged = chargedLookup and chargedLookup[gameSlot] and chargedColor
            segFrame._bg:SetColorTexture(0, 0, 0, 0)
            local didDual = false
            if useOverchargedCombo then
                if isCharged then
                    ApplyBarProgressCached(segSb, 0, 1, 1, useSmoothSeg)
                    if gameSlot <= comboCurrent then
                        ApplyStatusBarColorCached(segSb, chargedColor, 1, 1, 1, 1)
                    else
                        ApplyStatusBarColorCached(segSb, dimChargedColor, 1, 1, 1, 1)
                    end
                elseif gameSlot <= comboCurrent then
                    ApplyBarProgressCached(segSb, 0, 1, 1, useSmoothSeg)
                    ApplyStatusBarColorCached(segSb, fillCol, 1, 1, 1, 1)
                else
                    ApplyBarProgressCached(segSb, 0, 1, 0, useSmoothSeg)
                    ApplyStatusBarColorCached(segSb, dimFillCol, 1, 1, 1, 1)
                end
            elseif isSecret then
                ApplyBarProgressCached(segSb, gameSlot - 1, gameSlot, cur, false)
                ApplyStatusBarColorCached(segSb, fillCol, 1, 1, 1, 1)
            elseif useDual then
                didDual = SetDualColorForDiscreteSeg(segSb, resource, fill, gameSlot, cur, curInt, rechargeCol, readyCol)
            end
            if not didDual and not isSecret then
                if not isCharged and not useOverchargedCombo then
                    ApplyBarProgressCached(segSb, 0, 1, fill, useSmoothSeg)
                    ApplyMainBarFillColor(segSb, resource, style, cur, max)
                end
            elseif not isSecret then
                ApplyBarProgressCached(segSb, 0, 1, fill, useSmoothSeg)
            end
            segFrame:Show()
        end

        for pos = 1, max do
            StyleAndShowSegment(host._vf_segFrames[pos], pos)
        end

        for i = max + 1, #(host._vf_segFrames or {}) do
            local f = host._vf_segFrames[i]
            if f then
                f:Hide()
            end
        end

        return true
    end

    if not host._vf_segmentMode then
        return false
    end

    local curInt = (not IsSecretNumber(cur)) and math.floor(tonumber(cur) or 0) or nil
    local maxInt = (not IsSecretNumber(max)) and math.floor(tonumber(max) or 0) or nil
    if RS.RuntimeUsesEssenceRechargeTicker(resource) and curInt and maxInt then
        SyncEssenceRechargeClock(host, cur, max)
    end
    local runeOrder, runeFill
    if resource == E_PT.Runes and maxInt and maxInt > 0 then
        runeOrder, runeFill = BuildRuneSegmentState(maxInt)
    end
    local fillCol = ResolveBarTierFillColor(resource, style, cur, max)
    local rechargeCol = RS.ResolveRechargeColorForBase(style, fillCol)
    local readyCol = fillCol
    local useSmoothSeg = cfg and (cfg.smoothProgress == nil or cfg.smoothProgress == true)
    local useDual = RuntimeUsesSegmentRechargeColors(resource)
    local useOverchargedCombo = RuntimeUsesOverchargedComboPointColor(resource)
    local chargedLookup = BuildChargedComboPointLookup(host, resource)
    local chargedColor = chargedLookup and RS.ResolveOverchargedComboPointColor(style, fillCol) or nil
    local dimChargedColor = chargedColor and RS.DimBarColor(chargedColor, 0.5) or nil
    local comboCurrent = useOverchargedCombo and UnitPower("player", resource) or cur
    local dimFillCol = useOverchargedCombo and RS.DimBarColor(fillCol, 0.5) or nil
    local isSecret = IsSecretNumber(cur)

    local reverse = cfg.barReverse == true
    for pos = 1, max do
        local segFrame = host._vf_segFrames and host._vf_segFrames[pos]
        if segFrame and segFrame._sb then
            local gameSlot = reverse and (max - pos + 1) or pos
            local fill = (not isSecret) and ComputeDiscretePipFill(resource, host, gameSlot, cur, max, runeOrder, runeFill) or 0
            local isCharged = chargedLookup and chargedLookup[gameSlot] and chargedColor
            segFrame._bg:SetColorTexture(0, 0, 0, 0)
            local didDual = false
            if useOverchargedCombo then
                if isCharged then
                    ApplyBarProgressCached(segFrame._sb, 0, 1, 1, useSmoothSeg)
                    if gameSlot <= comboCurrent then
                        ApplyStatusBarColorCached(segFrame._sb, chargedColor, 1, 1, 1, 1)
                    else
                        ApplyStatusBarColorCached(segFrame._sb, dimChargedColor, 1, 1, 1, 1)
                    end
                elseif gameSlot <= comboCurrent then
                    ApplyBarProgressCached(segFrame._sb, 0, 1, 1, useSmoothSeg)
                    ApplyStatusBarColorCached(segFrame._sb, fillCol, 1, 1, 1, 1)
                else
                    ApplyBarProgressCached(segFrame._sb, 0, 1, 0, useSmoothSeg)
                    ApplyStatusBarColorCached(segFrame._sb, dimFillCol, 1, 1, 1, 1)
                end
            elseif isSecret then
                ApplyBarProgressCached(segFrame._sb, gameSlot - 1, gameSlot, cur, false)
                ApplyStatusBarColorCached(segFrame._sb, fillCol, 1, 1, 1, 1)
            elseif useDual then
                didDual = SetDualColorForDiscreteSeg(segFrame._sb, resource, fill, gameSlot, cur, curInt, rechargeCol, readyCol)
            end
            if not didDual and not isSecret then
                if not isCharged and not useOverchargedCombo then
                    ApplyBarProgressCached(segFrame._sb, 0, 1, fill, useSmoothSeg)
                    ApplyMainBarFillColor(segFrame._sb, resource, style, cur, max)
                end
            elseif not isSecret then
                ApplyBarProgressCached(segFrame._sb, 0, 1, fill, useSmoothSeg)
            end
        end
    end
    return true
end

local function AbbreviateSafe(n)
    if n == nil then
        return ""
    end
    if AbbreviateNumbers then
        local ok, s = pcall(function()
            return string.format("%s", AbbreviateNumbers(n))
        end)
        if ok then
            return s
        end
    end
    if not IsSecretNumber(n) then
        local t = tonumber(n)
        if t then
            return string.format("%d", math.floor(t))
        end
    end
    return ""
end

local function PowerPercentSafe(resource)
    if type(resource) ~= "number" or not UnitPowerPercent then
        return nil
    end
    local curve = _G.CurveConstants and CurveConstants.ScaleTo100 or 2
    local ok, pct = pcall(UnitPowerPercent, "player", resource, true, curve)
    if ok and type(pct) == "number" then
        return pct
    end
    return nil
end

local function FormatText(style, max, cur, resource)
    if not style or style.showText == false then
        return ""
    end

    if style.showPercent then
        if resource == "STAGGER" then
            return string.format("%.0f", lastStaggerPercent or 0)
        end
        if type(resource) == "number" and issecretvalue and (issecretvalue(max) or issecretvalue(cur)) then
            local pct = PowerPercentSafe(resource)
            if pct then
                return string.format("%.0f", pct)
            end
            return ""
        end
        if max and not IsSecretNumber(max) and not IsSecretNumber(cur) and max > 0 then
            return string.format("%.0f", (cur / max) * 100)
        end
        if type(resource) == "number" then
            local pct = PowerPercentSafe(resource)
            if pct then
                return string.format("%.0f", pct)
            end
        end
        return ""
    end

    --- AbbreviateNumbers 可能返回受保护字符串，勿用 == 与 "" 比较
    local curStr = AbbreviateSafe(cur)
    local cmpOk, nonEmpty = pcall(function()
        return curStr ~= ""
    end)
    if not cmpOk then
        return curStr
    end
    if nonEmpty then
        return curStr
    end
    return ""
end

-- =========================================================
-- SECTION 4: 布局与显隐刷新
-- =========================================================

local function GetBarHostPixelDimensions(cfg)
    local along = Utils.ResolveSyncedBarSpan(cfg, {
        manualKey = "barWidth",
        modeKey = "barWidthMode",
        defaultMode = "sync_essential",
    })
    local thick = cfg.barHeight or 16
    if cfg and cfg.barDirection == "vertical" then
        return thick, along
    end
    return along, thick
end

---@param layoutCfg 条尺寸与样式键位
---@param anchorCfg 锚点键位，默认同 layoutCfg；次条可在主条隐藏时改用 primaryBar
--- 运行时刷新只消费现有配置，不允许把计算后的位置反写到 Store。
--- 坐标持久化仅允许来自显式编辑：DragFrame 拖拽回调或 Grid 的 x/y 控件。
local function ApplyLayoutHost(host, layoutCfg, anchorCfg)
    if not host or not layoutCfg then return end
    anchorCfg = anchorCfg or layoutCfg
    local w, h = GetBarHostPixelDimensions(layoutCfg)
    if PP and PP.SetSize then
        PP.SetSize(host, w, h)
    else
        host:SetSize(w, h)
    end
    local DF = VFlow.DragFrame
    if not (DF and DF.isHostDragging and DF.isHostDragging(host)) then
        CA.ApplyFramePosition(host, anchorCfg, nil)
    end
end

local function SecondaryAnchorsToPrimaryBar(db)
    return db and db.secondaryBar
        and db.secondaryBar.usePrimaryPositionWhenPrimaryHidden ~= false
        and primaryHost
        and not primaryHost:IsShown()
end

local function AnchorConfigForSecondary(db)
    if not db or not db.secondaryBar then
        return nil
    end
    if SecondaryAnchorsToPrimaryBar(db) then
        return db.primaryBar
    end
    return db.secondaryBar
end

local function ApplyBarBackground(host, db)
    if not host or not db or not host._vf_bg then
        return
    end
    local c = db.resourceBarBackground
    local colorSig, r, g, b, a = BuildColorSignature(c, 0, 0, 0, 0.5)
    if colorSig and host._vf_bgColorSig == colorSig then
        return
    end
    host._vf_bg:SetColorTexture(r, g, b, a)
    host._vf_bgColorSig = colorSig
end

local function EditModeActive()
    return VFlow.State and (VFlow.State.isEditMode or VFlow.State.systemEditMode or VFlow.State.internalEditMode) or false
end

local function BarUsesSmooth(cfg)
    return cfg and (cfg.smoothProgress == nil or cfg.smoothProgress == true)
end

local function ResourceNeedsContinuousValueRefresh(resource)
    return E_PT and (resource == E_PT.Essence or resource == E_PT.Runes)
end

local function CanSkipValueOnlyRefresh(host, resource, max, cur, style)
    if not host or not style then
        return false
    end
    if ResourceNeedsContinuousValueRefresh(resource) then
        return false
    end
    if IsSecretNumber(max) or IsSecretNumber(cur) then
        return false
    end
    return host._vf_lastValueResource == resource
        and host._vf_lastValueMax == max
        and host._vf_lastValueCur == cur
        and host._vf_lastValueShowText == (style.showText ~= false)
end

local function RememberLastValueState(host, resource, max, cur, style)
    if not host or IsSecretNumber(max) or IsSecretNumber(cur) then
        if host then
            host._vf_lastValueResource = nil
            host._vf_lastValueMax = nil
            host._vf_lastValueCur = nil
            host._vf_lastValueShowText = nil
        end
        return
    end
    host._vf_lastValueResource = resource
    host._vf_lastValueMax = max
    host._vf_lastValueCur = cur
    host._vf_lastValueShowText = style and (style.showText ~= false) or false
end

--- StyleDisplay 作用域勾选且全局条件触发展示策略时，阻止显示（不替代模块自身的禁用/无资源等硬隐藏）
local function StyleDisplayForcesResourceBarHide()
    local VC = VFlow.VisibilityControl
    if VC and VC.ShouldApplyGlobalVisibilityHide then
        return VC.ShouldApplyGlobalVisibilityHide("resourceBars")
    end
    return false
end

local function SetResourceHostShown(host, wantShown)
    if not host then
        return
    end
    if StyleDisplayForcesResourceBarHide() then
        if host:IsShown() then
            host:Hide()
        end
        return
    end
    if wantShown and not host:IsShown() then
        host:Show()
    elseif not wantShown and host:IsShown() then
        host:Hide()
    end
end

---@param skipLayout boolean|nil true 时跳过尺寸/锚点/字体，仅刷新数值与条（OnUpdate 轮询路径）
local function UpdateOneSlot(context, isSecondary, skipLayout)
    local db = context and context.db or GetDb()
    if not db then
        return
    end
    local cfg, host, sb, fs
    if isSecondary then
        cfg = db.secondaryBar
        host = secondaryHost
        sb = secondarySB
        fs = secondaryText
    else
        cfg = db.primaryBar
        host = primaryHost
        sb = primarySB
        fs = primaryText
    end
    if not host or not cfg or not sb then
        return
    end

    host._vf_slotIsSecondary = isSecondary

    if not skipLayout then
        local anchorCfg = nil
        if isSecondary then
            anchorCfg = AnchorConfigForSecondary(db)
        end
        ApplyLayoutHost(host, cfg, anchorCfg)
        ApplyTextFont(fs, cfg.textFont)
        ApplyBarBackground(host, db)
        sb._vf_fillColorSig = nil
        if BFK and BFK.ApplyResourceBarChrome then
            BFK.ApplyResourceBarChrome(host, cfg)
        end
    end

    if C_PetBattles and C_PetBattles.IsInBattle and C_PetBattles.IsInBattle() then
        ClearSegmentUI(host)
        host:Hide()
        return
    end

    if cfg.enabled == false then
        ClearSegmentUI(host)
        host:Hide()
        return
    end

    local specID = context and context.specID or CurrentSpecId()
    if CR and CR.IsBarEnabledForSpec and not CR.IsBarEnabledForSpec(cfg, specID) then
        ClearSegmentUI(host)
        host:Hide()
        return
    end

    local resource
    if isSecondary then
        resource = context and context.secondaryResource or nil
    else
        resource = context and context.primaryResource or nil
    end

    if not resource then
        if EditModeActive() then
            ClearSegmentUI(host)
            local placeholderResource = (E_PT and E_PT.Mana) or "MANA"
            local phStyle = RS.ResolveStyle(db, placeholderResource)
            SetResourceHostShown(host, true)
            ApplyBarProgressCached(sb, 0, 5, 4, false)
            ApplyMainBarFillColor(sb, placeholderResource, phStyle, 4, 5)
            SetTextIfChanged(fs, "4")
            SetShownIfChanged(fs, phStyle.showText ~= false)
        else
            ClearSegmentUI(host)
            host:Hide()
        end
        return
    end

    local style = RS.ResolveStyle(db, resource)

    local max, cur
    if isSecondary then
        max, cur = GetSecondaryResourceValue(resource)
    else
        max, cur = GetPrimaryResourceValue(resource)
    end

    if max == nil then
        if EditModeActive() then
            ClearSegmentUI(host)
            SetResourceHostShown(host, true)
            ApplyBarProgressCached(sb, 0, 5, 4, false)
            ApplyMainBarFillColor(sb, type(resource) == "number" and resource or ((E_PT and E_PT.Mana) or "MANA"), style, 4, 5)
            SetTextIfChanged(fs, "4")
            SetShownIfChanged(fs, style.showText ~= false)
        else
            ClearSegmentUI(host)
            host:Hide()
        end
        return
    end

    SetResourceHostShown(host, true)
    if skipLayout and CanSkipValueOnlyRefresh(host, resource, max, cur, style) then
        return
    end
    local segOn = UpdateDiscreteSegmentDisplay(host, cfg, db, resource, max, cur, style, skipLayout)
    if not segOn then
        ApplyBarProgressCached(sb, 0, max, cur, BarUsesSmooth(cfg))
        ApplyMainBarFillColor(sb, resource, style, cur, max)
    end
    if style.showText ~= false then
        SetTextIfChanged(fs, FormatText(style, max, cur, resource))
    else
        SetTextIfChanged(fs, "")
    end
    SetShownIfChanged(fs, style.showText ~= false)
    RememberLastValueState(host, resource, max, cur, style)
end

local RefreshValuesOnly

local function StartResourceBarValuePoll()
    if resourceBarPollDriver then
        return
    end
    local f = CreateFrame("Frame", "VFlow_ResourceBarPollDriver", UIParent)
    f:SetSize(1, 1)
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    f:EnableMouse(false)
    f:SetAlpha(0)
    f:Show()
    f:SetScript("OnUpdate", function(self, dt)
        self._vf_pollElapsed = (self._vf_pollElapsed or 0) + dt
        if self._vf_pollElapsed >= RESOURCE_BAR_POLL_INTERVAL then
            self._vf_pollElapsed = 0
            RefreshValuesOnly()
        end
    end)
    resourceBarPollDriver = f
end

local function RefreshAll()
    local context = BuildRuntimeContext(nil, true)
    UpdateOneSlot(context, false, false)
    UpdateOneSlot(context, true, false)
end

local function RefreshLayoutOnly()
    local context = BuildRuntimeContext(nil, false)
    UpdateOneSlot(context, false, false)
    UpdateOneSlot(context, true, false)
end

local function RefreshVisibilityOnly()
    local context = BuildRuntimeContext(nil, false)
    UpdateOneSlot(context, false, true)
    UpdateOneSlot(context, true, true)
end

--- 双槽均隐藏且非编辑模式时跳过轮询
local function ResourceBarsPollShouldSkip()
    if EditModeActive() then
        return false
    end
    local p = primaryHost
    local s = secondaryHost
    if (not p or not p:IsShown()) and (not s or not s:IsShown()) then
        return true
    end
    return false
end

RefreshValuesOnly = function()
    if ResourceBarsPollShouldSkip() then
        return
    end
    local context = BuildRuntimeContext(nil, false)
    UpdateOneSlot(context, false, true)
    UpdateOneSlot(context, true, true)
end

local function HandleLayoutRuntimeEvent()
    MarkRuntimeContextDirty()
    RefreshAll()
end

-- =========================================================
-- SECTION 5: 刷新调度与运行时事件
-- =========================================================

rb.RefreshAll = RefreshAll
rb.RefreshVisibilityOnly = RefreshVisibilityOnly

function rb.OnSkillViewerLayoutChanged()
    local d = GetDb()
    if not d then return end
    local need = false
    for _, bar in ipairs({ d.primaryBar, d.secondaryBar }) do
        local m = bar and (bar.barWidthMode or "sync_essential")
        if m == "sync_essential" or m == "sync_utility" then
            need = true
            break
        end
    end
    if need then
        RefreshLayoutOnly()
    end
end

local function RegisterRuntimeEvents()
    if runtimeEventsRegistered then
        return
    end
    runtimeEventsRegistered = true
    local registerEvent = (Profiler and Profiler.registerEvent) or function(event, owner, callback, units)
        VFlow.on(event, owner, callback, units)
    end
    registerEvent("PLAYER_SPECIALIZATION_CHANGED", EVENT_OWNER, HandleLayoutRuntimeEvent, "player", "RB:HandleLayoutRuntimeEvent", "count")
    registerEvent("PLAYER_REGEN_ENABLED", EVENT_OWNER, HandleLayoutRuntimeEvent, nil, "RB:HandleLayoutRuntimeEvent", "count")
    registerEvent("PLAYER_REGEN_DISABLED", EVENT_OWNER, HandleLayoutRuntimeEvent, nil, "RB:HandleLayoutRuntimeEvent", "count")
    if select(2, UnitClass("player")) == "DRUID" then
        registerEvent("UPDATE_SHAPESHIFT_FORM", EVENT_OWNER, HandleLayoutRuntimeEvent, nil, "RB:HandleLayoutRuntimeEvent", "count")
    end
    StartResourceBarValuePoll()
end

-- =========================================================
-- SECTION 6: UI 帧生命周期
-- =========================================================

local function EnsureBarLabel(host, existingFs)
    if not host then
        return existingFs
    end
    local holder = host._vf_textHolder
    if not holder then
        holder = CreateFrame("Frame", nil, host)
        holder:SetAllPoints(host)
        holder:SetFrameLevel((host:GetFrameLevel() or 0) + 10)
        holder:EnableMouse(false)
        host._vf_textHolder = holder
    end
    if existingFs and existingFs.SetParent and existingFs:GetParent() ~= holder then
        existingFs:SetParent(holder)
    end
    if not existingFs then
        existingFs = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        existingFs:SetJustifyH("CENTER")
    end
    return existingFs
end

local function EnsureFrames()
    if primaryHost and secondaryHost then
        return
    end

    if not primaryHost then
        primaryHost = CreateFrame("Frame", "VFlow_ResourceBarPrimary", UIParent, "BackdropTemplate")
        primaryHost:SetFrameStrata("MEDIUM")
        primaryHost:SetFrameLevel(20)
        primaryHost:SetClampedToScreen(true)
        primaryHost:SetMovable(true)
        primaryHost:EnableMouse(false)

        if BFK and BFK.SetupResourceBarHost then
            BFK.SetupResourceBarHost(primaryHost)
        end
        primarySB = primaryHost._vf_sb
        primaryText = EnsureBarLabel(primaryHost, nil)
    else
        primarySB = primaryHost._vf_sb or primarySB
        primaryText = EnsureBarLabel(primaryHost, primaryText)
    end

    if not secondaryHost then
        secondaryHost = CreateFrame("Frame", "VFlow_ResourceBarSecondary", UIParent, "BackdropTemplate")
        secondaryHost:SetFrameStrata("MEDIUM")
        secondaryHost:SetFrameLevel(21)
        secondaryHost:SetClampedToScreen(true)
        secondaryHost:SetMovable(true)
        secondaryHost:EnableMouse(false)

        if BFK and BFK.SetupResourceBarHost then
            BFK.SetupResourceBarHost(secondaryHost)
        end
        secondarySB = secondaryHost._vf_sb
        secondaryText = EnsureBarLabel(secondaryHost, nil)
    else
        secondarySB = secondaryHost._vf_sb or secondarySB
        secondaryText = EnsureBarLabel(secondaryHost, secondaryText)
    end
end

-- =========================================================
-- SECTION 7: 拖拽与模块生命周期
-- =========================================================

local function RegisterDrag()
    local db = GetDb()
    if not db or not primaryHost then return end

    if not primaryHost._vf_dragReg then
        VFlow.DragFrame.register(primaryHost, {
            label = (VFlow.L and VFlow.L["Primary resource bar"]) or "Primary resource",
            menuKey = "resource_primary",
            getAnchorConfig = function()
                local d = GetDb()
                return d and d.primaryBar
            end,
            onPositionChanged = function(_, kind, x, y)
                if kind ~= "PLAYER_ANCHOR" and kind ~= "SYMMETRIC" then return end
                local d = GetDb()
                if not d then return end
                d.primaryBar.x = x
                d.primaryBar.y = y
                VFlow.Store.set(MODULE_KEY, "primaryBar.x", x)
                VFlow.Store.set(MODULE_KEY, "primaryBar.y", y)
            end,
        })
        primaryHost._vf_dragReg = true
    end
    if secondaryHost and not secondaryHost._vf_dragReg then
        VFlow.DragFrame.register(secondaryHost, {
            label = (VFlow.L and VFlow.L["Secondary resource bar"]) or "Secondary resource",
            menuKey = "resource_secondary",
            getAnchorConfig = function()
                local d = GetDb()
                if not d or not d.secondaryBar then return end
                if SecondaryAnchorsToPrimaryBar(d) then
                    return d.primaryBar
                end
                return d.secondaryBar
            end,
            onPositionChanged = function(_, kind, x, y)
                if kind ~= "PLAYER_ANCHOR" and kind ~= "SYMMETRIC" then return end
                local d = GetDb()
                if not d then return end
                if SecondaryAnchorsToPrimaryBar(d) then
                    d.primaryBar.x = x
                    d.primaryBar.y = y
                    VFlow.Store.set(MODULE_KEY, "primaryBar.x", x)
                    VFlow.Store.set(MODULE_KEY, "primaryBar.y", y)
                else
                    d.secondaryBar.x = x
                    d.secondaryBar.y = y
                    VFlow.Store.set(MODULE_KEY, "secondaryBar.x", x)
                    VFlow.Store.set(MODULE_KEY, "secondaryBar.y", y)
                end
            end,
        })
        secondaryHost._vf_dragReg = true
    end
    VFlow.DragFrame.applyRegisteredPosition(primaryHost)
    if secondaryHost then
        VFlow.DragFrame.applyRegisteredPosition(secondaryHost)
    end
end

local MODULE_DB_DEFAULT_BG = { r = 0.2, g = 0.2, b = 0.2, a = 0.5 }

function rb.OnModuleReady()
    if initialized then
        MarkRuntimeContextDirty()
        if RS and RS.WipeRuntimeCaches then
            RS.WipeRuntimeCaches(GetDb())
        end
        RefreshAll()
        return
    end
    if not VFlow.getDBIfReady(MODULE_KEY) then
        return
    end
    local d0 = GetDb()
    if d0 and VFlow.Utils then
        d0.resourceStyles = d0.resourceStyles or {}
        VFlow.Utils.applyDefaults(d0.resourceStyles, RS.BuildFullResourceStylesDefaults())
        VFlow.Utils.applyDefaults(d0, { resourceBarBackground = MODULE_DB_DEFAULT_BG })
    end
    EnsureFrames()
    RegisterRuntimeEvents()
    if RS and RS.WipeRuntimeCaches then
        RS.WipeRuntimeCaches(d0)
    end
    RefreshAll()
    RegisterDrag()

    if not rb._storeWatched then
        rb._storeWatched = true
        VFlow.Store.watch(MODULE_KEY, "Core.ResourceBars", function(key)
            local d = GetDb()
            if not d then return end
            if key and (key:find("%.x$") or key:find("%.y$")) then
                EnsureFrames()
                ApplyLayoutHost(primaryHost, d.primaryBar)
                if d.secondaryBar and secondaryHost then
                    ApplyLayoutHost(secondaryHost, d.secondaryBar, AnchorConfigForSecondary(d))
                end
                RegisterDrag()
                return
            end
            if RS and RS.WipeRuntimeCaches then
                RS.WipeRuntimeCaches(d)
            end
            RefreshLayoutOnly()
            RegisterDrag()
        end)
    end

    initialized = true
end

VFlow.ResourceBars = rb

if Profiler and Profiler.registerScope then
    Profiler.registerScope("RB:UpdateDiscreteSegments", function()
        return UpdateDiscreteSegmentDisplay
    end, function(fn)
        UpdateDiscreteSegmentDisplay = fn
    end)
    Profiler.registerScope(function(_, isSecondary)
        return isSecondary and "RB:UpdateSecondarySlot" or "RB:UpdatePrimarySlot"
    end, function()
        return UpdateOneSlot
    end, function(fn)
        UpdateOneSlot = fn
    end)
    Profiler.registerScope("RB:RefreshAll", function()
        return RefreshAll
    end, function(fn)
        RefreshAll = fn
        rb.RefreshAll = fn
    end)
    Profiler.registerScope("RB:RefreshValuesOnly", function()
        return RefreshValuesOnly
    end, function(fn)
        RefreshValuesOnly = fn
    end)
    Profiler.registerScope("RB:EnsureFrames", function()
        return EnsureFrames
    end, function(fn)
        EnsureFrames = fn
    end)
    Profiler.registerTableScope(rb, "OnModuleReady", "RB:OnModuleReady")
end

VFlow.on("PLAYER_ENTERING_WORLD", "ResourceBars.Boot", function()
    if VFlow.ResourceBars and VFlow.ResourceBars.OnModuleReady then
        VFlow.ResourceBars.OnModuleReady()
    end
end)

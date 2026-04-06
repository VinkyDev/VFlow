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

local function ProfStart(name)
    if not Profiler or not Profiler.start then
        return nil
    end
    return Profiler.start(name)
end

local function ProfStop(token)
    if not token or not Profiler or not Profiler.stop then
        return
    end
    Profiler.stop(token)
end

local function ProfCount(name)
    if not Profiler or not Profiler.count then
        return
    end
    Profiler.count(name)
end

-- =========================================================
-- SECTION 2: 运行时状态与资源解析
-- =========================================================

local lastStaggerPercent = 60
local runtimeEventsRegistered = false

local function IsSecretNumber(v)
    if v == nil or not issecretvalue then
        return false
    end
    return not not issecretvalue(v)
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

local function BuildRuntimeContext(db)
    local specID = CurrentSpecId()
    local row = FindActiveResourceRow(specID, GetShapeshiftFormID())
    local primaryResource = ResolveRuntimeResourceToken(row and row.primary)
    local secondaryResource = ResolveRuntimeResourceToken(row and row.secondary)
    if primaryResource ~= nil and primaryResource == secondaryResource then
        secondaryResource = nil
    end
    return {
        db = db or GetDb(),
        specID = specID,
        primaryResource = primaryResource,
        secondaryResource = secondaryResource,
    }
end

local function GetPrimaryResourceValue(resource)
    if not resource then return nil, nil end
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

    if resource == Enum.PowerType.Runes then
        local max = UnitPowerMax("player", resource)
        if max <= 0 then return nil, nil end
        local current = 0
        for i = 1, max do
            local _, _, runeReady = GetRuneCooldown(i)
            if runeReady then
                current = current + 1
            end
        end
        return max, current
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
                if max0 <= 0 then return nil, nil end
                return max0, cur0
            end
            local r = tonumber(raw) or 0
            local curShards = math.floor(r / 10) + (r % 10) / 10
            local maxP = UnitPowerMax("player", resource, false) or 5
            if maxP <= 0 then return nil, nil end
            return maxP, curShards
        end
        local cur = UnitPower("player", resource, false)
        local max = UnitPowerMax("player", resource, false)
        if max <= 0 then return nil, nil end
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
    if max <= 0 then return nil, nil end
    return max, cur
end

-- =========================================================
-- SECTION 3: 帧引用与外观工具
-- =========================================================

local primaryHost, secondaryHost
local primarySB, secondarySB
local primaryText, secondaryText
local tickFrame
local initialized = false

local SetDiscreteRechargeTicker

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
    return RS.TryResolveBarFillFromPowerPercent(resource, style) or RS.ResolveBarFillColor(style, cur, max)
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
    else
        sb:SetStatusBarColor(r, g, b, a)
    end
    sb._vf_fillColorSig = colorSig
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
        if not rate or rate <= 0 then
            rate = 0.2
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

--- 就绪符文优先，冷却中按剩余时间排序；返回每 UI 格对应符文槽及填充比例。
local function BuildRuneSegmentState(maxRunes)
    local readyList = {}
    local cdList = {}
    local now = GetTime()
    for i = 1, maxRunes do
        local start, duration, runeReady = GetRuneCooldown(i)
        if runeReady then
            readyList[#readyList + 1] = i
        else
            local remaining = math.huge
            local frac = 0
            if start and duration and duration > 0 then
                local elapsed = now - start
                remaining = math.max(0, duration - elapsed)
                frac = math.min(1, math.max(0, elapsed / duration))
            end
            cdList[#cdList + 1] = { index = i, remaining = remaining, frac = frac }
        end
    end
    table.sort(cdList, function(a, b)
        return a.remaining < b.remaining
    end)
    local order = {}
    local fillByIndex = {}
    for _, idx in ipairs(readyList) do
        order[#order + 1] = idx
        fillByIndex[idx] = 1
    end
    for _, info in ipairs(cdList) do
        order[#order + 1] = info.index
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
            segSb:SetStatusBarColor(readyCol.r or 1, readyCol.g or 1, readyCol.b or 1, readyCol.a or 1)
        else
            segSb:SetStatusBarColor(rechargeCol.r or 1, rechargeCol.g or 1, rechargeCol.b or 1, rechargeCol.a or 1)
        end
        return true
    end
    if resource == E_PT.Runes then
        if fill >= 1 - 1e-6 then
            segSb:SetStatusBarColor(readyCol.r or 1, readyCol.g or 1, readyCol.b or 1, readyCol.a or 1)
        else
            segSb:SetStatusBarColor(rechargeCol.r or 1, rechargeCol.g or 1, rechargeCol.b or 1, rechargeCol.a or 1)
        end
        return true
    end
    if resource == E_PT.SoulShards then
        local c = tonumber(cur) or 0
        local w = math.floor(c)
        if gameSlot <= w then
            segSb:SetStatusBarColor(readyCol.r or 1, readyCol.g or 1, readyCol.b or 1, readyCol.a or 1)
        else
            segSb:SetStatusBarColor(rechargeCol.r or 1, rechargeCol.g or 1, rechargeCol.b or 1, rechargeCol.a or 1)
        end
        return true
    end
    return false
end

local function NeedsDiscreteRechargeTicker(resource, cur, max)
    if RS.RuntimeUsesEssenceRechargeTicker(resource) then
        local c, m = tonumber(cur), tonumber(max)
        if c and m and math.floor(c) < math.floor(m) then
            return true
        end
        return false
    end
    if resource == E_PT.Runes then
        local m = tonumber(max) or UnitPowerMax("player", resource) or 0
        for i = 1, m do
            local _, _, runeReady = GetRuneCooldown(i)
            if not runeReady then
                return true
            end
        end
        return false
    end
    if resource == E_PT.SoulShards then
        local spec = C_SpecializationInfo.GetSpecialization()
        local specID = C_SpecializationInfo.GetSpecializationInfo(spec)
        if specID ~= 267 then
            return false
        end
        local raw = UnitPower("player", resource, true)
        if IsSecretNumber(raw) then
            return false
        end
        return (math.floor(tonumber(raw) or 0) % 10) ~= 0
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

local function CurTooOpaqueForDiscretePips(cur)
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
    SetDiscreteRechargeTicker(host, false)
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
    if host._vf_borderFrame and PP and PP.ShowBorder then
        PP.ShowBorder(host._vf_borderFrame)
    end
end

--- @param skipLayout boolean|nil
local function UpdateDiscreteSegmentDisplay(host, cfg, db, resource, max, cur, style, skipLayout)
    local _ps = ProfStart("RB:UpdateDiscreteSegments")
    local sb = host._vf_sb
    local borderFrame = host._vf_borderFrame
    if not host or not cfg or not db or not sb or not borderFrame or not BFK or not PP then
        ProfStop(_ps)
        return false
    end

    local wantSeg = UsesDiscreteSegments(resource) and type(max) == "number" and max >= 2 and not CurTooOpaqueForDiscretePips(cur)
    if not wantSeg then
        ClearSegmentUI(host)
        ProfStop(_ps)
        return false
    end

    if host._vf_segLastMax ~= max or host._vf_segLastResource ~= resource then
        skipLayout = false
    end

    local fullLayout = (not skipLayout) or (not host._vf_segmentMode)
    host._vf_segLastMax = max
    host._vf_segLastResource = resource

    if fullLayout then
        local _pl = ProfStart("RB:DiscreteSegmentsFullLayout")
        sb:Hide()
        PP.HideBorder(borderFrame)

        local container = EnsureSegContainer(host)
        container:Show()
        host._vf_segmentMode = true

        local totalW = host:GetWidth()
        local totalH = host:GetHeight()
        if totalW <= 0 or totalH <= 0 then
            SetDiscreteRechargeTicker(host, false)
            ProfStop(_pl)
            ProfStop(_ps)
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

        local function StyleAndShowSegment(segFrame, pos)
            segFrame._bg:SetColorTexture(0, 0, 0, 0)

            local segSb = segFrame._sb
            segSb:SetStatusBarTexture(texPath)
            segSb._vf_fillColorSig = nil
            BFK.ConfigureStatusBar(segSb)
            BFK.SetOrientation(segSb, dir)
            BFK.SetReverseFill(segSb, false)
            BFK.ApplySegmentCellBorder(segFrame._border, cfg)

            local gameSlot = reverse and (max - pos + 1) or pos
            local fill = ComputeDiscretePipFill(resource, host, gameSlot, cur, max, runeOrder, runeFill)
            local didDual = false
            if useDual then
                didDual = SetDualColorForDiscreteSeg(segSb, resource, fill, gameSlot, cur, curInt, rechargeCol, readyCol)
            end
            if not didDual then
                segSb:SetMinMaxValues(0, 1)
                segSb:SetValue(fill)
                ApplyMainBarFillColor(segSb, resource, style, cur, max)
            elseif BFK.ApplyBarProgress then
                BFK.ApplyBarProgress(segSb, 1, fill, useSmoothSeg)
            else
                segSb:SetMinMaxValues(0, 1)
                segSb:SetValue(fill)
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

        SetDiscreteRechargeTicker(host, NeedsDiscreteRechargeTicker(resource, cur, max), host._vf_slotIsSecondary == true)
        ProfStop(_pl)
        ProfStop(_ps)
        return true
    end

    if not host._vf_segmentMode then
        ProfStop(_ps)
        return false
    end

    local _pv = ProfStart("RB:DiscreteSegmentsValuesOnly")
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

    local reverse = cfg.barReverse == true
    for pos = 1, max do
        local segFrame = host._vf_segFrames and host._vf_segFrames[pos]
        if segFrame and segFrame._sb then
            local gameSlot = reverse and (max - pos + 1) or pos
            local fill = ComputeDiscretePipFill(resource, host, gameSlot, cur, max, runeOrder, runeFill)
            local didDual = false
            if useDual then
                didDual = SetDualColorForDiscreteSeg(segFrame._sb, resource, fill, gameSlot, cur, curInt, rechargeCol, readyCol)
            end
            if not didDual then
                segFrame._sb:SetMinMaxValues(0, 1)
                segFrame._sb:SetValue(fill)
                ApplyMainBarFillColor(segFrame._sb, resource, style, cur, max)
            elseif BFK.ApplyBarProgress then
                BFK.ApplyBarProgress(segFrame._sb, 1, fill, useSmoothSeg)
            else
                segFrame._sb:SetMinMaxValues(0, 1)
                segFrame._sb:SetValue(fill)
            end
        end
    end
    SetDiscreteRechargeTicker(host, NeedsDiscreteRechargeTicker(resource, cur, max), host._vf_slotIsSecondary == true)
    ProfStop(_pv)
    ProfStop(_ps)
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

local function AnchorStorePathForConfig(db, anchorCfg)
    if not db or not anchorCfg then return nil end
    if anchorCfg == db.primaryBar then return "primaryBar" end
    if anchorCfg == db.secondaryBar then return "secondaryBar" end
    return nil
end

---@param layoutCfg 条尺寸与样式键位
---@param anchorCfg 锚点键位，默认同 layoutCfg；次条可在主条隐藏时改用 primaryBar
local function ApplyLayoutHost(host, layoutCfg, anchorCfg)
    if not host or not layoutCfg then return end
    anchorCfg = anchorCfg or layoutCfg
    local w, h = GetBarHostPixelDimensions(layoutCfg)
    if PP and PP.SetSize then
        PP.SetSize(host, w, h)
    else
        host:SetSize(w, h)
    end
    local db = GetDb()
    local path = AnchorStorePathForConfig(db, anchorCfg)
    local store = VFlow.Store
    local DF = VFlow.DragFrame
    if not (DF and DF.isHostDragging and DF.isHostDragging(host)) then
        CA.ApplyFramePosition(host, anchorCfg, nil, {
            canonicalSync = (path and store and store.set) and function(nx, ny)
                store.set(MODULE_KEY, path .. ".x", nx)
                store.set(MODULE_KEY, path .. ".y", ny)
            end or nil,
        })
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

---@param skipLayout boolean|nil OnUpdate 轮询时跳过尺寸/锚点/字体，仅刷新数值与条
local function UpdateOneSlot(context, isSecondary, skipLayout)
    local _ps = ProfStart(isSecondary and "RB:UpdateSecondarySlot" or "RB:UpdatePrimarySlot")
    local db = context and context.db or GetDb()
    if not db then
        ProfStop(_ps)
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
        ProfStop(_ps)
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
        ProfStop(_ps)
        return
    end

    if cfg.enabled == false then
        ClearSegmentUI(host)
        host:Hide()
        ProfStop(_ps)
        return
    end

    local specID = context and context.specID or CurrentSpecId()
    if CR and CR.IsBarEnabledForSpec and not CR.IsBarEnabledForSpec(cfg, specID) then
        ClearSegmentUI(host)
        host:Hide()
        ProfStop(_ps)
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
            sb:SetMinMaxValues(0, 5)
            sb:SetValue(4)
            ApplyMainBarFillColor(sb, placeholderResource, phStyle, 4, 5)
            fs:SetText("4")
            fs:SetShown(phStyle.showText ~= false)
        else
            ClearSegmentUI(host)
            host:Hide()
        end
        ProfStop(_ps)
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
            sb:SetMinMaxValues(0, 5)
            sb:SetValue(4)
            ApplyMainBarFillColor(sb, type(resource) == "number" and resource or ((E_PT and E_PT.Mana) or "MANA"), style, 4, 5)
            fs:SetText("4")
            fs:SetShown(style.showText ~= false)
        else
            ClearSegmentUI(host)
            host:Hide()
        end
        ProfStop(_ps)
        return
    end

    SetResourceHostShown(host, true)
    local segOn = UpdateDiscreteSegmentDisplay(host, cfg, db, resource, max, cur, style, skipLayout)
    if not segOn then
        if BFK and BFK.ApplyBarProgress then
            BFK.ApplyBarProgress(sb, max, cur, BarUsesSmooth(cfg))
        end
        ApplyMainBarFillColor(sb, resource, style, cur, max)
    end
    fs:SetText(FormatText(style, max, cur, resource))
    fs:SetShown(style.showText ~= false)
    ProfStop(_ps)
end

SetDiscreteRechargeTicker = function(host, want, isSecondary)
    ProfCount("RB:SetDiscreteRechargeTicker")
    if not host then
        return
    end
    if want and not host._vf_rechargeTicker then
        host._vf_rechargeTicker = C_Timer.NewTicker(0.05, function()
            UpdateOneSlot(BuildRuntimeContext(), isSecondary, true)
        end)
    elseif not want and host._vf_rechargeTicker then
        host._vf_rechargeTicker:Cancel()
        host._vf_rechargeTicker = nil
    end
end

local function RefreshAll()
    local _ps = ProfStart("RB:RefreshAll")
    local context = BuildRuntimeContext()
    UpdateOneSlot(context, false, false)
    UpdateOneSlot(context, true, false)
    ProfStop(_ps)
end

local function RefreshValuesOnly()
    local _ps = ProfStart("RB:RefreshValuesOnly")
    local context = BuildRuntimeContext()
    UpdateOneSlot(context, false, true)
    UpdateOneSlot(context, true, true)
    ProfStop(_ps)
end

-- =========================================================
-- SECTION 5: 刷新调度与运行时事件
-- =========================================================

rb.RefreshAll = RefreshAll

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
        RefreshAll()
    end
end

local function TickResourceBars(frame, elapsed)
    ProfCount("RB:TickResourceBars")
    local d = GetDb()
    if not d or not primaryHost then
        return
    end
    local priOff = d.primaryBar.enabled == false
    local secOff = not d.secondaryBar or d.secondaryBar.enabled == false
    if priOff and secOff then
        return
    end
    local secCfg = d.secondaryBar or {}
    local fast = (d.primaryBar.fasterUpdates == nil or d.primaryBar.fasterUpdates == true)
        or (secCfg.fasterUpdates == nil or secCfg.fasterUpdates == true)
    local interval = fast and 0.1 or 0.25
    frame._vf_tickAcc = (frame._vf_tickAcc or 0) + elapsed
    if frame._vf_tickAcc < interval then
        return
    end
    frame._vf_tickAcc = 0
    RefreshValuesOnly()
end

local function HandleRuntimeEvent(event)
    ProfCount("RB:HandleRuntimeEvent")
    if event == "UNIT_MAXPOWER" or event == "UNIT_POWER_UPDATE"
        or event == "UNIT_AURA" or event == "RUNE_POWER_UPDATE" then
        RefreshValuesOnly()
        return
    end
    RefreshAll()
end

local function RegisterRuntimeEvents()
    if runtimeEventsRegistered then
        return
    end
    runtimeEventsRegistered = true
    VFlow.on("PLAYER_SPECIALIZATION_CHANGED", EVENT_OWNER, HandleRuntimeEvent, "player")
    VFlow.on("PLAYER_REGEN_ENABLED", EVENT_OWNER, HandleRuntimeEvent)
    VFlow.on("PLAYER_REGEN_DISABLED", EVENT_OWNER, HandleRuntimeEvent)
    VFlow.on("UNIT_MAXPOWER", EVENT_OWNER, HandleRuntimeEvent, "player")
    VFlow.on("UNIT_POWER_UPDATE", EVENT_OWNER, HandleRuntimeEvent, "player")
    VFlow.on("UNIT_AURA", EVENT_OWNER, HandleRuntimeEvent, "player")
    if E_PT and E_PT.Runes then
        VFlow.on("RUNE_POWER_UPDATE", EVENT_OWNER, HandleRuntimeEvent)
    end
    if select(2, UnitClass("player")) == "DRUID" then
        VFlow.on("UPDATE_SHAPESHIFT_FORM", EVENT_OWNER, HandleRuntimeEvent)
    end
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
    local _ps = ProfStart("RB:EnsureFrames")
    if primaryHost and secondaryHost and tickFrame then
        ProfStop(_ps)
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

    if not tickFrame then
        tickFrame = CreateFrame("Frame", nil, UIParent)
        tickFrame._vf_tickAcc = 0
        tickFrame:SetScript("OnUpdate", TickResourceBars)
    end
    ProfStop(_ps)
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
    local _ps = ProfStart("RB:OnModuleReady")
    if initialized then
        if RS and RS.WipeRuntimeCaches then
            RS.WipeRuntimeCaches(GetDb())
        end
        RefreshAll()
        ProfStop(_ps)
        return
    end
    if not VFlow.getDBIfReady(MODULE_KEY) then
        ProfStop(_ps)
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
        VFlow.Store.watch(MODULE_KEY, "Core.ResourceBars", function()
            local d = GetDb()
            if not d then return end
            if RS and RS.WipeRuntimeCaches then
                RS.WipeRuntimeCaches(d)
            end
            RefreshAll()
            RegisterDrag()
        end)
    end

    initialized = true
    ProfStop(_ps)
end

VFlow.ResourceBars = rb

VFlow.on("PLAYER_ENTERING_WORLD", "ResourceBars.Boot", function()
    if VFlow.ResourceBars and VFlow.ResourceBars.OnModuleReady then
        VFlow.ResourceBars.OnModuleReady()
    end
end)

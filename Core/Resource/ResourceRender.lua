-- =========================================================
-- ResourceRender — 资源条渲染工具：帧创建、分段渲染、文字、颜色
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.RESOURCES_ENABLED then return end

local FD = VFlow.FD
local RS = VFlow.ResourceStyles
local BFK = VFlow.BarFrameKit
local PP = VFlow.PixelPerfect
local E_PT = _G.Enum and Enum.PowerType

-- =========================================================
-- SECTION 1: 共享状态与基础工具
-- =========================================================

local RR = {}

--- 符文快照，由 ResourceBars 写入，BuildRuneSegmentState 读取
RR.runeCooldownSnapshot = {}
for i = 1, 6 do
    RR.runeCooldownSnapshot[i] = { start = 0, duration = 0, runeReady = false }
end

--- 醉酿百分比，由 ResourceBars 写入，FormatText 读取
RR.lastStaggerPercent = 60

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

RR.IsSecretValue = IsSecretValue
RR.IsSecretNumber = IsSecretNumber
RR.IsPositivePlainNumber = IsPositivePlainNumber

-- =========================================================
-- SECTION 2: 缓存渲染原语
-- =========================================================

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
        tostring(r), tostring(g), tostring(b), tostring(a),
    }, "\031"), r, g, b, a
end

RR.BuildColorSignature = BuildColorSignature

function RR.SetShownIfChanged(region, wantShown)
    if not region then return end
    if region:IsShown() ~= wantShown then
        region:SetShown(wantShown)
    end
end

function RR.SetTextIfChanged(fs, text)
    if not fs then return end
    local fd = FD(fs)
    if IsSecretValue(text) or IsSecretValue(fd.textValue) then
        fs:SetText(text)
        fd.textValue = nil
        return
    end
    if fd.textValue ~= text then
        fs:SetText(text)
        fd.textValue = text
    end
end

function RR.ApplyStatusBarColorCached(sb, color, defaultR, defaultG, defaultB, defaultA)
    if not sb then return end
    local colorSig, r, g, b, a = BuildColorSignature(color, defaultR or 1, defaultG or 1, defaultB or 1, defaultA or 1)
    if colorSig and FD(sb).fillColorSig == colorSig then return end
    sb:SetStatusBarColor(r, g, b, a)
    FD(sb).fillColorSig = colorSig
end

function RR.ApplyBarProgressCached(sb, minValue, maxValue, value, useSmooth)
    if not sb then return end
    local canCache = not IsSecretNumber(minValue) and not IsSecretNumber(maxValue) and not IsSecretNumber(value)
    local smoothFlag = useSmooth == true
    local fd = FD(sb)
    if canCache
        and fd.progMin == minValue
        and fd.progMax == maxValue
        and fd.progValue == value
        and fd.progSmooth == smoothFlag then
        return
    end
    if minValue == 0 and BFK and BFK.ApplyBarProgress then
        BFK.ApplyBarProgress(sb, maxValue, value, useSmooth)
    else
        sb:SetMinMaxValues(minValue, maxValue)
        sb:SetValue(value)
    end
    if canCache then
        fd.progMin = minValue
        fd.progMax = maxValue
        fd.progValue = value
        fd.progSmooth = smoothFlag
    else
        fd.progMin = nil
        fd.progMax = nil
        fd.progValue = nil
        fd.progSmooth = nil
    end
end

-- =========================================================
-- SECTION 3: 字体与文字
-- =========================================================

local function OutlineToken(outline)
    if outline == "THICKOUTLINE" then return "THICKOUTLINE" end
    if outline == "MONOCHROMEOUTLINE" then return "OUTLINE,MONOCHROME" end
    if outline == "OUTLINE" then return "OUTLINE" end
    return ""
end

function RR.ApplyTextFont(fs, tf)
    if not fs or not tf then return end
    local fd = FD(fs)
    local sz = tonumber(tf.size) or 12
    local fontSig = table.concat({
        tostring(tf.font), tostring(sz), tostring(tf.outline or ""),
    }, "\031")
    if fd.fontSig ~= fontSig then
        local applyFont = VFlow.UI and VFlow.UI.applyFont
        if applyFont then
            applyFont(fs, tf.font, sz, OutlineToken(tf.outline))
        end
        fd.fontSig = fontSig
    end
    local colorSig, r, g, b, a = BuildColorSignature(tf.color, 1, 1, 1, 1)
    if not colorSig or fd.colorSig ~= colorSig then
        fs:SetTextColor(r, g, b, a)
        fd.colorSig = colorSig
    end
    local position = tf.position or "CENTER"
    if position == "TOP" then position = "BOTTOM"
    elseif position == "TOPLEFT" then position = "BOTTOMLEFT"
    elseif position == "TOPRIGHT" then position = "BOTTOMRIGHT"
    elseif position == "BOTTOM" then position = "TOP"
    elseif position == "BOTTOMLEFT" then position = "TOPLEFT"
    elseif position == "BOTTOMRIGHT" then position = "TOPRIGHT"
    end
    local pointSig = table.concat({
        tostring(position), tostring(tf.offsetX or 0), tostring(tf.offsetY or 0),
    }, "\031")
    if fd.pointSig ~= pointSig then
        fs:ClearAllPoints()
        fs:SetPoint(position, fs:GetParent(), position, tf.offsetX or 0, tf.offsetY or 0)
        fd.pointSig = pointSig
    end
end

local function AbbreviateSafe(n)
    if n == nil then return "" end
    if AbbreviateNumbers then
        local ok, s = pcall(function()
            return string.format("%s", AbbreviateNumbers(n))
        end)
        if ok then return s end
    end
    if not IsSecretNumber(n) then
        local t = tonumber(n)
        if t then return string.format("%d", math.floor(t)) end
    end
    return ""
end

local function PowerPercentSafe(resource)
    if type(resource) ~= "number" or not UnitPowerPercent then return nil end
    local curve = _G.CurveConstants and CurveConstants.ScaleTo100 or 2
    local ok, pct = pcall(UnitPowerPercent, "player", resource, true, curve)
    if ok and type(pct) == "number" then return pct end
    return nil
end

function RR.FormatText(style, max, cur, resource)
    if not style or style.showText == false then return "" end
    if style.showPercent then
        if resource == "STAGGER" then
            return string.format("%.0f", RR.lastStaggerPercent or 0)
        end
        if type(resource) == "number" and issecretvalue and (issecretvalue(max) or issecretvalue(cur)) then
            local pct = PowerPercentSafe(resource)
            if pct then return string.format("%.0f", pct) end
            return ""
        end
        if max and not IsSecretNumber(max) and not IsSecretNumber(cur) and max > 0 then
            return string.format("%.0f", (cur / max) * 100)
        end
        if type(resource) == "number" then
            local pct = PowerPercentSafe(resource)
            if pct then return string.format("%.0f", pct) end
        end
        return ""
    end
    local curStr = AbbreviateSafe(cur)
    local cmpOk, nonEmpty = pcall(function() return curStr ~= "" end)
    if not cmpOk then return curStr end
    if nonEmpty then return curStr end
    return ""
end

-- =========================================================
-- SECTION 4: 条填充色
-- =========================================================

local function ResolveBarTierFillColor(resource, style, cur, max)
    return RS.TryResolveBarFillFromPowerPercent(resource, style) or RS.ResolveBarFillColor(style, cur, max, resource)
end

RR.ResolveBarTierFillColor = ResolveBarTierFillColor

function RR.ApplyMainBarFillColor(sb, resource, style, cur, max)
    if not sb then return end
    local c = style and ResolveBarTierFillColor(resource, style, cur, max) or nil
    if not c then
        local fallback = RS and RS.ResolveStyle(nil, resource) or nil
        c = fallback and fallback.barColor or nil
    end
    if not c then return end
    local colorSig, r, g, b, a = BuildColorSignature(c, 1, 1, 1, 1)
    if colorSig and FD(sb).fillColorSig == colorSig then return end
    local tex = sb.GetStatusBarTexture and sb:GetStatusBarTexture()
    if tex then
        tex:SetVertexColor(r, g, b, a)
        FD(sb).fillColorSig = colorSig
        return
    end
    RR.ApplyStatusBarColorCached(sb, c, 1, 1, 1, 1)
end

function RR.ApplyBarBackground(host, db)
    if not host or not db or not FD(host).bg then return end
    local c = db.resourceBarBackground
    local colorSig, r, g, b, a = BuildColorSignature(c, 0, 0, 0, 0.5)
    if colorSig and FD(host).bgColorSig == colorSig then return end
    FD(host).bg:SetColorTexture(r, g, b, a)
    FD(host).bgColorSig = colorSig
end

-- =========================================================
-- SECTION 5: 精华充能时钟
-- =========================================================

function RR.SyncEssenceRechargeClock(host, cur, max)
    if not host or IsSecretNumber(cur) or IsSecretNumber(max) then return end
    local c = math.floor(tonumber(cur) or 0)
    local m = math.floor(tonumber(max) or 0)
    if m <= 0 then return end
    local fd = FD(host)
    local prev = fd.essencePrevCur
    if prev ~= c then
        fd.essencePrevCur = c
        if c < m then
            fd.essenceRechargeStart = GetTime()
        else
            fd.essenceRechargeStart = nil
        end
    end
    if c < m and not fd.essenceRechargeStart then
        fd.essenceRechargeStart = GetTime()
    end
    if c >= m then
        fd.essenceRechargeStart = nil
    end
end

local function GetEssencePipFill(host, gameSlot, curInt, maxInt)
    if gameSlot <= curInt then return 1 end
    if gameSlot == curInt + 1 and curInt < maxInt then
        local rate = GetPowerRegenForPowerType(Enum.PowerType.Essence)
        local fd = FD(host)
        if type(rate) == "number" and not IsSecretNumber(rate) and rate > 0 then
            fd.essenceLastRate = rate
        else
            rate = fd.essenceLastRate or 0.2
        end
        local rechargeTime = 1 / rate
        local now = GetTime()
        local start = fd.essenceRechargeStart or now
        local elapsed = now - start
        local p = rechargeTime > 0 and (elapsed / rechargeTime) or 0
        if p < 0 then p = 0 end
        if p > 1 then p = 1 end
        return p
    end
    return 0
end

-- =========================================================
-- SECTION 6: 符文分段状态
-- =========================================================

local runeCdInfoPool = {}
for i = 1, 6 do
    runeCdInfoPool[i] = { index = 0, remaining = 0, frac = 0 }
end
local runeReadyScratch = {}
local runeCdScratch = {}
local runeOrderScratch = {}
local runeFillScratch = {}

--- 就绪符文优先，冷却中按剩余时间排序
local function BuildRuneSegmentState(maxRunes)
    local snapshot = RR.runeCooldownSnapshot
    local readyList = runeReadyScratch
    for ri = #readyList, 1, -1 do readyList[ri] = nil end
    local cdList = runeCdScratch
    for ci = #cdList, 1, -1 do cdList[ci] = nil end
    local now = GetTime()
    local poolIdx = 1
    for i = 1, maxRunes do
        local cached = snapshot[i]
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
    table.sort(cdList, function(a, b) return a.remaining < b.remaining end)
    local order = runeOrderScratch
    local fillByIndex = runeFillScratch
    for fi = 1, maxRunes do fillByIndex[fi] = nil end
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

-- =========================================================
-- SECTION 7: 离散分段计算
-- =========================================================

local function RuntimeUsesSegmentRechargeColors(resource)
    if not E_PT then
        return RS.RuntimeUsesEssenceRechargeTicker(resource)
    end
    return RS.RuntimeUsesEssenceRechargeTicker(resource)
        or resource == E_PT.Runes
        or resource == E_PT.SoulShards
end

local function PipCellFillAmount(cur, pipIndex)
    if cur == nil or pipIndex < 1 then return 0 end
    if IsSecretNumber(cur) then return 0 end
    local c = tonumber(cur)
    if not c then return 0 end
    return math.min(1, math.max(0, c - (pipIndex - 1)))
end

local function RuntimeUsesOverchargedComboPointColor(resource)
    return type(resource) == "number" and E_PT and resource == E_PT.ComboPoints
end

local function BuildChargedComboPointLookup(host, resource)
    if not RuntimeUsesOverchargedComboPointColor(resource) or not GetUnitChargedPowerPoints then
        if host then
            local fd = FD(host)
            fd.chargedLookup = nil
            fd.chargedLookupSig = nil
        end
        return nil
    end
    local points = GetUnitChargedPowerPoints("player") or {}
    local signature = (#points > 0) and table.concat(points, ",") or ""
    local fd = FD(host)
    if host and fd.chargedLookupSig == signature then
        return fd.chargedLookup
    end
    local lookup = (host and fd.chargedLookup) or {}
    wipe(lookup)
    for _, pointIndex in ipairs(points) do
        lookup[pointIndex] = true
    end
    lookup = next(lookup) and lookup or nil
    if host then
        fd.chargedLookup = lookup
        fd.chargedLookupSig = signature
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
        if not runeIdx then return 0 end
        return runeFill[runeIdx] or 0
    end
    return PipCellFillAmount(cur, gameSlot)
end

--- 双态分段：满/就绪色与充能中色
local function SetDualColorForDiscreteSeg(segSb, resource, fill, gameSlot, cur, curIntEssence, rechargeCol, readyCol)
    if not rechargeCol or not readyCol then return false end
    if RS.RuntimeUsesEssenceRechargeTicker(resource) and curIntEssence then
        if gameSlot <= curIntEssence then
            RR.ApplyStatusBarColorCached(segSb, readyCol, 1, 1, 1, 1)
        else
            RR.ApplyStatusBarColorCached(segSb, rechargeCol, 1, 1, 1, 1)
        end
        return true
    end
    if resource == E_PT.Runes then
        if fill >= 1 - 1e-6 then
            RR.ApplyStatusBarColorCached(segSb, readyCol, 1, 1, 1, 1)
        else
            RR.ApplyStatusBarColorCached(segSb, rechargeCol, 1, 1, 1, 1)
        end
        return true
    end
    if resource == E_PT.SoulShards then
        local c = tonumber(cur) or 0
        local w = math.floor(c)
        if gameSlot <= w then
            RR.ApplyStatusBarColorCached(segSb, readyCol, 1, 1, 1, 1)
        else
            RR.ApplyStatusBarColorCached(segSb, rechargeCol, 1, 1, 1, 1)
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
    ["WHIRLWIND"] = true,
    ["ICICLES"] = true,
    ["TIP_OF_THE_SPEAR"] = true,
    ["SOUL_FRAGMENTS_VENGEANCE"] = true,
    ["MAELSTROM_WEAPON"] = true,
} or {}

local function UsesDiscreteSegments(resource)
    return resource and DISCRETE_SEGMENT_RESOURCES[resource] == true
end

local function CurTooOpaqueForDiscretePips(cur, resource)
    if resource == "SOUL_FRAGMENTS_VENGEANCE" then return false end
    return cur ~= nil and IsSecretNumber(cur)
end

-- =========================================================
-- SECTION 8: 分段帧管理
-- =========================================================

local function EnsureSegContainer(host)
    local fd = FD(host)
    if fd.segContainer then return fd.segContainer end
    local c = CreateFrame("Frame", nil, host)
    c:SetFrameLevel((host:GetFrameLevel() or 0) + 1)
    c:SetAllPoints()
    c:EnableMouse(false)
    fd.segContainer = c
    fd.segFrames = {}
    return c
end

local function GetOrCreateSegFrame(host, index)
    local fd = FD(host)
    fd.segFrames = fd.segFrames or {}
    local seg = fd.segFrames[index]
    if seg then return seg end
    seg = CreateFrame("Frame", nil, fd.segContainer)
    local base = (fd.segContainer:GetFrameLevel() or 0)
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
    fd.segFrames[index] = seg
    return seg
end

function RR.ClearSegmentUI(host)
    if not host then return end
    local fd = FD(host)
    if fd.rechargeTicker then
        fd.rechargeTicker:Cancel()
        fd.rechargeTicker = nil
    end
    fd.segmentMode = false
    fd.segLastMax = nil
    fd.segLastResource = nil
    if fd.segContainer then fd.segContainer:Hide() end
    if fd.segFrames then
        for _, f in ipairs(fd.segFrames) do
            if f then f:Hide() end
        end
    end
    if fd.sb then fd.sb:Show() end
    fd.lastValueResource = nil
    fd.lastValueMax = nil
    fd.lastValueCur = nil
    fd.lastValueShowText = nil
    if fd.borderFrame and PP and PP.ShowBorder then
        PP.ShowBorder(fd.borderFrame)
    end
end

-- =========================================================
-- SECTION 9: 离散分段整体渲染
-- =========================================================

--- @param skipLayout boolean|nil
function RR.UpdateDiscreteSegmentDisplay(host, cfg, db, resource, max, cur, style, skipLayout)
    local fd = FD(host)
    local sb = fd.sb
    local borderFrame = fd.borderFrame
    if not host or not cfg or not db or not sb or not borderFrame or not BFK or not PP then
        return false
    end

    local wantSeg = UsesDiscreteSegments(resource) and type(max) == "number" and max >= 2 and not CurTooOpaqueForDiscretePips(cur, resource)
    if not wantSeg then
        RR.ClearSegmentUI(host)
        return false
    end

    if fd.segLastMax ~= max or fd.segLastResource ~= resource then
        skipLayout = false
    end

    local fullLayout = (not skipLayout) or (not fd.segmentMode)
    fd.segLastMax = max
    fd.segLastResource = resource

    --- 内部：为每个分段应用样式并显示
    local function ApplySegments(isFullLayout)
        local curInt = (not IsSecretNumber(cur)) and math.floor(tonumber(cur) or 0) or nil
        local maxInt = (not IsSecretNumber(max)) and math.floor(tonumber(max) or 0) or nil
        if RS.RuntimeUsesEssenceRechargeTicker(resource) and curInt and maxInt then
            RR.SyncEssenceRechargeClock(host, cur, max)
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
            local segFrame = fd.segFrames and fd.segFrames[pos]
            if not segFrame then break end
            local segSb = segFrame._sb
            if not segSb then break end

            -- 全量布局时设置材质/方向
            if isFullLayout then
                local dir = cfg.barDirection or "horizontal"
                local texPath = BFK.ResolveBarTexture(cfg.barTexture)
                local chromeSig = table.concat({ tostring(texPath), tostring(dir) }, "\031")
                if FD(segSb).chromeSig ~= chromeSig then
                    segSb:SetStatusBarTexture(texPath)
                    FD(segSb).fillColorSig = nil
                    BFK.ConfigureStatusBar(segSb)
                    BFK.SetOrientation(segSb, dir)
                    BFK.SetReverseFill(segSb, false)
                    FD(segSb).chromeSig = chromeSig
                end
                BFK.ApplySegmentCellBorder(segFrame._border, cfg)
            end

            local gameSlot = reverse and (max - pos + 1) or pos
            local fill = (not isSecret) and ComputeDiscretePipFill(resource, host, gameSlot, cur, max, runeOrder, runeFill) or 0
            local isCharged = chargedLookup and chargedLookup[gameSlot] and chargedColor
            segFrame._bg:SetColorTexture(0, 0, 0, 0)
            local didDual = false

            if useOverchargedCombo then
                if isCharged then
                    RR.ApplyBarProgressCached(segSb, 0, 1, 1, useSmoothSeg)
                    if gameSlot <= comboCurrent then
                        RR.ApplyStatusBarColorCached(segSb, chargedColor, 1, 1, 1, 1)
                    else
                        RR.ApplyStatusBarColorCached(segSb, dimChargedColor, 1, 1, 1, 1)
                    end
                elseif gameSlot <= comboCurrent then
                    RR.ApplyBarProgressCached(segSb, 0, 1, 1, useSmoothSeg)
                    RR.ApplyStatusBarColorCached(segSb, fillCol, 1, 1, 1, 1)
                else
                    RR.ApplyBarProgressCached(segSb, 0, 1, 0, useSmoothSeg)
                    RR.ApplyStatusBarColorCached(segSb, dimFillCol, 1, 1, 1, 1)
                end
            elseif isSecret then
                RR.ApplyBarProgressCached(segSb, gameSlot - 1, gameSlot, cur, false)
                RR.ApplyStatusBarColorCached(segSb, fillCol, 1, 1, 1, 1)
            elseif useDual then
                didDual = SetDualColorForDiscreteSeg(segSb, resource, fill, gameSlot, cur, curInt, rechargeCol, readyCol)
            end
            if not didDual and not isSecret then
                if not isCharged and not useOverchargedCombo then
                    RR.ApplyBarProgressCached(segSb, 0, 1, fill, useSmoothSeg)
                    RR.ApplyMainBarFillColor(segSb, resource, style, cur, max)
                end
            elseif not isSecret then
                RR.ApplyBarProgressCached(segSb, 0, 1, fill, useSmoothSeg)
            end

            if isFullLayout then segFrame:Show() end
        end

        -- 隐藏多余分段
        if isFullLayout then
            for i = max + 1, #(fd.segFrames or {}) do
                local f = fd.segFrames[i]
                if f then f:Hide() end
            end
        end
    end

    if fullLayout then
        sb:Hide()
        PP.HideBorder(borderFrame)
        local container = EnsureSegContainer(host)
        container:Show()
        fd.segmentMode = true
        local totalW = host:GetWidth()
        local totalH = host:GetHeight()
        if totalW <= 0 or totalH <= 0 then return true end
        local dir = cfg.barDirection or "horizontal"
        for pos = 1, max do GetOrCreateSegFrame(host, pos) end
        BFK.LayoutDiscreteBarSegmentFrames(container, cfg, max, dir, fd.segFrames, host)
        ApplySegments(true)
        return true
    end

    if not fd.segmentMode then return false end
    ApplySegments(false)
    return true
end

-- =========================================================
-- SECTION 10: 帧创建辅助
-- =========================================================

function RR.EnsureBarLabel(host, existingFs)
    if not host then return existingFs end
    local fd = FD(host)
    local holder = fd.textHolder
    if not holder then
        holder = CreateFrame("Frame", nil, host)
        holder:SetAllPoints(host)
        holder:SetFrameLevel((host:GetFrameLevel() or 0) + 10)
        holder:EnableMouse(false)
        fd.textHolder = holder
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

function RR.BarUsesSmooth(cfg)
    return cfg and (cfg.smoothProgress == nil or cfg.smoothProgress == true)
end

-- =========================================================

VFlow._RR = RR

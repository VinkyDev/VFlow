-- CustomMonitorBar - 条形帧创建、样式基础设施、技能冷却渲染
-- 导出 VFlow.CustomMonitorBar 供 Ring/Runtime 消费

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.CustomMonitor"
local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CUSTOM_ENABLED then return end

local FD = VFlow.FD
local PP = VFlow.PixelPerfect
local BFK = VFlow.BarFrameKit

-- =========================================================
-- SECTION 1: 常量
-- =========================================================

local RING_TEXTURE_FMT = "Interface\\AddOns\\VFlow\\Assets\\Ring\\Ring_%spx.tga"
local INTERP_EASE_OUT = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut or 1

-- =========================================================
-- SECTION 2: 字体辅助
-- =========================================================

local function ResolveFontFlags(outline)
    if outline == "OUTLINE" or outline == "THICKOUTLINE" then return outline end
    if outline == "MONOCHROMEOUTLINE" then return "OUTLINE,MONOCHROME" end
    return ""
end

local function ApplyConfiguredFont(fs, tf)
    if not fs then return end
    local fontSize = tf and tf.size or 14
    local fontFlags = ResolveFontFlags(tf and tf.outline)
    local applyFont = VFlow.UI and VFlow.UI.applyFont
    if applyFont then applyFont(fs, tf and tf.font, fontSize, fontFlags) end
    if tf and tf.outline == "SHADOW" then
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
    else
        fs:SetShadowColor(0, 0, 0, 0)
        fs:SetShadowOffset(0, 0)
    end
end

-- =========================================================
-- SECTION 3: 通用工具
-- =========================================================

local function HasAuraInstanceID(value)
    if value == nil then return false end
    if issecretvalue and issecretvalue(value) then return true end
    if type(value) == "number" and value == 0 then return false end
    return true
end

-- CDM 偶发把整份 AuraData 挂在 auraInstanceID 上；C_UnitAuras 只要数值 ID
local function AuraInstanceIDForAPI(v)
    if type(v) == "table" and v.auraInstanceID ~= nil then return v.auraInstanceID end
    return v
end

--- 含 secret 时 format 受限，pcall 回退
local function SetRemainingText(text, durObj)
    local remaining
    pcall(function() remaining = durObj:GetRemainingDuration() end)
    if remaining == nil then text:SetText(""); return end
    local ok1 = pcall(function() text:SetFormattedText("%.1f", remaining) end)
    if ok1 then return end
    local ok2 = pcall(function() text:SetText(remaining) end)
    if not ok2 then text:SetText("") end
end

local function FillDirection(fillMode)
    if fillMode == "fill" then
        return Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.RemainingTime or 1
    end
    return Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.ElapsedTime or 0
end

local function ApplyTimerDuration(seg, durObj, interpolation, direction)
    if not (durObj and seg.SetTimerDuration) then return false end
    seg:SetMinMaxValues(0, 1)
    seg:SetTimerDuration(durObj, interpolation, direction)
    if seg.SetToTargetValue then seg:SetToTargetValue() end
    return true
end

local function SetBarTickState(barFrame, mode)
    if not barFrame then return end
    barFrame._tickMode = mode
end

-- =========================================================
-- SECTION 4: 签名与缓存键
-- =========================================================

local function colKey(c)
    if not c then return "-" end
    return table.concat({ tostring(c.r), tostring(c.g), tostring(c.b), tostring(c.a) }, ";")
end

local function ShouldRenderGraphics(cfg)
    return cfg and cfg.showGraphics ~= false
end

local function ShouldRenderText(cfg)
    return cfg and cfg.showText ~= false
end

local function timerFontKey(cfg)
    local t = cfg.timerFont or {}
    local fc = t.color or {}
    return table.concat({
        tostring(t.font or ""), tostring(t.size or 0), tostring(t.outline or ""),
        tostring(t.position or "CENTER"), tostring(t.offsetX or 0), tostring(t.offsetY or 0),
        colKey(fc),
    }, "\031")
end

local function innerBarSignature(cfg)
    return table.concat({
        tostring(cfg.shape or "bar"),
        tostring(cfg.showGraphics ~= false),
        tostring(cfg.showText ~= false),
        colKey(cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }),
        tostring(cfg.showGraphics ~= false and cfg.showIcon ~= false),
        tostring(cfg.iconSize or 20),
        tostring(cfg.iconPosition or "LEFT"),
        tostring(cfg.iconOffsetX or 0),
        tostring(cfg.iconOffsetY or 0),
        timerFontKey(cfg),
    }, "\031")
end

local function segmentLayoutSignature(cfg, barFrame)
    local storeKey = barFrame._storeKey or "skills"
    local shape = cfg.shape or "bar"
    local mon = (storeKey == "buffs") and (barFrame._monitorType or cfg.monitorType or "duration") or ""
    local bt = (BFK and BFK.ParseBorderThickness and BFK.ParseBorderThickness(cfg.borderThickness))
        or tonumber(cfg.borderThickness) or 1
    return table.concat({
        shape, storeKey, mon,
        tostring(cfg.showGraphics ~= false),
        tostring(tonumber(cfg.maxStacks) or 5),
        tostring(tonumber(cfg.segmentGap) or 0),
        cfg.barDirection or "horizontal",
        tostring(cfg.barReverse == true),
        tostring(cfg.barTexture or ""),
        tostring(tonumber(cfg.stackThreshold1) or 0),
        tostring(tonumber(cfg.stackThreshold2) or 0),
        colKey(cfg.stackColor1), colKey(cfg.stackColor2), colKey(cfg.barColor), colKey(cfg.bgColor),
        tostring(cfg.ringTexture or ""),
        colKey(cfg.ringColor or { r = 0.2, g = 0.6, b = 1, a = 1 }),
        tostring(cfg.ringThickness or 0),
        tostring(cfg.barFillMode or ""),
        tostring(bt), colKey(cfg.borderColor),
        storeKey == "skills" and tostring(cfg.isChargeSpell == true) or "",
        tostring(cfg.ringSize or 0),
    }, "\031")
end

-- =========================================================
-- SECTION 5: 分段管理
-- =========================================================

local function ClearSegments(barFrame)
    if barFrame._segments then
        for _, seg in ipairs(barFrame._segments) do seg:Hide(); seg:SetParent(nil) end
    end
    if barFrame._segBGs then
        for _, bg in ipairs(barFrame._segBGs) do bg:Hide(); bg:SetParent(nil) end
    end
    if barFrame._thresholdOverlays then
        for _, ov in ipairs(barFrame._thresholdOverlays) do ov:Hide(); ov:SetParent(nil) end
    end
    if barFrame._segFrames then
        for _, frame in ipairs(barFrame._segFrames) do frame:Hide(); frame:SetParent(nil) end
    end
    barFrame._segments          = {}
    barFrame._segBGs            = {}
    barFrame._thresholdOverlays = {}
    barFrame._segFrames         = {}
end

local function CreateSegments(barFrame, count, cfg, isStack, isRing)
    ClearSegments(barFrame)
    if not ShouldRenderGraphics(cfg) then
        barFrame._segSig = segmentLayoutSignature(cfg, barFrame)
        barFrame._segsDirty = false
        barFrame._segsNeedCount = nil
        return
    end
    if count < 1 then return end

    local segContainer = barFrame._segContainer
    local totalW, totalH = segContainer:GetSize()
    if totalW <= 0 then
        barFrame._segsDirty     = true
        barFrame._segsNeedCount = count
        return
    end

    -- 环形模式
    if isRing then
        local ringTexture = cfg.ringTexture or "10"
        local ringTex = string.format(RING_TEXTURE_FMT, ringTexture)
        local rc = cfg.ringColor or { r = 0.2, g = 0.6, b = 1, a = 1 }

        local bg = segContainer:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(ringTex)
        local bgc = cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }
        bg:SetVertexColor(bgc.r, bgc.g, bgc.b, bgc.a)
        bg:Show()
        barFrame._segBGs[1] = bg

        -- 隐藏条形背景
        local bgTexRegion = barFrame.GetRegions and select(1, barFrame:GetRegions())
        if bgTexRegion and bgTexRegion.SetColorTexture then
            bgTexRegion:SetColorTexture(0, 0, 0, 0)
        end

        -- CooldownFrame 作为环形进度
        local cd = CreateFrame("Cooldown", nil, segContainer, "CooldownFrameTemplate")
        cd:SetAllPoints()
        cd:SetDrawEdge(false)
        cd:SetDrawBling(false)
        cd:SetSwipeTexture(ringTex)
        cd:SetSwipeColor(rc.r, rc.g, rc.b, rc.a)
        cd:SetReverse(false)
        cd:SetHideCountdownNumbers(true)
        cd:SetUseCircularEdge(false)
        cd:EnableMouse(false)
        cd:Show()
        cd._isRing = true
        cd._needsRefresh = true
        barFrame._segments[1] = cd

        barFrame._segSig = segmentLayoutSignature(cfg, barFrame)
        barFrame._segsDirty = false
        barFrame._segsNeedCount = nil
        return
    end

    -- 条形模式
    local dir = cfg.barDirection or "horizontal"
    local barReverse = cfg.barReverse == true
    local tex = BFK and BFK.ResolveBarTexture(cfg.barTexture) or "Interface\\Buttons\\WHITE8X8"
    local bc  = cfg.barColor or { r = 0.2, g = 0.6, b = 1, a = 1 }
    local t1 = isStack and (tonumber(cfg.stackThreshold1) or 0) or 0
    local t2 = isStack and (tonumber(cfg.stackThreshold2) or 0) or 0
    local c1 = cfg.stackColor1 or { r = 1, g = 0.5, b = 0, a = 1 }
    local c2 = cfg.stackColor2 or { r = 1, g = 0,   b = 0, a = 1 }
    local baseLevel = segContainer:GetFrameLevel()

    for i = 1, count do
        local segFrame = CreateFrame("Frame", nil, segContainer)
        segFrame:SetFrameLevel(baseLevel)

        local bgTex = segFrame:CreateTexture(nil, "BACKGROUND")
        local bgc = cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }
        bgTex:SetColorTexture(bgc.r, bgc.g, bgc.b, bgc.a)
        bgTex:SetAllPoints(segFrame)

        local seg = CreateFrame("StatusBar", nil, segFrame)
        seg:SetStatusBarTexture(tex)
        seg:SetStatusBarColor(bc.r, bc.g, bc.b, bc.a)
        seg:SetValue(0)
        seg:EnableMouse(false)
        seg:SetFrameLevel(baseLevel + 1)
        seg:SetAllPoints(segFrame)
        if BFK then
            BFK.ConfigureStatusBar(seg)
            BFK.SetOrientation(seg, dir)
            BFK.SetReverseFill(seg, barReverse)
        end

        if isStack then
            seg:SetMinMaxValues(i - 1, i)
            if dir == "vertical" and seg.SetFillStyle then
                seg:SetFillStyle(Enum.StatusBarFillStyle.Standard)
            end
        else
            seg:SetMinMaxValues(0, 1)
        end

        barFrame._segBGs[i]   = bgTex
        barFrame._segments[i] = seg
        barFrame._segFrames = barFrame._segFrames or {}
        barFrame._segFrames[i] = segFrame

        if isStack then
            if t1 > 0 then
                local ov1 = CreateFrame("StatusBar", nil, segFrame)
                ov1:SetAllPoints(segFrame)
                ov1:SetStatusBarTexture(tex)
                ov1:SetStatusBarColor(c1.r, c1.g, c1.b, c1.a)
                ov1:SetValue(0)
                ov1:EnableMouse(false)
                ov1:SetFrameLevel(baseLevel + 2)
                ov1:SetMinMaxValues((i < t1) and (t1 - 1) or (i - 1), (i < t1) and t1 or i)
                if BFK then
                    BFK.ConfigureStatusBar(ov1)
                    BFK.SetOrientation(ov1, dir)
                    BFK.SetReverseFill(ov1, barReverse)
                end
                table.insert(barFrame._thresholdOverlays, ov1)
            end
            if t2 > 0 then
                local ov2 = CreateFrame("StatusBar", nil, segFrame)
                ov2:SetAllPoints(segFrame)
                ov2:SetStatusBarTexture(tex)
                ov2:SetStatusBarColor(c2.r, c2.g, c2.b, c2.a)
                ov2:SetValue(0)
                ov2:EnableMouse(false)
                ov2:SetFrameLevel(baseLevel + 3)
                ov2:SetMinMaxValues((i < t2) and (t2 - 1) or (i - 1), (i < t2) and t2 or i)
                if BFK then
                    BFK.ConfigureStatusBar(ov2)
                    BFK.SetOrientation(ov2, dir)
                    BFK.SetReverseFill(ov2, barReverse)
                end
                table.insert(barFrame._thresholdOverlays, ov2)
            end
        end

        local borderFrame = CreateFrame("Frame", nil, segFrame)
        borderFrame:SetFrameLevel(baseLevel + 4)
        borderFrame:SetAllPoints(segFrame)
        borderFrame:EnableMouse(false)
        FD(segFrame).segmentBorder = borderFrame
    end

    if BFK and BFK.LayoutDiscreteBarSegmentFrames then
        BFK.LayoutDiscreteBarSegmentFrames(segContainer, cfg, count, dir, barFrame._segFrames or {}, segContainer)
    end
    if BFK and BFK.ApplySegmentCellBorder then
        for i = 1, count do
            local sf = barFrame._segFrames and barFrame._segFrames[i]
            if sf and FD(sf).segmentBorder then
                BFK.ApplySegmentCellBorder(FD(sf).segmentBorder, cfg)
            end
        end
    end

    barFrame._segSig        = segmentLayoutSignature(cfg, barFrame)
    barFrame._segsDirty     = false
    barFrame._segsNeedCount = nil
end

local function SetStackSegmentsValue(barFrame, value)
    for _, seg in ipairs(barFrame._segments) do seg:SetValue(value) end
    for _, ov  in ipairs(barFrame._thresholdOverlays) do ov:SetValue(value) end
end

local function BuildChargeSegmentMetrics(container, count, dir, segmentGap)
    if not container or count < 1 then return nil end
    local totalW = container:GetWidth()
    local totalH = container:GetHeight()
    if totalW <= 0 or totalH <= 0 then return nil end

    local ppScale = PP.GetPixelScale(container)
    local function ToPixel(v) return math.floor(v / ppScale + 0.5) end
    local function ToLogical(px) return px * ppScale end

    local pxTotalW = ToPixel(totalW)
    local pxTotalH = ToPixel(totalH)
    local pxGap = ToPixel(segmentGap)
    local metrics = {}

    if count == 1 then
        metrics[1] = { x = 0, y = 0, w = ToLogical(pxTotalW), h = ToLogical(pxTotalH) }
        return metrics
    end

    if dir == "vertical" then
        local pxAvailH = math.max(0, pxTotalH - (count - 1) * pxGap)
        local prevEdge = 0
        for i = 1, count do
            local edge = (i == count) and pxAvailH or math.floor(pxAvailH * i / count + 0.5)
            metrics[i] = {
                x = 0, y = ToLogical(prevEdge + (i - 1) * pxGap),
                w = ToLogical(pxTotalW), h = ToLogical(math.max(0, edge - prevEdge)),
            }
            prevEdge = edge
        end
    else
        local pxAvailW = math.max(0, pxTotalW - (count - 1) * pxGap)
        local prevEdge = 0
        for i = 1, count do
            local edge = (i == count) and pxAvailW or math.floor(pxAvailW * i / count + 0.5)
            metrics[i] = {
                x = ToLogical(prevEdge + (i - 1) * pxGap), y = 0,
                w = ToLogical(math.max(0, edge - prevEdge)), h = ToLogical(pxTotalH),
            }
            prevEdge = edge
        end
    end
    return metrics
end

-- =========================================================
-- SECTION 6: 帧创建
-- =========================================================

local function GetOrCreateShadowCooldown(barFrame)
    if barFrame._shadowCooldown then return barFrame._shadowCooldown end
    local cd = CreateFrame("Cooldown", nil, barFrame, "CooldownFrameTemplate")
    cd:SetAllPoints(barFrame)
    cd:SetDrawSwipe(false)
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)
    cd:SetHideCountdownNumbers(true)
    cd:SetAlpha(0)
    cd:EnableMouse(false)
    barFrame._shadowCooldown = cd
    return cd
end

local function CreateBarFrame(spellID, cfg, container)
    if container._bar then container._bar:Hide() end

    local showGraphics = ShouldRenderGraphics(cfg)
    local showText = ShouldRenderText(cfg)
    local barFrame = CreateFrame("Frame", nil, container)
    barFrame:SetAllPoints(container)
    barFrame:SetFrameStrata(container:GetFrameStrata())
    barFrame:SetFrameLevel(container:GetFrameLevel() + 1)

    if showGraphics then
        local bg = barFrame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        if cfg.shape == "ring" then
            bg:SetColorTexture(0, 0, 0, 0)
        else
            local bgc = cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }
            bg:SetColorTexture(bgc.r, bgc.g, bgc.b, bgc.a)
        end
        barFrame._bg = bg
    end

    if showGraphics and cfg.showIcon ~= false then
        local iconFrame = CreateFrame("Frame", nil, container)
        iconFrame:SetFrameStrata(container:GetFrameStrata())
        local iconSize = cfg.iconSize or 20
        iconFrame:SetSize(iconSize, iconSize)
        local pos = cfg.iconPosition or "LEFT"
        local ox  = cfg.iconOffsetX  or 0
        local oy  = cfg.iconOffsetY  or 0
        local iconAnchor, relAnchor
        if     pos == "LEFT"  then iconAnchor, relAnchor = "RIGHT",  "LEFT"
        elseif pos == "RIGHT" then iconAnchor, relAnchor = "LEFT",   "RIGHT"
        elseif pos == "TOP"   then iconAnchor, relAnchor = "BOTTOM", "TOP"
        else                       iconAnchor, relAnchor = "TOP",    "BOTTOM"
        end
        iconFrame:SetPoint(iconAnchor, container, relAnchor, ox, oy)
        local si = C_Spell.GetSpellInfo(spellID)
        if si and si.iconID then
            local t = iconFrame:CreateTexture(nil, "ARTWORK")
            t:SetAllPoints()
            t:SetTexture(si.iconID)
            t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        barFrame._iconFrame = iconFrame
    end

    local segContainer = CreateFrame("Frame", nil, barFrame)
    segContainer:SetAllPoints(barFrame)
    segContainer:SetFrameLevel(barFrame:GetFrameLevel() + 1)
    segContainer:EnableMouse(false)
    -- 勿 Clip：与 ResourceBars 一致，避免边框锯齿叠粗
    segContainer:SetClipsChildren(false)
    barFrame._segContainer = segContainer

    local textHolder = CreateFrame("Frame", nil, barFrame)
    textHolder:SetAllPoints(barFrame)
    textHolder:SetFrameStrata(container:GetFrameStrata())
    textHolder:SetFrameLevel(container:GetFrameLevel() + 50)
    textHolder:EnableMouse(false)
    barFrame._textHolder = textHolder

    local chargeTextMask = CreateFrame("Frame", nil, textHolder)
    chargeTextMask:SetAllPoints(barFrame)
    chargeTextMask:SetFrameStrata(container:GetFrameStrata())
    chargeTextMask:SetFrameLevel(textHolder:GetFrameLevel())
    chargeTextMask:SetClipsChildren(true)
    chargeTextMask:EnableMouse(false)
    barFrame._chargeTextMask = chargeTextMask

    if showText then
        local tf      = cfg.timerFont or {}
        local fc      = tf.color or { r = 1, g = 1, b = 1, a = 1 }
        local tAnchor = tf.position or "CENTER"
        barFrame._text = textHolder:CreateFontString(nil, "OVERLAY")
        ApplyConfiguredFont(barFrame._text, tf)
        barFrame._text:SetTextColor(fc.r, fc.g, fc.b, fc.a)
        barFrame._text:SetPoint(tAnchor, textHolder, tAnchor, tf.offsetX or 0, tf.offsetY or 0)
        barFrame._text:SetJustifyH("CENTER")
    end

    barFrame._cfg                   = cfg
    barFrame._spellID               = spellID
    barFrame._segments              = {}
    barFrame._segBGs                = {}
    barFrame._thresholdOverlays     = {}
    barFrame._shadowCooldown        = nil
    barFrame._cachedChargeInfo      = nil
    barFrame._cachedMaxCharges      = 0
    barFrame._needsChargeRefresh    = true
    barFrame._lastChargeWasFull     = false
    barFrame._lastFillMode          = nil
    barFrame._chargeBar             = nil
    barFrame._refreshCharge         = nil
    barFrame._chargeBorders         = nil
    barFrame._lastKnownActive       = false
    barFrame._lastKnownStacks       = 0
    barFrame._nilCount              = 0
    barFrame._trackedAuraInstanceID = nil
    barFrame._trackedUnit           = nil
    barFrame._segsDirty             = false
    barFrame._segsNeedCount         = nil
    barFrame._tickMode              = nil
    barFrame._isTicking             = false
    barFrame._isVisible             = true

    return barFrame
end

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

-- =========================================================
-- SECTION 7: 技能冷却更新
-- =========================================================

local function UpdateRegularCooldownBar(barFrame, spellID)
    local cfg = barFrame._cfg
    local showGraphics = ShouldRenderGraphics(cfg)
    local showText = ShouldRenderText(cfg)
    local tickDurObj, tickText

    local cdInfo
    pcall(function() cdInfo = C_Spell.GetSpellCooldown(spellID) end)
    local isOnGCD = cdInfo and cdInfo.isOnGCD == true
    local spellCdActive = true
    if cdInfo and cdInfo.isActive ~= nil then
        spellCdActive = cdInfo.isActive == true
    end

    local durObj
    local shadowCD = showGraphics and GetOrCreateShadowCooldown(barFrame) or nil
    if not isOnGCD then
        pcall(function() durObj = C_Spell.GetSpellCooldownDuration(spellID) end)
    end
    if showGraphics then
        if isOnGCD then
            shadowCD:Clear()
        elseif durObj and spellCdActive then
            shadowCD:Clear()
            pcall(function() shadowCD:SetCooldownFromDurationObject(durObj, true) end)
        else
            shadowCD:Clear()
        end
    end

    local isOnCooldown = false
    if showGraphics then
        isOnCooldown = shadowCD:IsShown()
    elseif durObj and spellCdActive then
        -- 12.0 DurationObject 可能含 secret，非图形模式保守认定有 durObj 即冷却中
        isOnCooldown = true
    end

    if not showGraphics then
        if barFrame._text then
            if isOnCooldown and not isOnGCD and durObj and spellCdActive and showText then
                SetRemainingText(barFrame._text, durObj)
                tickDurObj = durObj
                tickText = barFrame._text
            else
                barFrame._text:SetText("")
            end
        end
        SetBarTickState(barFrame, tickDurObj and "spell_cd" or nil)
        return
    end

    if not barFrame._segments or #barFrame._segments ~= 1 then
        CreateSegments(barFrame, 1, cfg)
    end
    local seg = barFrame._segments and barFrame._segments[1]
    if not seg then
        SetBarTickState(barFrame, nil)
        return
    end

    if isOnCooldown and not isOnGCD and durObj and spellCdActive then
        local rc = cfg.rechargeColor or cfg.barColor
        seg:SetStatusBarColor(rc.r, rc.g, rc.b, rc.a)
        local dir = FillDirection(cfg.barFillMode)
        if not ApplyTimerDuration(seg, durObj, INTERP_EASE_OUT, dir) then
            seg:SetValue(0)
        end
        barFrame._lastFillMode = cfg.barFillMode
        if barFrame._text and showText then
            SetRemainingText(barFrame._text, durObj)
            tickDurObj = durObj
            tickText = barFrame._text
        elseif barFrame._text then
            barFrame._text:SetText("")
        end
    else
        seg:SetStatusBarColor(cfg.barColor.r, cfg.barColor.g, cfg.barColor.b, cfg.barColor.a)
        seg:SetMinMaxValues(0, 1)
        seg:SetValue(1)
        if barFrame._text then barFrame._text:SetText("") end
    end
    if BFK then BFK.SetReverseFill(seg, cfg.barReverse == true) end
    SetBarTickState(barFrame, tickDurObj and "spell_cd" or nil)
end

-- =========================================================
-- SECTION 8: 充能技能更新
-- =========================================================

local function UpdateChargeBar(barFrame, spellID)
    local cfg = barFrame._cfg
    local showGraphics = ShouldRenderGraphics(cfg)
    local showText = ShouldRenderText(cfg)
    local tickDurObj, tickText

    if not cfg.isChargeSpell then
        UpdateRegularCooldownBar(barFrame, spellID)
        return
    end

    if barFrame._needsChargeRefresh then
        barFrame._cachedChargeInfo   = C_Spell.GetSpellCharges(spellID)
        barFrame._needsChargeRefresh = false
    end

    local chargeInfo = barFrame._cachedChargeInfo
    if not chargeInfo then
        SetBarTickState(barFrame, nil)
        return
    end

    local currentCharges = chargeInfo.currentCharges
    local maxCharges = chargeInfo.maxCharges
    local wasFullyCharged = barFrame._lastChargeWasFull == true

    if not (issecretvalue and issecretvalue(maxCharges)) then
        barFrame._cachedMaxCharges = maxCharges
    else
        local cached = barFrame._cachedMaxCharges
        if cached and cached > 0 then maxCharges = cached end
    end

    if issecretvalue and issecretvalue(maxCharges) then
        SetBarTickState(barFrame, nil); return
    end
    if not maxCharges or maxCharges < 1 then
        SetBarTickState(barFrame, nil); return
    end

    local chargeDurObj
    pcall(function() chargeDurObj = C_Spell.GetSpellChargeDuration(spellID) end)

    local activeChargeDurObj = chargeDurObj
    local recharging = true
    pcall(function()
        if type(currentCharges) == "number" and type(maxCharges) == "number" then
            if not (issecretvalue and (issecretvalue(currentCharges) or issecretvalue(maxCharges))) then
                recharging = currentCharges < maxCharges
            end
        end
    end)

    local shouldShowRecharge = recharging and (chargeDurObj ~= nil) and (activeChargeDurObj ~= nil)

    if not showGraphics then
        if barFrame._text then
            if showText and shouldShowRecharge then
                SetRemainingText(barFrame._text, activeChargeDurObj)
                tickDurObj = activeChargeDurObj
                tickText = barFrame._text
            else
                barFrame._text:SetText("")
            end
        end
        if type(currentCharges) == "number" and type(maxCharges) == "number"
            and not (issecretvalue and (issecretvalue(currentCharges) or issecretvalue(maxCharges))) then
            barFrame._lastChargeWasFull = currentCharges >= maxCharges
        else
            barFrame._lastChargeWasFull = false
        end
        SetBarTickState(barFrame, tickDurObj and "spell_charge" or nil)
        return
    end

    local borderThickness = tonumber(cfg.borderThickness) or 1

    if not barFrame._chargeBG then
        local bg = barFrame._segContainer:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(barFrame._segContainer)
        local bgc = cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }
        bg:SetColorTexture(bgc.r, bgc.g, bgc.b, bgc.a)
        barFrame._chargeBG = bg
    end

    if not barFrame._chargeBar then
        local chargeBar = CreateFrame("StatusBar", nil, barFrame._segContainer)
        chargeBar:SetStatusBarTexture(BFK and BFK.ResolveBarTexture(cfg.barTexture) or "Interface\\Buttons\\WHITE8X8")
        chargeBar:SetAllPoints(barFrame._segContainer)
        chargeBar:SetFrameLevel(barFrame._segContainer:GetFrameLevel() + 1)
        if BFK then BFK.ConfigureStatusBar(chargeBar) end
        barFrame._chargeBar = chargeBar
    end

    local barTex = BFK and BFK.ResolveBarTexture(cfg.barTexture) or "Interface\\Buttons\\WHITE8X8"
    barFrame._chargeBar:SetStatusBarTexture(barTex)
    if BFK then BFK.ConfigureStatusBar(barFrame._chargeBar) end
    barFrame._chargeBar:SetStatusBarColor(cfg.barColor.r, cfg.barColor.g, cfg.barColor.b, cfg.barColor.a)
    barFrame._chargeBar:SetMinMaxValues(0, maxCharges)
    barFrame._chargeBar:SetValue(currentCharges)
    local dir = cfg.barDirection or "horizontal"
    if BFK then
        BFK.SetOrientation(barFrame._chargeBar, dir)
        BFK.SetReverseFill(barFrame._chargeBar, cfg.barReverse == true)
    end

    if not barFrame._refreshCharge then
        local refreshCharge = CreateFrame("StatusBar", nil, barFrame._segContainer)
        refreshCharge:SetStatusBarTexture(BFK and BFK.ResolveBarTexture(cfg.barTexture) or "Interface\\Buttons\\WHITE8X8")
        if BFK then BFK.ConfigureStatusBar(refreshCharge) end
        barFrame._refreshCharge = refreshCharge
    end

    if showText and not barFrame._refreshChargeText then
        local tf = cfg.timerFont or {}
        local fc = tf.color or { r = 1, g = 1, b = 1, a = 1 }
        local clip = CreateFrame("Frame", nil, barFrame._chargeTextMask or barFrame._textHolder)
        clip:SetPoint("TOPLEFT", barFrame._refreshCharge, "TOPLEFT", 0, 0)
        clip:SetPoint("BOTTOMRIGHT", barFrame._refreshCharge, "BOTTOMRIGHT", 0, 0)
        clip:SetFrameLevel(barFrame._textHolder:GetFrameLevel())
        clip:SetClipsChildren(true)
        clip:EnableMouse(false)
        barFrame._refreshChargeClip = clip

        local txt = clip:CreateFontString(nil, "OVERLAY")
        ApplyConfiguredFont(txt, tf)
        txt:SetTextColor(fc.r, fc.g, fc.b, fc.a)
        txt:SetJustifyH("CENTER")
        local anchor = tf.position or "CENTER"
        txt:SetPoint(anchor, clip, anchor, tf.offsetX or 0, tf.offsetY or 0)
        barFrame._refreshChargeText = txt
    end

    local rc = cfg.rechargeColor or { r = 0.5, g = 0.8, b = 1, a = 1 }
    barFrame._refreshCharge:SetStatusBarTexture(barTex)
    if BFK then BFK.ConfigureStatusBar(barFrame._refreshCharge) end
    barFrame._refreshCharge:SetStatusBarColor(rc.r, rc.g, rc.b, rc.a)
    if BFK then
        BFK.SetOrientation(barFrame._refreshCharge, dir)
        BFK.SetReverseFill(barFrame._refreshCharge, cfg.barReverse == true)
    end

    local totalW = barFrame._segContainer:GetWidth()
    local totalH = barFrame._segContainer:GetHeight()
    local barReverse = cfg.barReverse == true
    if totalW > 0 and totalH > 0 then
        local userGap = tonumber(cfg.segmentGap) or 0
        local segmentGap = (maxCharges > 1) and (userGap - borderThickness) or 0
        local ppScale = PP.GetPixelScale(barFrame._segContainer)
        local function ToPixel(v) return math.floor(v / ppScale + 0.5) end
        local function ToLogical(px) return px * ppScale end

        local pxTotalW = ToPixel(totalW)
        local pxTotalH = ToPixel(totalH)
        local pxGap = ToPixel(segmentGap)

        local pxSegW_Base, pxSegH_Base, pxRemainder
        if dir == "vertical" then
            pxSegW_Base = pxTotalW
            local pxAvailableH = math.max(0, pxTotalH - (maxCharges - 1) * pxGap)
            pxSegH_Base = math.floor(pxAvailableH / maxCharges)
            pxRemainder = pxAvailableH % maxCharges
        else
            pxSegH_Base = pxTotalH
            local pxAvailableW = math.max(0, pxTotalW - (maxCharges - 1) * pxGap)
            pxSegW_Base = math.floor(pxAvailableW / maxCharges)
            pxRemainder = pxAvailableW % maxCharges
        end

        local thisPxSegW = pxSegW_Base
        local thisPxSegH = pxSegH_Base
        if dir == "vertical" then
            if 1 <= pxRemainder then thisPxSegH = thisPxSegH + 1 end
        else
            if 1 <= pxRemainder then thisPxSegW = thisPxSegW + 1 end
        end
        local logSegW = ToLogical(thisPxSegW)
        local logSegH = ToLogical(thisPxSegH)

        barFrame._refreshCharge:ClearAllPoints()
        local texObj = barFrame._chargeBar:GetStatusBarTexture()
        if texObj then
            if dir == "vertical" then
                if not barReverse then
                    barFrame._refreshCharge:SetPoint("BOTTOM", texObj, "TOP", 0, 0)
                else
                    barFrame._refreshCharge:SetPoint("TOP", texObj, "BOTTOM", 0, 0)
                end
            else
                if not barReverse then
                    barFrame._refreshCharge:SetPoint("LEFT", texObj, "RIGHT", 0, 0)
                else
                    barFrame._refreshCharge:SetPoint("RIGHT", texObj, "LEFT", 0, 0)
                end
            end
        end
        barFrame._refreshCharge:SetSize(logSegW, logSegH)
    end

    pcall(function()
        barFrame._refreshCharge:SetTimerDuration(
            chargeDurObj,
            Enum.StatusBarInterpolation.Immediate or 0,
            Enum.StatusBarTimerDirection.ElapsedTime or 0
        )
    end)

    activeChargeDurObj = nil
    if barFrame._refreshCharge.GetTimerDuration then
        activeChargeDurObj = barFrame._refreshCharge:GetTimerDuration()
    end

    local suppressRechargeThisFrame = wasFullyCharged and recharging
    shouldShowRecharge = recharging and (chargeDurObj ~= nil) and (activeChargeDurObj ~= nil)

    if shouldShowRecharge then
        barFrame._refreshCharge:Show()
        barFrame._refreshCharge:SetAlpha(suppressRechargeThisFrame and 0 or 1)
    else
        barFrame._refreshCharge:Hide()
        barFrame._refreshCharge:SetAlpha(1)
    end

    -- 充能分隔边框
    if maxCharges > 1 and borderThickness > 0 then
        barFrame._chargeBorders = barFrame._chargeBorders or {}
        for i = maxCharges + 1, #barFrame._chargeBorders do
            if barFrame._chargeBorders[i] then
                PP.HideBorder(barFrame._chargeBorders[i])
                barFrame._chargeBorders[i]:Hide()
                barFrame._chargeBorders[i] = nil
            end
        end
        if totalW > 0 and totalH > 0 then
            local userGap = tonumber(cfg.segmentGap) or 0
            local segmentGap = (maxCharges > 1) and (userGap - borderThickness) or 0
            local bc = cfg.borderColor or { r = 0.3, g = 0.3, b = 0.3, a = 1 }
            local metrics = BuildChargeSegmentMetrics(barFrame._segContainer, maxCharges, dir, segmentGap)

            for i = 1, maxCharges do
                local cell = metrics and metrics[i]
                if not barFrame._chargeBorders[i] then
                    local borderFrame = CreateFrame("Frame", nil, barFrame._segContainer)
                    borderFrame:SetFrameLevel(barFrame._segContainer:GetFrameLevel() + 10)
                    barFrame._chargeBorders[i] = borderFrame
                end
                local borderFrame = barFrame._chargeBorders[i]
                borderFrame:ClearAllPoints()
                if cell then
                    local anchor = (dir == "vertical") and "BOTTOMLEFT" or "TOPLEFT"
                    borderFrame:SetPoint(anchor, barFrame._segContainer, anchor, cell.x, cell.y)
                    PP.SetSize(borderFrame, cell.w, cell.h)
                end

                local needRebuild = (not borderFrame._vfBorderThickness)
                    or (borderFrame._vfBorderThickness ~= borderThickness)
                    or (borderFrame._vfBorderW ~= (cell and cell.w or 0))
                    or (borderFrame._vfBorderH ~= (cell and cell.h or 0))
                if needRebuild then
                    PP.CreateBorder(borderFrame, borderThickness, bc, true)
                    borderFrame._vfBorderThickness = borderThickness
                    borderFrame._vfBorderW = cell and cell.w or 0
                    borderFrame._vfBorderH = cell and cell.h or 0
                    borderFrame._vfBorderColor = { r = bc.r or 1, g = bc.g or 1, b = bc.b or 1, a = bc.a or 1 }
                else
                    local last = borderFrame._vfBorderColor
                    local r, g, b, a = bc.r or 1, bc.g or 1, bc.b or 1, bc.a or 1
                    if (not last) or last.r ~= r or last.g ~= g or last.b ~= b or last.a ~= a then
                        PP.UpdateBorderColor(borderFrame, bc)
                        borderFrame._vfBorderColor = { r = r, g = g, b = b, a = a }
                    end
                end
                PP.ShowBorder(borderFrame)
                borderFrame:Show()
            end
        end
    else
        if barFrame._chargeBorders then
            for _, borderFrame in ipairs(barFrame._chargeBorders) do
                PP.HideBorder(borderFrame)
                borderFrame:Hide()
            end
        end
    end

    if barFrame._text then barFrame._text:SetText("") end
    if barFrame._refreshChargeText then
        if shouldShowRecharge then
            SetRemainingText(barFrame._refreshChargeText, activeChargeDurObj)
            tickDurObj = activeChargeDurObj
            tickText = barFrame._refreshChargeText
        else
            barFrame._refreshChargeText:SetText("")
        end
    end

    if type(currentCharges) == "number" and type(maxCharges) == "number"
        and not (issecretvalue and (issecretvalue(currentCharges) or issecretvalue(maxCharges))) then
        barFrame._lastChargeWasFull = currentCharges >= maxCharges
    else
        barFrame._lastChargeWasFull = false
    end
    SetBarTickState(barFrame, tickDurObj and "spell_charge" or nil)
end

-- =========================================================
-- SECTION 9: 导出
-- =========================================================

VFlow.CustomMonitorBar = {
    RING_TEXTURE_FMT         = RING_TEXTURE_FMT,
    INTERP_EASE_OUT          = INTERP_EASE_OUT,
    HasAuraInstanceID        = HasAuraInstanceID,
    AuraInstanceIDForAPI     = AuraInstanceIDForAPI,
    ResolveFontFlags         = ResolveFontFlags,
    ApplyConfiguredFont      = ApplyConfiguredFont,
    SetRemainingText         = SetRemainingText,
    FillDirection            = FillDirection,
    ApplyTimerDuration       = ApplyTimerDuration,
    SetBarTickState          = SetBarTickState,
    ShouldRenderGraphics     = ShouldRenderGraphics,
    ShouldRenderText         = ShouldRenderText,
    innerBarSignature        = innerBarSignature,
    segmentLayoutSignature   = segmentLayoutSignature,
    ClearSegments            = ClearSegments,
    CreateSegments           = CreateSegments,
    SetStackSegmentsValue    = SetStackSegmentsValue,
    BuildChargeSegmentMetrics = BuildChargeSegmentMetrics,
    GetOrCreateShadowCooldown = GetOrCreateShadowCooldown,
    CreateBarFrame           = CreateBarFrame,
    ApplyBgColor             = ApplyBgColor,
    UpdateRegularCooldownBar = UpdateRegularCooldownBar,
    UpdateChargeBar          = UpdateChargeBar,
}

-- =========================================================
-- VFlow CustomMonitor Runtime — CooldownRenderer
-- 职责：技能冷却 / 充能条更新逻辑
--   - UpdateRegularCooldownBar：单段（普通技能）
--   - UpdateChargeBar：多段（充能技能 OctoChargeBar 方案）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CUSTOM_ENABLED then return end

VFlow.CustomMonitor = VFlow.CustomMonitor or {}
VFlow.CustomMonitor.Runtime = VFlow.CustomMonitor.Runtime or {}
VFlow.CustomMonitor.Runtime.Renderers = VFlow.CustomMonitor.Runtime.Renderers or {}

local Constants = VFlow.CustomMonitor.Runtime.Constants
local Segments = VFlow.CustomMonitor.Runtime.Segments
local CdmRegistry = VFlow.CustomMonitor.Runtime.CdmRegistry
local Fonts = VFlow.CustomMonitor.Runtime.Fonts
local PP = VFlow.PixelPerfect
local BFK = VFlow.BarFrameKit

local CooldownRenderer = {}
VFlow.CustomMonitor.Runtime.Renderers.Cooldown = CooldownRenderer

local ShouldRenderGraphics = Segments.shouldRenderGraphics
local ShouldRenderText = Segments.shouldRenderText
local SetRemainingText = Segments.setRemainingText
local FillDirection = Segments.fillDirection
local ApplyTimerDuration = Segments.applyTimerDuration
local SetBarTickState = Segments.setBarTickState
local CreateSegments = Segments.create
local BuildChargeSegmentMetrics = Segments.buildChargeMetrics
local GetOrCreateShadowCooldown = CdmRegistry.getOrCreateShadowCooldown

-- =========================================================
-- SECTION 1: 普通冷却
-- =========================================================

local function UpdateRegularCooldownBar(barFrame, spellID)
    local cfg = barFrame._cfg
    local showGraphics = ShouldRenderGraphics(cfg)
    local showText = ShouldRenderText(cfg)
    local tickDurObj = nil
    local cdInfo
    pcall(function()
        cdInfo = C_Spell.GetSpellCooldown(spellID)
    end)
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
        -- 12.0 的 DurationObject 可能返回 secret value，只能直接渲染，不能比较。
        -- 非图形模式下这里保守认定存在 durObj 即进入文本刷新，结束态由事件链收敛。
        isOnCooldown = true
    end

    if not showGraphics then
        if barFrame._text then
            if isOnCooldown and not isOnGCD and durObj and spellCdActive and showText then
                SetRemainingText(barFrame._text, durObj)
                tickDurObj = durObj
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

    -- 根据冷却状态设置颜色
    if isOnCooldown and not isOnGCD and durObj and spellCdActive then
        -- 冷却中：使用 rechargeColor（冷却中颜色）
        local rc = cfg.rechargeColor or cfg.barColor
        seg:SetStatusBarColor(rc.r, rc.g, rc.b, rc.a)
        local dir = FillDirection(cfg.barFillMode)
        if not ApplyTimerDuration(seg, durObj, Constants.INTERP_EASE_OUT, dir) then
            seg:SetValue(0)
        end
        barFrame._lastFillMode = cfg.barFillMode
        if barFrame._text and showText then
            SetRemainingText(barFrame._text, durObj)
            tickDurObj = durObj
        elseif barFrame._text then
            barFrame._text:SetText("")
        end
    else
        -- 就绪时：使用 barColor（就绪时颜色）
        seg:SetStatusBarColor(cfg.barColor.r, cfg.barColor.g, cfg.barColor.b, cfg.barColor.a)
        seg:SetMinMaxValues(0, 1)
        seg:SetValue(1)
        if barFrame._text then barFrame._text:SetText("") end
    end
    if BFK then BFK.SetReverseFill(seg, cfg.barReverse == true) end
    SetBarTickState(barFrame, tickDurObj and "spell_cd" or nil)
end

-- =========================================================
-- SECTION 2: 充能技能（OctoChargeBar 方案）
-- =========================================================

local function UpdateChargeBar(barFrame, spellID)
    local cfg = barFrame._cfg
    local showGraphics = ShouldRenderGraphics(cfg)
    local showText = ShouldRenderText(cfg)
    local tickDurObj = nil

    -- 使用配置中预先判断的技能类型
    if not cfg.isChargeSpell then
        UpdateRegularCooldownBar(barFrame, spellID)
        return
    end

    if barFrame._needsChargeRefresh then
        barFrame._cachedChargeInfo = C_Spell.GetSpellCharges(spellID)
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

    -- 缓存非 secret 的 maxCharges 值，战斗中可能需要 fallback
    if not (issecretvalue and issecretvalue(maxCharges)) then
        barFrame._cachedMaxCharges = maxCharges
    else
        local cached = barFrame._cachedMaxCharges
        if cached and cached > 0 then
            maxCharges = cached
        end
    end

    -- 如果 maxCharges 仍是 secret 或无效，无法设置条
    if issecretvalue and issecretvalue(maxCharges) then
        SetBarTickState(barFrame, nil)
        return
    end
    if not maxCharges or maxCharges < 1 then
        SetBarTickState(barFrame, nil)
        return
    end

    local chargeDurObj = nil
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

    -- 创建背景层（显示未充能部分）
    if not barFrame._chargeBG then
        local bg = barFrame._segContainer:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(barFrame._segContainer)
        local bgc = cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }
        bg:SetColorTexture(bgc.r, bgc.g, bgc.b, bgc.a)
        barFrame._chargeBG = bg
    end

    -- 设置主充能条（显示已有充能数）
    if not barFrame._chargeBar then
        local chargeBar = CreateFrame("StatusBar", nil, barFrame._segContainer)
        chargeBar:SetStatusBarTexture(BFK and BFK.ResolveBarTexture(cfg.barTexture) or "Interface\\Buttons\\WHITE8X8")
        chargeBar:SetAllPoints(barFrame._segContainer)
        chargeBar:SetFrameLevel(barFrame._segContainer:GetFrameLevel() + 1)
        if BFK then BFK.ConfigureStatusBar(chargeBar) end
        barFrame._chargeBar = chargeBar
    end

    -- 每次更新颜色与材质（配置可能变化）
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

    -- 设置充能进度条（显示正在充能的进度）
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
        Fonts.apply(txt, tf)
        txt:SetTextColor(fc.r, fc.g, fc.b, fc.a)
        txt:SetJustifyH("CENTER")
        local anchor = tf.position or "CENTER"
        txt:SetPoint(anchor, clip, anchor, tf.offsetX or 0, tf.offsetY or 0)
        barFrame._refreshChargeText = txt
    end

    -- 每次更新颜色与材质（配置可能变化）
    local rc = cfg.rechargeColor or { r = 0.5, g = 0.8, b = 1, a = 1 }
    barFrame._refreshCharge:SetStatusBarTexture(barTex)
    if BFK then BFK.ConfigureStatusBar(barFrame._refreshCharge) end
    barFrame._refreshCharge:SetStatusBarColor(rc.r, rc.g, rc.b, rc.a)
    if BFK then
        BFK.SetOrientation(barFrame._refreshCharge, dir)
        BFK.SetReverseFill(barFrame._refreshCharge, cfg.barReverse == true)
    end

    -- 保持原有充能动画路径：单格尺寸按首格计算，位置继续锚定到主条填充前沿
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
        local tex = barFrame._chargeBar:GetStatusBarTexture()
        if tex then
            if dir == "vertical" then
                if not barReverse then
                    barFrame._refreshCharge:SetPoint("BOTTOM", tex, "TOP", 0, 0)
                else
                    barFrame._refreshCharge:SetPoint("TOP", tex, "BOTTOM", 0, 0)
                end
            else
                if not barReverse then
                    barFrame._refreshCharge:SetPoint("LEFT", tex, "RIGHT", 0, 0)
                else
                    barFrame._refreshCharge:SetPoint("RIGHT", tex, "LEFT", 0, 0)
                end
            end
        end
        barFrame._refreshCharge:SetSize(logSegW, logSegH)
    end

    -- 使用 SetTimerDuration 设置充能进度动画
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

    local suppressRechargeThisFrame = false
    if wasFullyCharged and recharging then
        suppressRechargeThisFrame = true
    end

    shouldShowRecharge = recharging and (chargeDurObj ~= nil) and (activeChargeDurObj ~= nil)

    if shouldShowRecharge then
        barFrame._refreshCharge:Show()
        barFrame._refreshCharge:SetAlpha(suppressRechargeThisFrame and 0 or 1)
    else
        barFrame._refreshCharge:Hide()
        barFrame._refreshCharge:SetAlpha(1)
    end

    -- 创建分隔线（使用完美像素边框）- 边框重合自动形成分隔线
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
                    borderFrame._vfBorderColor = {
                        r = bc.r or 1,
                        g = bc.g or 1,
                        b = bc.b or 1,
                        a = bc.a or 1,
                    }
                else
                    local last = borderFrame._vfBorderColor
                    local r = bc.r or 1
                    local g = bc.g or 1
                    local b = bc.b or 1
                    local a = bc.a or 1
                    if (not last)
                        or (last.r ~= r)
                        or (last.g ~= g)
                        or (last.b ~= b)
                        or (last.a ~= a) then
                        PP.UpdateBorderColor(borderFrame, bc)
                        borderFrame._vfBorderColor = { r = r, g = g, b = b, a = a }
                    end
                end
                PP.ShowBorder(borderFrame)
                borderFrame:Show()
            end
        end
    else
        -- 隐藏所有边框
        if barFrame._chargeBorders then
            for _, borderFrame in ipairs(barFrame._chargeBorders) do
                PP.HideBorder(borderFrame)
                borderFrame:Hide()
            end
        end
    end

    -- 更新文字显示
    if barFrame._text then
        barFrame._text:SetText("")
    end
    if barFrame._refreshChargeText then
        if shouldShowRecharge then
            SetRemainingText(barFrame._refreshChargeText, activeChargeDurObj)
            tickDurObj = activeChargeDurObj
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

CooldownRenderer.updateRegular = UpdateRegularCooldownBar
CooldownRenderer.updateCharge = UpdateChargeBar

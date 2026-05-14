-- =========================================================
-- VFlow CustomMonitor Runtime — BarFrame
-- 职责：CreateBarFrame 总入口（技能 / BUFF 共用）
--   构造 barFrame 三层结构：
--     barFrame
--     ├─ _bg               矩形背景
--     ├─ _iconFrame        spell 图标
--     ├─ _segContainer     段容器（Segments.create 在此挂段）
--     ├─ _textHolder       公共文本层
--     └─ _chargeTextMask   充能文字遮罩
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CUSTOM_ENABLED then return end

VFlow.CustomMonitor = VFlow.CustomMonitor or {}
VFlow.CustomMonitor.Runtime = VFlow.CustomMonitor.Runtime or {}

local Segments = VFlow.CustomMonitor.Runtime.Segments
local Fonts = VFlow.CustomMonitor.Runtime.Fonts

local BarFrame = {}
VFlow.CustomMonitor.Runtime.BarFrame = BarFrame

local ShouldRenderGraphics = Segments.shouldRenderGraphics
local ShouldRenderText = Segments.shouldRenderText
local ApplyConfiguredFont = Fonts.apply

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
        local ox = cfg.iconOffsetX or 0
        local oy = cfg.iconOffsetY or 0
        local iconAnchor, relAnchor
        if pos == "LEFT" then
            iconAnchor, relAnchor = "RIGHT", "LEFT"
        elseif pos == "RIGHT" then
            iconAnchor, relAnchor = "LEFT", "RIGHT"
        elseif pos == "TOP" then
            iconAnchor, relAnchor = "BOTTOM", "TOP"
        else
            iconAnchor, relAnchor = "TOP", "BOTTOM"
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
    --- 勿对整条形容器 Clip：与 ResourceBars 一致；Clip 会在接缝/尾部与 PixelPerfect 1px 边框锯齿叠粗。
    --- 充能数字溢出由 _refreshChargeClip:SetClipsChildren(true) 处理。
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
        local tf = cfg.timerFont or {}
        local fc = tf.color or { r = 1, g = 1, b = 1, a = 1 }
        local tAnchor = tf.position or "CENTER"

        barFrame._text = textHolder:CreateFontString(nil, "OVERLAY")
        ApplyConfiguredFont(barFrame._text, tf)
        barFrame._text:SetTextColor(fc.r, fc.g, fc.b, fc.a)
        barFrame._text:SetPoint(tAnchor, textHolder, tAnchor, tf.offsetX or 0, tf.offsetY or 0)
        barFrame._text:SetJustifyH("CENTER")
    end

    barFrame._cfg = cfg
    barFrame._spellID = spellID
    barFrame._segments = {}
    barFrame._segBGs = {}
    barFrame._thresholdOverlays = {}
    barFrame._shadowCooldown = nil

    -- 技能冷却 / 充能
    barFrame._cachedChargeInfo = nil
    barFrame._cachedMaxCharges = 0
    barFrame._needsChargeRefresh = true
    barFrame._lastChargeWasFull = false
    barFrame._lastFillMode = nil
    barFrame._chargeBar = nil       -- OctoChargeBar 方案：主充能条
    barFrame._refreshCharge = nil   -- OctoChargeBar 方案：充能进度条
    barFrame._chargeBorders = nil   -- OctoChargeBar 方案：边框容器

    -- BUFF 堆叠
    barFrame._lastKnownActive = false
    barFrame._lastKnownStacks = 0
    barFrame._nilCount = 0
    barFrame._trackedAuraInstanceID = nil
    barFrame._trackedUnit = nil

    -- 通用
    barFrame._segsDirty = false
    barFrame._segsNeedCount = nil
    barFrame._tickMode = nil
    barFrame._isTicking = false
    barFrame._isVisible = true

    return barFrame
end

BarFrame.create = CreateBarFrame

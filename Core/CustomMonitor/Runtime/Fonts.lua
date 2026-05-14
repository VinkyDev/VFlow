-- =========================================================
-- VFlow CustomMonitor Runtime — Fonts
-- timerFont 配置 → 字体应用辅助
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CUSTOM_ENABLED then return end

VFlow.CustomMonitor = VFlow.CustomMonitor or {}
VFlow.CustomMonitor.Runtime = VFlow.CustomMonitor.Runtime or {}

local Fonts = {}
VFlow.CustomMonitor.Runtime.Fonts = Fonts

local function ResolveFontFlags(outline)
    if outline == "OUTLINE" or outline == "THICKOUTLINE" then
        return outline
    end
    if outline == "MONOCHROMEOUTLINE" then
        return "OUTLINE,MONOCHROME"
    end
    return ""
end

local function ApplyConfiguredFont(fs, tf)
    if not fs then return end
    local fontSize = tf and tf.size or 14
    local fontFlags = ResolveFontFlags(tf and tf.outline)
    local applyFont = VFlow.UI and VFlow.UI.applyFont
    if applyFont then
        applyFont(fs, tf and tf.font, fontSize, fontFlags)
    end
    if tf and tf.outline == "SHADOW" then
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
    else
        fs:SetShadowColor(0, 0, 0, 0)
        fs:SetShadowOffset(0, 0)
    end
end

Fonts.resolveFlags = ResolveFontFlags
Fonts.apply = ApplyConfiguredFont

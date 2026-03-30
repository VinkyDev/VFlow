-- =========================================================
-- SECTION 1: 模块入口
-- StyleApply — 全局 styleCache + 帧级 styleCacheVersion；hook 读缓存
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
local PixelPerfect = VFlow.PixelPerfect
local StyleApply = {}
VFlow.StyleApply = StyleApply

local abs = math.abs
local Profiler = VFlow.Profiler

-- =========================================================
-- SECTION 2: 工具函数
-- =========================================================

local function SafeEquals(v, expected)
    if type(v) == "number" and issecretvalue and issecretvalue(v) then
        return false
    end
    return v == expected
end

local function SafeSetShadow(fs, enabled)
    if not fs or not fs.SetShadowColor or not fs.SetShadowOffset then return end
    if enabled then
        pcall(fs.SetShadowColor, fs, 0, 0, 0, 1)
        pcall(fs.SetShadowOffset, fs, 1, -1)
    else
        pcall(fs.SetShadowColor, fs, 0, 0, 0, 0)
        pcall(fs.SetShadowOffset, fs, 0, 0)
    end
end

local function EnsureHideZeroTextHook(fs)
    if not fs or fs._vf_hideZeroTextHooked then return end
    if not hooksecurefunc or not fs.SetText then return end
    hooksecurefunc(fs, "SetText", function(self, value)
        if type(value) ~= "number" then return end
        local text = C_StringUtil and C_StringUtil.TruncateWhenZero and C_StringUtil.TruncateWhenZero(value)
        if text == nil then
            text = (value == 0) and "" or tostring(value)
        end
        self:SetText(text)
    end)
    fs._vf_hideZeroTextHooked = true
end

-- =========================================================
-- SECTION 3: 全局样式缓存与常量
-- =========================================================

local styleCache = {}
local styleCacheVersion = 0
local lastRefreshedVersion = -1

local DEFAULT_SWIPE_TEXTURE = "Interface\\HUD\\UI-HUD-CoolDownManager-Icon-Swipe"
local WHITE8X8 = "Interface\\Buttons\\WHITE8x8"
local BLIZZARD_ICON_OVERLAY_ATLAS = "UI-HUD-CoolDownManager-IconOverlay"
local BLIZZARD_ICON_MASK_ATLAS = "UI-HUD-CoolDownManager-Mask"
local BLIZZARD_ICON_OVERLAY_TEXTURE_FILE_ID = 6707800

local function RefreshStyleCache()
    if lastRefreshedVersion == styleCacheVersion then return end
    lastRefreshedVersion = styleCacheVersion

    local db = VFlow.Store and VFlow.Store.getModuleRef and VFlow.Store.getModuleRef("VFlow.StyleIcon")
    if not db then return end

    styleCache.zoomIcons              = db.zoomIcons or false
    styleCache.zoomAmount             = db.zoomAmount or 0.08
    styleCache.hideIconOverlay        = db.hideIconOverlay or false
    styleCache.hideIconOverlayTexture = db.hideIconOverlayTexture or false
    styleCache.hideDebuffBorder       = db.hideDebuffBorder or false
    styleCache.hidePandemicIndicator  = db.hidePandemicIndicator or false
    styleCache.hideCooldownBling      = db.hideCooldownBling or false
    styleCache.hideIconGCD            = db.hideIconGCD or false
    styleCache.borderFile             = db.borderFile
    styleCache.borderSize             = db.borderSize or 1
    styleCache.borderOffsetX          = db.borderOffsetX or 0
    styleCache.borderOffsetY          = db.borderOffsetY or 0
    styleCache.borderColor            = db.borderColor
end

function StyleApply.InvalidateStyleCache()
    styleCacheVersion = styleCacheVersion + 1
end

-- =========================================================
-- SECTION 4: FontString 查找
-- =========================================================

function StyleApply.GetCooldownFontString(button)
    if not button or not button.Cooldown then return nil end
    local cd = button.Cooldown
    if cd.GetCountdownFontString then
        local fs = cd:GetCountdownFontString()
        if fs and fs.SetFont then return fs end
    end
    for _, region in ipairs({ cd:GetRegions() }) do
        if region and region.IsObjectType and region:IsObjectType("FontString") then
            return region
        end
    end
    return nil
end

function StyleApply.GetStackFontString(button)
    local fs
    if button.Applications and button.Applications.Applications then
        fs = button.Applications.Applications
    elseif button.ChargeCount and button.ChargeCount.Current then
        fs = button.ChargeCount.Current
    end
    if fs then
        EnsureHideZeroTextHook(fs)
    end
    return fs
end

-- =========================================================
-- SECTION 5: 幂等样式应用（尺寸与字体）
-- =========================================================

function StyleApply.ApplyIconSize(button, w, h)
    Profiler.count("SA:ApplyIconSize")
    if button._vf_w == w and button._vf_h == h then return end
    button:SetSize(w, h)
    button._vf_w = w
    button._vf_h = h
end

function StyleApply.ApplyFontStyle(fs, cfg, cachePrefix)
    local _pt = Profiler.start("SA:ApplyFontStyle")
    if not fs or not cfg then Profiler.stop(_pt) return end
    local prefix = cachePrefix or "_vf"

    local size = cfg.size or 14
    local fontToken = cfg.font
    local outline = cfg.outline or "OUTLINE"
    local requestedFlags = ""
    if outline == "OUTLINE" or outline == "THICKOUTLINE" then
        requestedFlags = outline
    end
    local sizeKey = prefix .. "_size"
    local fontKey = prefix .. "_font"
    local outlineKey = prefix .. "_outline"

    if fs[sizeKey] ~= size or fs[fontKey] ~= fontToken or fs[outlineKey] ~= outline then
        local currentFont = fs:GetFont()
        local fontPath
        if type(fontToken) == "string" and fontToken ~= "" then
            if VFlow.UI and VFlow.UI.resolveFontPath then
                fontPath = VFlow.UI.resolveFontPath(fontToken)
            else
                fontPath = fontToken
            end
        end
        local ok = fontPath and pcall(fs.SetFont, fs, fontPath, size, requestedFlags)
        if not ok and currentFont then
            pcall(fs.SetFont, fs, currentFont, size, requestedFlags)
        end
        if outline == "SHADOW" then
            SafeSetShadow(fs, true)
        else
            SafeSetShadow(fs, false)
        end
        fs[sizeKey] = size
        fs[fontKey] = fontToken
        fs[outlineKey] = outline
    end

    if cfg.color then
        local c = cfg.color
        local r, g, b, a = c.r or 1, c.g or 1, c.b or 1, c.a or 1
        local rKey, gKey, bKey, aKey = prefix .. "_r", prefix .. "_g", prefix .. "_b", prefix .. "_a"
        if fs[rKey] ~= r or fs[gKey] ~= g or fs[bKey] ~= b or fs[aKey] ~= a then
            fs:SetTextColor(r, g, b, a)
            fs[rKey] = r; fs[gKey] = g; fs[bKey] = b; fs[aKey] = a
        end
    end

    local position = cfg.position or "CENTER"
    local ox = cfg.offsetX or 0
    local oy = cfg.offsetY or 0
    local posKey = prefix .. "_pos"
    local oxKey = prefix .. "_ox"
    local oyKey = prefix .. "_oy"
    if fs[posKey] ~= position or fs[oxKey] ~= ox or fs[oyKey] ~= oy then
        fs:ClearAllPoints()
        local parent = fs:GetParent()
        fs:SetPoint(position, parent, position, ox, oy)
        fs[posKey] = position; fs[oxKey] = ox; fs[oyKey] = oy
    end
    Profiler.stop(_pt)
end

-- =========================================================
-- SECTION 6: 键位显示
-- =========================================================

function StyleApply.ApplyKeybind(button, cfg)
    local _pt = Profiler.start("SA:ApplyKeybind")
    if not button or not cfg then Profiler.stop(_pt) return end

    local show = cfg.showKeybind
    if not show then
        if button._vf_keybindFrame then button._vf_keybindFrame:Hide() end
        Profiler.stop(_pt)
        return
    end

    local keyText = ""
    if VFlow.Keybind then
        local spellID = VFlow.Keybind.GetSpellIDFromIcon(button)
        if spellID then
            keyText = VFlow.Keybind.GetKeyForSpell(spellID) or ""
        end
    end

    if not button._vf_keybindFrame then
        local f = CreateFrame("Frame", nil, button)
        f:SetAllPoints(button)
        f:SetFrameLevel(button:GetFrameLevel() + 2)
        local fs = f:CreateFontString(nil, "OVERLAY")
        fs:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
        f._text = fs
        button._vf_keybindFrame = f
    end

    local fs = button._vf_keybindFrame._text
    if cfg.keybindFont then
        StyleApply.ApplyFontStyle(fs, cfg.keybindFont, "_vf_kb")
    end

    if fs and keyText ~= (fs._vf_lastText or "") then
        fs:SetText(keyText)
        fs._vf_lastText = keyText
    end

    if keyText and keyText ~= "" then
        button._vf_keybindFrame:Show()
    else
        button._vf_keybindFrame:Hide()
    end
    Profiler.stop(_pt)
end

-- =========================================================
-- SECTION 7: 遮罩层与冷却显示（系统增益时间 vs 技能冷却）
-- =========================================================

--- 供 GCD 剥离与仅技能冷却路径共用
local function GetButtonSpellIDForGcd(button)
    if not button then return nil end
    if button.GetSpellID then
        local id = button:GetSpellID()
        if id and (not issecretvalue or not issecretvalue(id)) and type(id) == "number" and id > 0 then
            return id
        end
    end
    if button.GetAuraSpellID then
        local id = button:GetAuraSpellID()
        if id and (not issecretvalue or not issecretvalue(id)) and type(id) == "number" and id > 0 then
            return id
        end
    end
    local cdID = button.cooldownID
    if cdID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
        if info then
            local spellID = info.linkedSpellIDs and info.linkedSpellIDs[1]
            spellID = spellID or info.overrideSpellID or info.spellID
            if spellID and spellID > 0 then
                return spellID
            end
        end
    end
    return nil
end

--- 重要/效能/自定义技能管理器图标（非 BUFF 监视器）
local function IsSkillCooldownManagerIcon(button)
    if not button then return false end
    if button._vf_cdmKind == "skill" then return true end
    local p = button:GetParent()
    local n = p and p.GetName and p:GetName()
    if type(n) ~= "string" then return false end
    if n == "EssentialCooldownViewer" or n == "UtilityCooldownViewer" then return true end
    if n:match("^VFlow_SkillGroup_%d+$") then return true end
    return false
end

--- 优先 button.cooldownInfo 的 spellID：关联 BUFF 激活时 GetSpellID/GetAuraSpellID 可能指向光环 ID
local function GetSpellIDForSpellOnlyCooldown(button)
    local info = button and button.cooldownInfo
    if info then
        local id = info.overrideSpellID or info.spellID
        if id and (not issecretvalue or not issecretvalue(id)) and type(id) == "number" and id > 0 then
            return id
        end
    end
    return GetButtonSpellIDForGcd(button)
end

--- Step 曲线：仅在技能真实冷却中维持去饱和
local spellOnlyDesatCurve
local function GetSpellOnlyDesatCurve()
    if spellOnlyDesatCurve then return spellOnlyDesatCurve end
    if not (C_CurveUtil and C_CurveUtil.CreateCurve and Enum and Enum.LuaCurveType) then
        return nil
    end
    local ok, c = pcall(function()
        local curve = C_CurveUtil.CreateCurve()
        curve:SetType(Enum.LuaCurveType.Step)
        curve:AddPoint(0, 0)
        curve:AddPoint(0.001, 1)
        return curve
    end)
    if ok and c then spellOnlyDesatCurve = c end
    return spellOnlyDesatCurve
end

--- StyleIcon.hideIconGCD
local function StyleIconWantsHideGcdSwipe()
    local db = VFlow.Store and VFlow.Store.getModuleRef and VFlow.Store.getModuleRef("VFlow.StyleIcon")
    return db and db.hideIconGCD == true
end

local SPELL_ONLY_GCD_SPELL_ID = 61304

--- SetUseAuraDisplayTime(false) + DurationObject；仅在 isOnGCD 且无 durObj 时 Clear，避免误清整块遮罩与读秒
local function ApplySpellOnlyCooldownDisplay(button)
    if not button._vf_hideBuffCooldownOverlay then return end
    if not IsSkillCooldownManagerIcon(button) then return end
    local cd = button.Cooldown
    if not cd then return end

    local spellID = GetSpellIDForSpellOnlyCooldown(button)
    if not spellID then return end

    local isOnGCD = button.isOnGCD == true
    local tex = button.Icon

    local hasChargeSource = type(button.HasVisualDataSource_Charges) == "function"
        and button:HasVisualDataSource_Charges()
    local chargeDurObj
    if hasChargeSource and C_Spell and C_Spell.GetSpellChargeDuration then
        local okCh, c = pcall(C_Spell.GetSpellChargeDuration, spellID)
        if okCh then chargeDurObj = c end
    end

    local durObj
    if C_Spell and C_Spell.GetSpellCooldownDuration then
        local okD, d = pcall(C_Spell.GetSpellCooldownDuration, spellID)
        if okD then durObj = d end
    end

    local cdInfo
    if C_Spell and C_Spell.GetSpellCooldown then
        local okI, inf = pcall(C_Spell.GetSpellCooldown, spellID)
        if okI and type(inf) == "table" then
            cdInfo = inf
        end
    end

    -- 仅 GCD、技能本身已就绪时 isActive 仍可能为 true，用 Step 曲线会得到满去饱和 → 误伤「未在冷却」的图标
    if tex and tex.SetDesaturation then
        if cdInfo and cdInfo.isOnGCD == true then
            tex:SetDesaturation(0)
        elseif durObj and not hasChargeSource and cdInfo and cdInfo.isActive and durObj.EvaluateRemainingDuration then
            local curve = GetSpellOnlyDesatCurve()
            if curve then
                local okEv, v = pcall(durObj.EvaluateRemainingDuration, durObj, curve, 0)
                tex:SetDesaturation((okEv and v) or 0)
            else
                tex:SetDesaturation(1)
            end
        else
            tex:SetDesaturation(0)
        end
    end

    if cd.SetUseAuraDisplayTime then
        pcall(cd.SetUseAuraDisplayTime, cd, false)
    end

    -- 技能/充能 CD 与仅 GCD 分离；仅 GCD 时用全局 GCD 法术（61304）的 DurationObject 画圈
    local apiGcdOnly = cdInfo and cdInfo.isOnGCD == true
    local wantGcdRing = isOnGCD or apiGcdOnly
    local appliedSpellCd = false

    if hasChargeSource and chargeDurObj and cd.SetCooldownFromDurationObject then
        pcall(cd.SetCooldownFromDurationObject, cd, chargeDurObj, true)
        if cd.SetDrawSwipe then pcall(cd.SetDrawSwipe, cd, true) end
        appliedSpellCd = true
    elseif durObj and cd.SetCooldownFromDurationObject and not apiGcdOnly then
        pcall(cd.SetCooldownFromDurationObject, cd, durObj, true)
        if cd.SetDrawSwipe then pcall(cd.SetDrawSwipe, cd, true) end
        appliedSpellCd = true
    end

    if not appliedSpellCd then
        if wantGcdRing and not StyleIconWantsHideGcdSwipe() then
            local gcdInfoG
            pcall(function()
                gcdInfoG = C_Spell.GetSpellCooldown(SPELL_ONLY_GCD_SPELL_ID)
            end)
            local gcdActive = false
            if gcdInfoG then
                if gcdInfoG.isActive ~= nil then
                    gcdActive = gcdInfoG.isActive == true
                elseif C_Spell.GetSpellCooldownDuration then
                    pcall(function()
                        gcdActive = C_Spell.GetSpellCooldownDuration(SPELL_ONLY_GCD_SPELL_ID) ~= nil
                    end)
                end
            end
            local gcdDurObj
            if C_Spell.GetSpellCooldownDuration then
                local okG, g = pcall(C_Spell.GetSpellCooldownDuration, SPELL_ONLY_GCD_SPELL_ID)
                if okG then gcdDurObj = g end
            end
            if gcdActive and gcdDurObj and cd.SetCooldownFromDurationObject then
                pcall(cd.SetCooldownFromDurationObject, cd, gcdDurObj, true)
                if cd.SetDrawSwipe then pcall(cd.SetDrawSwipe, cd, true) end
            elseif cd.Clear then
                pcall(cd.Clear, cd)
            end
        elseif cd.Clear then
            pcall(cd.Clear, cd)
        end
    end
end

--- 前向声明：SPELL_UPDATE_COOLDOWN 刷新路径需绑定本函数为 upvalue
local OnCooldownMaskDriverRefresh

local function SkillsModuleWantsSpellOnlyCooldown()
    local get = VFlow.Store and VFlow.Store.getModuleRef
    if not get then return false end
    local db = get("VFlow.Skills")
    if not db then return false end
    local function wants(c)
        return type(c) == "table" and c.hideBuffCooldownOverlay == true
    end
    if wants(db.importantSkills) or wants(db.efficiencySkills) then
        return true
    end
    for _, grp in ipairs(db.customGroups or {}) do
        if wants(grp and grp.config) then
            return true
        end
    end
    return false
end

local spellOnlyCdEventHooked
local spellOnlyCdFlushFrame
local function EnsureSpellOnlyCooldownSpellUpdateFlush()
    if spellOnlyCdEventHooked then return end
    spellOnlyCdEventHooked = true
    spellOnlyCdFlushFrame = CreateFrame("Frame")
    spellOnlyCdFlushFrame:Hide()
    spellOnlyCdFlushFrame:SetScript("OnUpdate", function(self)
        self:Hide()
        if not SkillsModuleWantsSpellOnlyCooldown() then return end
        local SL = VFlow.StyleLayout
        if not SL or not SL.CollectIcons then return end
        for _, name in ipairs({ "EssentialCooldownViewer", "UtilityCooldownViewer" }) do
            local viewer = _G[name]
            if viewer then
                local icons = SL.CollectIcons(viewer)
                for i = 1, #icons do
                    local b = icons[i]
                    if b and b._vf_hideBuffCooldownOverlay and IsSkillCooldownManagerIcon(b) then
                        OnCooldownMaskDriverRefresh(b)
                    end
                end
            end
        end
        if VFlow.SkillGroups and VFlow.SkillGroups.forEachGroupIcon then
            VFlow.SkillGroups.forEachGroupIcon(function(icon)
                if icon and icon._vf_hideBuffCooldownOverlay and IsSkillCooldownManagerIcon(icon) then
                    OnCooldownMaskDriverRefresh(icon)
                end
            end)
        end
    end)
    VFlow.on("SPELL_UPDATE_COOLDOWN", "VFlow.StyleApply.SpellOnlyCd", function()
        if not SkillsModuleWantsSpellOnlyCooldown() then return end
        spellOnlyCdFlushFrame:Show()
    end)
end

--- 技能监视器上主 Cooldown 是否正在显示「充能恢复」扇形（与充能层数恢复中的 DurationObject 一致）
local function SkillButtonChargeRechargeSwipeActive(button)
    if not button or not IsSkillCooldownManagerIcon(button) then return false end
    if type(button.HasVisualDataSource_Charges) ~= "function" or not button:HasVisualDataSource_Charges() then
        return false
    end
    local spellID = GetSpellIDForSpellOnlyCooldown(button)
    if not spellID then
        spellID = GetButtonSpellIDForGcd(button)
    end
    if not spellID or not C_Spell.GetSpellChargeDuration then return false end
    local ok, dur = pcall(C_Spell.GetSpellChargeDuration, spellID)
    return ok and dur ~= nil
end

local function ApplyCooldownMaskSwipeNow(self)
    local cd = self.Cooldown
    if not cd or not cd.SetSwipeColor then return end
    local hideBuff = self._vf_hideBuffCooldownOverlay and IsSkillCooldownManagerIcon(self)
    local color
    if self._vf_hideBuffCooldownOverlay and IsSkillCooldownManagerIcon(self) and SkillButtonChargeRechargeSwipeActive(self) then
        color = self._vf_chargeRechargeMaskColor or self._vf_cooldownMaskColor
    elseif hideBuff then
        color = self._vf_cooldownMaskColor
    elseif self.cooldownUseAuraDisplayTime and self._vf_buffMaskColor then
        color = self._vf_buffMaskColor
    else
        color = self._vf_cooldownMaskColor
    end
    if type(color) == "table" then
        cd:SetSwipeColor(color.r or 1, color.g or 1, color.b or 1, color.a or 1)
    end
end

OnCooldownMaskDriverRefresh = function(self)
    if self._vf_hideBuffCooldownOverlay and IsSkillCooldownManagerIcon(self) then
        ApplySpellOnlyCooldownDisplay(self)
    end
    ApplyCooldownMaskSwipeNow(self)
end

function StyleApply.ApplyAuraSwipeColor(button, groupCfg)
    local _pt = Profiler.start("SA:ApplyAuraSwipeColor")
    if not button or not groupCfg then Profiler.stop(_pt) return end

    button._vf_buffMaskColor = groupCfg.buffMaskColor
    button._vf_cooldownMaskColor = groupCfg.cooldownMaskColor
    button._vf_chargeRechargeMaskColor = groupCfg.chargeRechargeMaskColor
    button._vf_hideBuffCooldownOverlay = groupCfg.hideBuffCooldownOverlay == true

    if button._vf_hideBuffCooldownOverlay then
        EnsureSpellOnlyCooldownSpellUpdateFlush()
    end

    if not button._vf_refreshColorHooked then
        button._vf_refreshColorHooked = true
        if button.RefreshSpellCooldownInfo then
            hooksecurefunc(button, "RefreshSpellCooldownInfo", OnCooldownMaskDriverRefresh)
        end
        if button.RefreshCooldownInfo then
            hooksecurefunc(button, "RefreshCooldownInfo", OnCooldownMaskDriverRefresh)
        end
    end

    OnCooldownMaskDriverRefresh(button)
    Profiler.stop(_pt)
end

-- =========================================================
-- SECTION 8: ApplyButtonStyle（组配置总入口）
-- =========================================================

function StyleApply.ApplyButtonStyle(button, cfg)
    local _pt = Profiler.start("SA:ApplyButtonStyle")
    if not button or not cfg then Profiler.stop(_pt) return end

    if cfg.stackFont then
        local stackFS = StyleApply.GetStackFontString(button)
        if stackFS then
            local parent = stackFS:GetParent()
            if parent and parent.SetFrameLevel then
                local targetLevel = button:GetFrameLevel() + 7
                if parent:GetFrameLevel() ~= targetLevel then
                    parent:SetFrameLevel(targetLevel)
                end
            end
            if stackFS.GetDrawLayer and stackFS.SetDrawLayer then
                local layer, subLevel = stackFS:GetDrawLayer()
                if layer ~= "OVERLAY" or (subLevel or 0) < 7 then
                    stackFS:SetDrawLayer("OVERLAY", 7)
                end
            end
            StyleApply.ApplyFontStyle(stackFS, cfg.stackFont, "_vf_stack")
        end
    end

    if cfg.cooldownFont then
        local cdFS = StyleApply.GetCooldownFontString(button)
        StyleApply.ApplyFontStyle(cdFS, cfg.cooldownFont, "_vf_cd")
    end

    if cfg.showKeybind ~= nil then
        StyleApply.ApplyKeybind(button, cfg)
    end

    if cfg.buffMaskColor or cfg.cooldownMaskColor or cfg.chargeRechargeMaskColor or cfg.hideBuffCooldownOverlay then
        StyleApply.ApplyAuraSwipeColor(button, cfg)
    end

    -- 全局美化
    StyleApply.ApplyBeautify(button, cfg)

    if button._vf_refreshColorHooked then
        OnCooldownMaskDriverRefresh(button)
    end
    Profiler.stop(_pt)
end

--- 全局样式版本（VFlow._buttonStyleVersion）未变则跳过，避免热路径重复跑字体/美化
--- 调用方须先按需 ApplyIconSize；配置变更由 CooldownStyle BumpButtonStyleVersion 驱动
function StyleApply.ApplyButtonStyleIfStale(button, cfg)
    if not button or not cfg then return end
    local ver = VFlow._buttonStyleVersion or 0
    if button._vf_btnStyleVer == ver then return end
    StyleApply.ApplyButtonStyle(button, cfg)
    button._vf_btnStyleVer = ver
end

-- =========================================================
-- SECTION 9: 美化实现（缩放 / 边框 / 视觉隐藏）
-- =========================================================

local function GetAspectPreservingTexCoord(frameW, frameH, zoomPadding)
    if not frameH or frameH <= 0 then return 0, 1, 0, 1 end
    local padding = zoomPadding or 0
    local texWidth = 1 - (padding * 2)
    local aspectRatio = frameW / frameH
    local xRatio = aspectRatio < 1 and aspectRatio or 1
    local yRatio = aspectRatio > 1 and 1 / aspectRatio or 1
    local left   = -0.5 * texWidth * xRatio + 0.5
    local right  =  0.5 * texWidth * xRatio + 0.5
    local top    = -0.5 * texWidth * yRatio + 0.5
    local bottom =  0.5 * texWidth * yRatio + 0.5
    return left, right, top, bottom
end

local function GetMaskColorForButton(groupCfg)
    local color = groupCfg and groupCfg.cooldownMaskColor
    if type(color) ~= "table" then return 1, 1, 1, 1 end
    return color.r or 1, color.g or 1, color.b or 1, color.a or 1
end

-- 图标缩放 + Cooldown 锚点 + Swipe 纹理
local function ApplyIconZoom(button, groupCfg)
    local tex = button.Icon
    if not tex or not tex.SetTexCoord then return end

    local w, h = button:GetSize()
    local zoomAmount = styleCache.zoomIcons and styleCache.zoomAmount or 0

    local zoomKey = w .. "z" .. zoomAmount
    if button._vf_zoomKey ~= zoomKey then
        tex:SetTexCoord(GetAspectPreservingTexCoord(w, h, zoomAmount))
        button._vf_zoomKey = zoomKey
    end

    local cd = button.Cooldown
    if not cd then return end

    local sizeKey = w .. "x" .. h
    if button._vf_cdSizeKey ~= sizeKey then
        cd:ClearAllPoints()
        cd:SetAllPoints(button)
        button._vf_cdSizeKey = sizeKey
    end

    if cd.SetSwipeTexture then
        local target = styleCache.zoomIcons and WHITE8X8 or DEFAULT_SWIPE_TEXTURE
        if button._vf_swipeTex ~= target then
            cd:SetSwipeTexture(target)
            button._vf_swipeTex = target
        end
    end

    if cd.SetSwipeColor then
        local r, g, b, a = GetMaskColorForButton(groupCfg)
        if button._vf_swR ~= r or button._vf_swG ~= g or button._vf_swB ~= b or button._vf_swA ~= a then
            cd:SetSwipeColor(r, g, b, a)
            button._vf_swR = r; button._vf_swG = g; button._vf_swB = b; button._vf_swA = a
        end
    end

    if cd.SetDrawEdge then cd:SetDrawEdge(false) end
end

-- 遮罩与覆盖层移除
local function ApplyOverlayHides(button)
    local hideAtlas   = styleCache.hideIconOverlay
    local hideTexture = styleCache.hideIconOverlayTexture

    if button._vf_overlayAtlasHidden == hideAtlas
        and button._vf_overlayTextureHidden == hideTexture then
        return
    end

    for _, region in ipairs({ button:GetRegions() }) do
        if region and region.IsObjectType then
            if region:IsObjectType("Texture") then
                local atlas = region.GetAtlas and region:GetAtlas()
                if SafeEquals(atlas, BLIZZARD_ICON_OVERLAY_ATLAS) then
                    if hideAtlas then region:Hide() else region:Show() end
                end
                local texID = region.GetTexture and region:GetTexture()
                if SafeEquals(texID, BLIZZARD_ICON_OVERLAY_TEXTURE_FILE_ID) then
                    if hideTexture then region:Hide() else region:Show() end
                end
            elseif region:IsObjectType("MaskTexture") then
                local atlas = region.GetAtlas and region:GetAtlas()
                if SafeEquals(atlas, BLIZZARD_ICON_MASK_ATLAS) then
                    if hideTexture and button.Icon and button.Icon.RemoveMaskTexture
                        and not button._vf_maskRemoved then
                        button._vf_maskRemoved = true
                        pcall(button.Icon.RemoveMaskTexture, button.Icon, region)
                    end
                end
            end
        end
    end

    button._vf_overlayAtlasHidden   = hideAtlas
    button._vf_overlayTextureHidden = hideTexture
end

-- 边框
local function ApplyBorder(button)
    if VFlow.MasqueSupport and VFlow.MasqueSupport:IsActive() then
        if button._vf_border then button._vf_border:Hide() end
        return
    end

    local borderFile = styleCache.borderFile
    if not borderFile or borderFile == "None" or borderFile == "无" then
        if button._vf_border then button._vf_border:Hide() end
        return
    end

    local size    = styleCache.borderSize
    local offsetX = styleCache.borderOffsetX
    local offsetY = styleCache.borderOffsetY
    local color   = styleCache.borderColor or { r = 0, g = 0, b = 0, a = 1 }

    local borderKey = borderFile .. "|" .. size .. "|" .. offsetX .. "|" .. offsetY
        .. "|" .. (color.r or 0) .. (color.g or 0) .. (color.b or 0) .. (color.a or 1)
    if button._vf_borderKey == borderKey and button._vf_border then
        button._vf_border:Show()
        return
    end
    button._vf_borderKey = borderKey

    if not button._vf_border then
        local b = CreateFrame("Frame", nil, button, "BackdropTemplate")
        b:SetFrameLevel(button:GetFrameLevel() + 1)
        b:SetAllPoints(button)
        button._vf_border = b
    end

    local b = button._vf_border
    b:Show()

    local anchorOffsetX = offsetX
    local anchorOffsetY = offsetY

    if borderFile == "1PX" then
        b:SetBackdrop(nil)
        if PixelPerfect then
            PixelPerfect.CreateBorder(b, size, color, true)
            anchorOffsetX = PixelPerfect.PixelSnap(offsetX, button)
            anchorOffsetY = PixelPerfect.PixelSnap(offsetY, button)
        else
            b:SetBackdrop({ edgeFile = WHITE8X8, edgeSize = 1, bgFile = nil })
            b:SetBackdropBorderColor(color.r, color.g, color.b, color.a)
        end
    else
        if b._ppBorders then
            for _, border in ipairs(b._ppBorders) do border:Hide() end
        end
        local edgeFile = borderFile
        if LSM then
            local p = LSM:Fetch("border", borderFile)
            if p then edgeFile = p end
        end
        if edgeFile and not edgeFile:find("\\") then
            edgeFile = WHITE8X8
        end
        b:SetBackdrop({ edgeFile = edgeFile, edgeSize = size, bgFile = nil })
        b:SetBackdropBorderColor(color.r, color.g, color.b, color.a)
    end

    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", button, "TOPLEFT", -anchorOffsetX, anchorOffsetY)
    b:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", anchorOffsetX, -anchorOffsetY)
end

-- GCD 转圈隐藏：仅剥 isOnGCD；充能恢复中 GetSpellChargeDuration 有值时不剥（避免误伤充能圈）
local pendingHideGcdButtons = {}
local hideGcdFlushFrame = CreateFrame("Frame")
hideGcdFlushFrame:Hide()

local function HideIconGcdOptionEnabled()
    local db = VFlow.Store and VFlow.Store.getModuleRef and VFlow.Store.getModuleRef("VFlow.StyleIcon")
    return db and db.hideIconGCD == true
end

--- BUFF / 光环类 CD 不按GCD隐藏遮罩层
local function IsBuffAuraDurationCooldownIcon(button)
    if not button then return false end
    if button._vf_cdmKind == "buff" then return true end
    if button.cooldownUseAuraDisplayTime then return true end
    local p = button
    for _ = 1, 18 do
        if not p then break end
        local n = p.GetName and p:GetName()
        if type(n) == "string" then
            if n == "BuffIconCooldownViewer" or n == "BuffBarCooldownViewer" then
                return true
            end
            if n:match("^VFlow_BuffGroup_%d+$") then
                return true
            end
        end
        p = p.GetParent and p:GetParent()
    end
    return false
end

local function ApplyHideGcdSwipeIfNeeded(button)
    if not HideIconGcdOptionEnabled() or not button then return end
    if IsBuffAuraDurationCooldownIcon(button) then return end
    local cd = button.Cooldown
    if not cd or not cd.IsShown or not cd:IsShown() then return end
    local spellID = GetButtonSpellIDForGcd(button)
    if not spellID then return end
    if C_Spell and C_Spell.GetSpellChargeDuration then
        local okCh, chargeDur = pcall(function()
            return C_Spell.GetSpellChargeDuration(spellID)
        end)
        if okCh and chargeDur ~= nil then return end
    end
    local ok, cooldown = pcall(function()
        return C_Spell.GetSpellCooldown(spellID)
    end)
    if not ok or type(cooldown) ~= "table" or not cooldown.isOnGCD then return end
    if button.CooldownFlash and button.CooldownFlash:IsShown() then return end
    if cd.SetCooldownFromDurationObject and C_DurationUtil and C_DurationUtil.CreateDuration then
        cd:SetCooldownFromDurationObject(C_DurationUtil.CreateDuration())
    elseif cd.Clear then
        pcall(function()
            cd:Clear()
        end)
    end
end

local function QueueHideGcdSwipeApply(button)
    if not button then return end
    pendingHideGcdButtons[button] = true
    hideGcdFlushFrame:Show()
end

hideGcdFlushFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    local batch = pendingHideGcdButtons
    pendingHideGcdButtons = {}
    for b in pairs(batch) do
        if b and b.Icon then
            ApplyHideGcdSwipeIfNeeded(b)
        end
    end
end)

local function EnsureHideGcdCooldownHooks(button)
    if not button or button._vf_hook_hide_gcd_cd or not hooksecurefunc then return end
    local cd = button.Cooldown
    if not cd then return end
    button._vf_hook_hide_gcd_cd = true
    if cd.SetCooldown then
        hooksecurefunc(cd, "SetCooldown", function()
            QueueHideGcdSwipeApply(button)
        end)
    end
    if cd.SetCooldownFromDurationObject then
        hooksecurefunc(cd, "SetCooldownFromDurationObject", function()
            QueueHideGcdSwipeApply(button)
        end)
    end
end

-- 视觉隐藏（DebuffBorder / PandemicIcon / CooldownFlash）
-- hook 回调直接读 styleCache，不再调用 GetBeautifyConfig()
local function SetupVisualHideHooks(button)
    if button.DebuffBorder and not button._vf_hook_debuff then
        hooksecurefunc(button.DebuffBorder, "Show", function(self)
            if styleCache.hideDebuffBorder then self:Hide() end
        end)
        if button.DebuffBorder.UpdateFromAuraData then
            hooksecurefunc(button.DebuffBorder, "UpdateFromAuraData", function(self)
                if styleCache.hideDebuffBorder then self:Hide() end
            end)
        end
        button._vf_hook_debuff = true
    end

    if button.PandemicIcon and button.ShowPandemicStateFrame and not button._vf_hook_pandemic then
        hooksecurefunc(button, "ShowPandemicStateFrame", function(self)
            if styleCache.hidePandemicIndicator and self.PandemicIcon then
                self.PandemicIcon:Hide()
            end
        end)
        button._vf_hook_pandemic = true
    end

    if button.CooldownFlash and not button._vf_hook_bling then
        hooksecurefunc(button.CooldownFlash, "Show", function(self)
            if styleCache.hideCooldownBling then
                self:Hide()
                if self.FlashAnim then self.FlashAnim:Stop() end
            end
        end)
        if button.CooldownFlash.FlashAnim and button.CooldownFlash.FlashAnim.Play then
            hooksecurefunc(button.CooldownFlash.FlashAnim, "Play", function(self)
                if styleCache.hideCooldownBling then
                    self:Stop()
                    button.CooldownFlash:Hide()
                end
            end)
        end
        button._vf_hook_bling = true
    end
end

local function ApplyVisualHides(button)
    SetupVisualHideHooks(button)
    EnsureHideGcdCooldownHooks(button)

    if button.DebuffBorder and styleCache.hideDebuffBorder then
        button.DebuffBorder:Hide()
    end
    if button.PandemicIcon and styleCache.hidePandemicIndicator then
        button.PandemicIcon:Hide()
    end
    if button.CooldownFlash and styleCache.hideCooldownBling then
        button.CooldownFlash:Hide()
    end
end

function StyleApply.ApplyViewerItemVisualHides(itemFrame)
    if not itemFrame then return end
    RefreshStyleCache()
    ApplyVisualHides(itemFrame)
    local icon = itemFrame.Icon
    if icon and icon ~= itemFrame then
        ApplyVisualHides(icon)
    end
    if styleCache.hideIconGCD then
        QueueHideGcdSwipeApply(itemFrame)
        if icon and icon ~= itemFrame then
            QueueHideGcdSwipeApply(icon)
        end
    end
end

-- =========================================================
-- SECTION 10: ApplyBeautify 主入口
-- =========================================================

function StyleApply.ApplyBeautify(button, groupCfg)
    local _pt = Profiler.start("SA:ApplyBeautify")
    RefreshStyleCache()

    if button._vf_styleVer == styleCacheVersion then Profiler.stop(_pt) return end
    button._vf_styleVer = styleCacheVersion

    ApplyIconZoom(button, groupCfg)
    ApplyOverlayHides(button)
    ApplyBorder(button)
    ApplyVisualHides(button)
    if styleCache.hideIconGCD then
        QueueHideGcdSwipeApply(button)
    end
    Profiler.stop(_pt)
end

-- =========================================================
-- SECTION 11: 发光效果
-- =========================================================

local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
local GLOW_KEY = "VFlow_Glow"
-- 与系统 proc 替换发光（GLOW_KEY）分离，避免 HideAlert 时清掉自定义高亮
local CUSTOM_GLOW_KEY = "VFlow_CustomHL"

local glowCache = {
    type = "proc",
    useCustomColor = false,
    color = nil,
    pixelLines = 8, pixelFrequency = 0.2, pixelLength = 0,
    pixelThickness = 2, pixelXOffset = 0, pixelYOffset = 0,
    autocastParticles = 4, autocastFrequency = 0.2, autocastScale = 1,
    autocastXOffset = 0, autocastYOffset = 0,
    buttonFrequency = 0,
    procDuration = 1, procXOffset = 0, procYOffset = 0,
}

local activeGlowFrames = setmetatable({}, { __mode = "k" })
local activeCustomGlowFrames = setmetatable({}, { __mode = "k" })

local function GetGlowColor()
    if glowCache.useCustomColor and glowCache.color then
        local c = glowCache.color
        return { c.r or 1, c.g or 0.84, c.b or 0, c.a or 1 }
    end
    return nil
end

local function makeGlowStartFunctions(glowKey)
    return {
        pixel = function(frame, color, frameLevel)
            if not LCG then return end
            LCG.PixelGlow_Start(frame, color,
                glowCache.pixelLines, glowCache.pixelFrequency,
                glowCache.pixelLength, glowCache.pixelThickness,
                glowCache.pixelXOffset, glowCache.pixelYOffset, false, glowKey, frameLevel)
        end,
        autocast = function(frame, color, frameLevel)
            if not LCG then return end
            LCG.AutoCastGlow_Start(frame, color,
                glowCache.autocastParticles, glowCache.autocastFrequency,
                glowCache.autocastScale,
                glowCache.autocastXOffset, glowCache.autocastYOffset, glowKey, frameLevel)
        end,
        button = function(frame, color, frameLevel)
            if not LCG then return end
            LCG.ButtonGlow_Start(frame, color, glowCache.buttonFrequency, frameLevel)
        end,
        proc = function(frame, color, frameLevel)
            if not LCG then return end
            LCG.ProcGlow_Start(frame, {
                color = color,
                duration = glowCache.procDuration,
                startAnim = false,
                xOffset = glowCache.procXOffset,
                yOffset = glowCache.procYOffset,
                key = glowKey,
                frameLevel = frameLevel,
            })
        end,
    }
end

local function makeGlowStopFunctions(glowKey)
    return {
        pixel    = function(f) if LCG then LCG.PixelGlow_Stop(f, glowKey) end end,
        autocast = function(f) if LCG then LCG.AutoCastGlow_Stop(f, glowKey) end end,
        button   = function(f) if LCG then LCG.ButtonGlow_Stop(f) end end,
        proc     = function(f) if LCG then LCG.ProcGlow_Stop(f, glowKey) end end,
    }
end

local glowStartFunctions = makeGlowStartFunctions(GLOW_KEY)
local glowStopFunctions = makeGlowStopFunctions(GLOW_KEY)
local customGlowStartFunctions = makeGlowStartFunctions(CUSTOM_GLOW_KEY)
local customGlowStopFunctions = makeGlowStopFunctions(CUSTOM_GLOW_KEY)

function StyleApply.ShowGlow(frame)
    if not frame or not LCG then return end
    if frame._vf_glowActive then StyleApply.HideGlow(frame) end
    local color = GetGlowColor()
    local startFn = glowStartFunctions[glowCache.type]
    if startFn then
        local frameLevel = frame:GetFrameLevel() + 5
        startFn(frame, color, frameLevel)
        frame._vf_glowActive = true
        frame._vf_glowType = glowCache.type
        activeGlowFrames[frame] = true
    end
end

function StyleApply.HideGlow(frame)
    if not frame or not frame._vf_glowActive then return end
    local stopFn = glowStopFunctions[frame._vf_glowType]
    if stopFn then stopFn(frame) end
    frame._vf_glowActive = false
    frame._vf_glowType = nil
    activeGlowFrames[frame] = nil
end

function StyleApply.RefreshActiveGlows()
    local _pt = Profiler.start("SA:RefreshActiveGlows")
    for frame in pairs(activeGlowFrames) do
        if frame._vf_glowActive then
            StyleApply.HideGlow(frame)
            StyleApply.ShowGlow(frame)
        end
    end
    Profiler.stop(_pt)
end

function StyleApply.ShowCustomGlow(frame)
    if not frame or not LCG then return end
    -- 已以当前发光类型显示则不再重复 Start，避免动画被不断重置
    if frame._vf_customGlowActive and frame._vf_customGlowType == glowCache.type then
        return
    end
    if frame._vf_customGlowActive then StyleApply.HideCustomGlow(frame) end
    local color = GetGlowColor()
    local startFn = customGlowStartFunctions[glowCache.type]
    if startFn then
        local frameLevel = frame:GetFrameLevel() + 5
        startFn(frame, color, frameLevel)
        frame._vf_customGlowActive = true
        frame._vf_customGlowType = glowCache.type
        activeCustomGlowFrames[frame] = true
    end
end

function StyleApply.HideCustomGlow(frame)
    if not frame or not frame._vf_customGlowActive then return end
    local stopFn = customGlowStopFunctions[frame._vf_customGlowType]
    if stopFn then stopFn(frame) end
    frame._vf_customGlowActive = false
    frame._vf_customGlowType = nil
    activeCustomGlowFrames[frame] = nil
end

function StyleApply.RefreshActiveCustomGlows()
    local _pt = Profiler.start("SA:RefreshActiveCustomGlows")
    for frame in pairs(activeCustomGlowFrames) do
        if frame._vf_customGlowActive then
            StyleApply.HideCustomGlow(frame)
            StyleApply.ShowCustomGlow(frame)
        end
    end
    Profiler.stop(_pt)
end

function StyleApply.RefreshGlowCache()
    local db = VFlow.Store and VFlow.Store.getModuleRef and VFlow.Store.getModuleRef("VFlow.StyleGlow")
    if db then
        glowCache.type = db.glowType or "proc"
        glowCache.useCustomColor = db.useCustomColor or false
        glowCache.color = db.color

        glowCache.pixelLines = db.pixelLines or 8
        glowCache.pixelFrequency = db.pixelFrequency or 0.2
        glowCache.pixelLength = db.pixelLength or 0
        glowCache.pixelThickness = db.pixelThickness or 2
        glowCache.pixelXOffset = db.pixelXOffset or 0
        glowCache.pixelYOffset = db.pixelYOffset or 0

        glowCache.autocastParticles = db.autocastParticles or 4
        glowCache.autocastFrequency = db.autocastFrequency or 0.2
        glowCache.autocastScale = db.autocastScale or 1
        glowCache.autocastXOffset = db.autocastXOffset or 0
        glowCache.autocastYOffset = db.autocastYOffset or 0

        glowCache.buttonFrequency = db.buttonFrequency or 0

        glowCache.procDuration = db.procDuration or 1
        glowCache.procXOffset = db.procXOffset or 0
        glowCache.procYOffset = db.procYOffset or 0

        if not glowStartFunctions[glowCache.type] then
            glowCache.type = "proc"
        end
    end

    StyleApply.RefreshActiveGlows()
    StyleApply.RefreshActiveCustomGlows()
end

local function HideBlizzardGlow(frame)
    if not frame then return end
    local alert = frame.SpellActivationAlert
    if not alert then return end
    alert:SetAlpha(0)
    alert:Hide()
end

local function IsSupportedGlowFrame(frame)
    if not frame then return false end
    local parent = frame:GetParent()
    if not parent then return false end
    local parentName = parent:GetName()
    if not parentName then return false end
    return parentName == "EssentialCooldownViewer"
        or parentName == "UtilityCooldownViewer"
        or parentName == "BuffIconCooldownViewer"
end

local alertManagerHooked = false
function StyleApply.HookAlertManager()
    if alertManagerHooked then return end
    if not LCG then return end
    local alertManager = _G.ActionButtonSpellAlertManager
    if not alertManager then return end

    hooksecurefunc(alertManager, "ShowAlert", function(_, frame)
        if not IsSupportedGlowFrame(frame) then return end
        HideBlizzardGlow(frame)
        if frame._vf_glowActive and frame._vf_glowType == glowCache.type then return end
        StyleApply.ShowGlow(frame)
    end)

    hooksecurefunc(alertManager, "HideAlert", function(_, frame)
        if not IsSupportedGlowFrame(frame) then return end
        HideBlizzardGlow(frame)
        StyleApply.HideGlow(frame)
    end)

    alertManagerHooked = true
end

local function ScanActiveAlerts()
    local _pt = Profiler.start("SA:ScanActiveAlerts")
    local viewers = {
        _G["EssentialCooldownViewer"],
        _G["UtilityCooldownViewer"],
        _G["BuffIconCooldownViewer"],
    }
    for _, viewer in ipairs(viewers) do
        if viewer then
            for _, child in ipairs({ viewer:GetChildren() }) do
                if child and child.SpellActivationAlert
                    and child.SpellActivationAlert:IsShown() then
                    HideBlizzardGlow(child)
                    StyleApply.ShowGlow(child)
                end
            end
        end
    end
    Profiler.stop(_pt)
end

function StyleApply.InitializeGlow()
    StyleApply.RefreshGlowCache()
    StyleApply.HookAlertManager()
    ScanActiveAlerts()
end

-- =========================================================
-- SECTION 12: Store 监听与初始化
-- =========================================================

VFlow.Store.watch("VFlow.StyleGlow", "StyleApply_Glow", function()
    StyleApply.RefreshGlowCache()
end)

VFlow.Store.watch("VFlow.StyleIcon", "StyleApply_Style", function()
    StyleApply.InvalidateStyleCache()
end)

VFlow.on("PLAYER_LOGIN", "StyleApply_Glow", function()
    C_Timer.After(1, function()
        StyleApply.InitializeGlow()
    end)
end)

-- =========================================================
-- SECTION 1: 模块入口
-- CooldownStyle — 技能/BUFF 样式引擎
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local Utils = VFlow.Utils

local StyleApply = VFlow.StyleApply
local StyleLayout = VFlow.StyleLayout
local MasqueSupport = VFlow.MasqueSupport
local RefreshBus = VFlow.RefreshBus
local ViewerRuntime = VFlow.ViewerRuntime
local SkillViewModel = VFlow.SkillViewModel
local SkillLayoutPass = VFlow.SkillLayoutPass
local SkillGroupLayoutPass = VFlow.SkillGroupLayoutPass
local SkillStylePass = VFlow.SkillStylePass
local SkillPostPass = VFlow.SkillPostPass
local PP = VFlow.PixelPerfect
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
local abs = math.abs
local Profiler = VFlow.Profiler
local ViewerRefreshQueue = VFlow.ViewerRefreshQueue
local QK_ESSENTIAL = "EssentialCooldownViewer"
local QK_UTILITY = "UtilityCooldownViewer"
local QK_BUFF_ICONS = "BuffIconCooldownViewer"
local QK_BUFF_BAR = "BuffBarCooldownViewer"
local DoBuffRefresh
local RequestBuffRefresh
local RequestBuffBarRefresh
local DoBuffBarRefresh
local IsViewerReady
local customHLFlushOnUpdate
local viewerPhaseRegistered = false
local MAX_BUFF_READY_RETRIES = 20
local MAX_BUFFBAR_READY_RETRIES = 20
local skillRefreshPending = false

-- =========================================================
-- SECTION 2: 样式版本与 DB 缓存
-- =========================================================
local _buttonStyleVersion = 0
VFlow._buttonStyleVersion = _buttonStyleVersion

local function BumpButtonStyleVersion()
    _buttonStyleVersion = _buttonStyleVersion + 1
    VFlow._buttonStyleVersion = _buttonStyleVersion
end

local _buffBarStyleVersion = 0

local function BumpBuffBarStyleVersion()
    _buffBarStyleVersion = _buffBarStyleVersion + 1
end

-- =========================================================
-- 模块级 DB 引用缓存（避免热路径上反复 Store.getModuleRef）
-- =========================================================
local _cachedBuffsDB
local _cachedBuffBarDB

local function InvalidateDBCache()
    local store = VFlow and VFlow.Store
    if not store or not store.getModuleRef then return end
    _cachedBuffsDB  = store.getModuleRef("VFlow.Buffs")
    _cachedBuffBarDB = store.getModuleRef("VFlow.BuffBar")
end

local function GetBuffViewerAndConfig()
    local viewer = _G.BuffIconCooldownViewer
    local cfg = _cachedBuffsDB and _cachedBuffsDB.buffMonitor
    return viewer, cfg
end

local function GetBuffBarViewerAndConfig()
    local viewer = _G.BuffBarCooldownViewer
    return viewer, _cachedBuffBarDB
end

-- =========================================================
-- SECTION 3: Buff 条解析与帧收集
-- =========================================================

local function ResolveStatusBarTexture(textureName)
    if not textureName or textureName == "" or textureName == "默认" then
        return "Interface\\Buttons\\WHITE8X8"
    end
    if LSM then
        local path = LSM:Fetch("statusbar", textureName)
        if path then
            return path
        end
    end
    return textureName
end

local function ResolveBuffBarWidth(cfg)
    local width = cfg and cfg.barWidth or 200
    if not width or width <= 0 then
        return 200
    end
    return width
end

local function CollectBuffBarFrames(viewer)
    if not viewer then
        return {}
    end
    local frames = viewer._vf_cdf_bar_collect_work
    if not frames then
        frames = {}
        viewer._vf_cdf_bar_collect_work = frames
    else
        wipe(frames)
    end
    if viewer.itemFramePool then
        for frame in viewer.itemFramePool:EnumerateActive() do
            if frame and frame.IsShown and frame:IsShown() then
                frames[#frames + 1] = frame
            end
        end
    else
        for _, frame in ipairs({ viewer:GetChildren() }) do
            if frame and frame.IsShown and frame:IsShown() then
                frames[#frames + 1] = frame
            end
        end
    end
    Utils.sortByLayoutIndex(frames)
    return frames
end

-- =========================================================
-- SECTION 4: 自定义高亮（OtherFeatures / StyleGlow）
-- =========================================================

local OTHER_FEATURES_KEY = "VFlow.OtherFeatures"

local function GetOtherFeaturesDB()
    local store = VFlow.Store
    if not store or not store.getModuleRef then return nil end
    return store.getModuleRef(OTHER_FEATURES_KEY)
end

local function NormalizeOtherFeaturesHighlightSource(src)
    if src == "buff" then return "buff" end
    return "skill"
end

local function GetOtherFeaturesHighlightRule(spellID)
    if not spellID then return nil end
    local db = GetOtherFeaturesDB()
    if not db then return nil end
    local rules = db.highlightRules
    if not rules then return nil end
    local r = rules[spellID] or rules[tostring(spellID)]
    if type(r) ~= "table" or not r.enabled then return nil end
    return r
end

--- 默认 true（与模块 defaults 一致）；仅当显式为 false 时脱战也高亮
local function OtherFeaturesHighlightOnlyInCombat()
    local db = GetOtherFeaturesDB()
    if not db then return true end
    return db.highlightOnlyInCombat ~= false
end

local function IsPlayerInCombatForCustomHighlight()
    return UnitAffectingCombat and UnitAffectingCombat("player") == true
end

local function ResolveHighlightSpellID(frame)
    if not frame then return nil end
    if frame.GetSpellID then
        local id = frame:GetSpellID()
        if id and (not issecretvalue or not issecretvalue(id)) and type(id) == "number" and id > 0 then
            return id
        end
    end
    if frame.GetAuraSpellID then
        local id = frame:GetAuraSpellID()
        if id and (not issecretvalue or not issecretvalue(id)) and type(id) == "number" and id > 0 then
            return id
        end
    end
    if frame.cooldownID and StyleLayout.GetCachedCooldownViewerInfo then
        local info = StyleLayout.GetCachedCooldownViewerInfo(frame)
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

local function InferCdmKindFromParent(frame)
    local p = frame and frame:GetParent()
    if not p then return nil end
    local n = p:GetName()
    if n == "EssentialCooldownViewer" or n == "UtilityCooldownViewer" then return "skill" end
    if n == "BuffIconCooldownViewer" or n == "BuffBarCooldownViewer" then return "buff" end
    if n and n:match("^VFlow_SkillGroup_") then return "skill" end
    if n and n:match("^VFlow_BuffGroup_") then return "buff" end
    return nil
end

local function GetCdmFrameKind(frame)
    if not frame then return nil end
    if frame._vf_cdmKind == "skill" or frame._vf_cdmKind == "buff" then
        return frame._vf_cdmKind
    end
    return InferCdmKindFromParent(frame)
end

local function HighlightRuleMatchesKind(rule, kind)
    if not rule or not kind then return false end
    local src = rule.source
    if not src or src == "" then
        return true
    end
    if src == "skill" then return kind == "skill" end
    if src == "buff" then return kind == "buff" end
    return false
end

-- 与 CustomMonitorRuntime / ItemGroups 一致：仅受 GCD 锁时仍视为「可用」
local function SkillCooldownIsGcdOnly(spellID)
    if not spellID or not C_Spell or not C_Spell.GetSpellCooldown then return false end
    local ok, info = pcall(function() return C_Spell.GetSpellCooldown(spellID) end)
    if not ok or type(info) ~= "table" then return false end
    return info.isOnGCD == true
end

local function SkillIconAppearsReady(frame)
    if not frame or not frame:IsShown() then return false end
    local spellID = ResolveHighlightSpellID(frame)
    if spellID and SkillCooldownIsGcdOnly(spellID) then
        return true
    end
    local cd = frame.Cooldown
    if not cd or not cd.IsShown or not cd:IsShown() then return true end
    local ok, dur = pcall(function()
        return cd.GetCooldownDuration and cd:GetCooldownDuration()
    end)
    if not ok or dur == nil then return false end
    if type(dur) == "number" then
        if issecretvalue and issecretvalue(dur) then return false end
        return dur <= 0
    end
    return false
end

local function BuffIconAppearsActive(frame)
    if not frame or not frame:IsShown() then return false end
    local a = frame.GetAlpha and frame:GetAlpha()
    if type(a) == "number" and a < 0.05 then return false end
    return true
end

local function UpdateCustomHighlightForFrame(frame)
    if not StyleApply or not StyleApply.ShowCustomGlow or not StyleApply.HideCustomGlow then return end
    local kind = GetCdmFrameKind(frame)
    local spellID = ResolveHighlightSpellID(frame)
    local rule = spellID and GetOtherFeaturesHighlightRule(spellID)
    local wantGlow = false
    if rule and HighlightRuleMatchesKind(rule, kind) then
        if kind == "skill" then
            wantGlow = SkillIconAppearsReady(frame)
        elseif kind == "buff" then
            wantGlow = BuffIconAppearsActive(frame)
        end
    end
    if wantGlow and OtherFeaturesHighlightOnlyInCombat() and not IsPlayerInCombatForCustomHighlight() then
        wantGlow = false
    end
    if wantGlow then
        StyleApply.ShowCustomGlow(frame)
    else
        StyleApply.HideCustomGlow(frame)
    end
end

-- BUFF 激活瞬间会连续触发 CD 更新 / RefreshData / OnActiveStateChanged，合并到帧末只算一次，避免发光被反复打断。
-- 技能图标也必须延迟：SetCooldown hook 若在暴雪 RefreshData/充能缓存链内同步调用 C_Spell.GetSpellCooldown，
-- 会使 spellChargeInfo.maxCharges 等 secret 带上 VFlow 污染，触发 Blizzard_CooldownViewer CacheChargeValues 报错。
local pendingCustomHLBatch1, pendingCustomHLBatch2 = {}, {}
local pendingCustomHLFrames = pendingCustomHLBatch1
local customHLFlushFrame = CreateFrame("Frame")
customHLFlushFrame:Hide()
customHLFlushOnUpdate = function(self)
    self:Hide()
    for _ = 1, 12 do
        local batch = pendingCustomHLFrames
        if not next(batch) then break end
        pendingCustomHLFrames = (batch == pendingCustomHLBatch1) and pendingCustomHLBatch2 or pendingCustomHLBatch1
        for f in pairs(batch) do
            if f and f.Icon then
                UpdateCustomHighlightForFrame(f)
            end
        end
        wipe(batch)
    end
end
customHLFlushFrame:SetScript("OnUpdate", customHLFlushOnUpdate)

local function RequestCustomHighlightUpdate(frame)
    if not frame then return end
    pendingCustomHLFrames[frame] = true
    customHLFlushFrame:Show()
end

local function EnsureCustomHighlightHooks(frame)
    if not frame or frame._vf_customHLHooked then return end
    frame._vf_customHLHooked = true
    local cd = frame.Cooldown
    if cd and hooksecurefunc then
        if cd.SetCooldown then
            hooksecurefunc(cd, "SetCooldown", function()
                RequestCustomHighlightUpdate(frame)
            end)
        end
        if cd.SetCooldownFromDurationObject then
            hooksecurefunc(cd, "SetCooldownFromDurationObject", function()
                RequestCustomHighlightUpdate(frame)
            end)
        end
        if cd.Clear then
            hooksecurefunc(cd, "Clear", function()
                RequestCustomHighlightUpdate(frame)
            end)
        end
        if cd.HookScript then
            cd:HookScript("OnCooldownDone", function()
                RequestCustomHighlightUpdate(frame)
            end)
        end
    end
    if frame.HookScript then
        frame:HookScript("OnShow", function(self)
            RequestCustomHighlightUpdate(self)
        end)
        frame:HookScript("OnHide", function(self)
            pendingCustomHLFrames[self] = nil
            if StyleApply and StyleApply.HideCustomGlow then
                StyleApply.HideCustomGlow(self)
            end
        end)
    end
end

local function TouchCustomHighlight(frame)
    if not frame or not frame.Icon then return end
    EnsureCustomHighlightHooks(frame)
    RequestCustomHighlightUpdate(frame)
end

--- @param icons? table 若已在同次刷新中 CollectIcons，传入可避免二次收集
local function ScanCooldownViewerIcons(viewer, icons)
    if not viewer then return end
    local list = icons or StyleLayout.CollectIcons(viewer)
    for i = 1, #list do
        TouchCustomHighlight(list[i])
    end
end

local function ScanSkillGroupCustomHighlights()
    if VFlow.SkillGroups and VFlow.SkillGroups.forEachGroupIcon then
        VFlow.SkillGroups.forEachGroupIcon(function(icon)
            TouchCustomHighlight(icon)
        end)
    end
end

local function ScanBuffGroupCustomHighlights()
    if VFlow.BuffGroups and VFlow.BuffGroups.forEachGroupIcon then
        VFlow.BuffGroups.forEachGroupIcon(function(icon)
            TouchCustomHighlight(icon)
        end)
    end
end

local function RefreshAllOtherFeatureHighlights()
    ScanCooldownViewerIcons(_G.EssentialCooldownViewer)
    ScanCooldownViewerIcons(_G.UtilityCooldownViewer)
    ScanCooldownViewerIcons(_G.BuffIconCooldownViewer)
    ScanSkillGroupCustomHighlights()
    ScanBuffGroupCustomHighlights()
end

VFlow.on("PLAYER_REGEN_ENABLED", "VFlow.CustomHL.OutOfCombat", function()
    RefreshAllOtherFeatureHighlights()
end)
VFlow.on("PLAYER_REGEN_DISABLED", "VFlow.CustomHL.InCombat", function()
    RefreshAllOtherFeatureHighlights()
end)

local function IsSafeEqual(v, expected)
    if type(v) == "number" and issecretvalue and issecretvalue(v) then
        return false
    end
    return v == expected
end

local function HideIconOverlays(iconFrame)
    if not iconFrame then return end
    for _, region in ipairs({ iconFrame:GetRegions() }) do
        if region and region.IsObjectType and region:IsObjectType("Texture") then
            local atlas = region.GetAtlas and region:GetAtlas()
            local tex = region.GetTexture and region:GetTexture()
            if IsSafeEqual(atlas, "UI-HUD-CoolDownManager-IconOverlay") or IsSafeEqual(tex, 6707800) then
                region:Hide()
                region:SetAlpha(0)
            end
        end
    end
end

-- =========================================================
-- SECTION 5: BuffBar 辅助
-- =========================================================

local function QueueBuffBarRefresh(opt)
    opt = opt or {}
    local viewer = _G.BuffBarCooldownViewer
    if viewer and viewer._vf_refreshing then
        viewer._vf_needsReRefresh = true
        return
    end
    if ViewerRuntime and ViewerRuntime.request then
        ViewerRuntime.request(QK_BUFF_BAR, "manual", opt)
        return
    end
    RequestNamedViewers(RefreshBus.PRESETS.BUFFBAR_FULL, { QK_BUFF_BAR }, opt)
end

--- 一次性 hook：当配置隐藏某文本时，阻止系统 Show() 调用
local function HookBarTextVisibility(frame, hookKey, textElement, cfgKey)
    if not frame or not textElement or frame[hookKey] then return end
    frame[hookKey] = true
    hooksecurefunc(textElement, "Show", function(self)
        local localCfg = frame._vf_barCfg
        if localCfg and localCfg[cfgKey] == false then
            self:Hide()
        end
    end)
end

--- 确保 bar 有自定义背景纹理
local function EnsureBarBackground(bar)
    if not bar then return nil end
    if not bar._vf_bg then
        local bg = bar:CreateTexture(nil, "BACKGROUND", nil, -1)
        bg:ClearAllPoints()
        bg:SetAllPoints(bar)
        bar._vf_bg = bg
    end
    return bar._vf_bg
end

--- 确保 bar 有像素边框
local function EnsureBarBorder(bar)
    if not bar or not PP then return end
    if not bar._vf_borderFrame then
        local borderFrame = CreateFrame("Frame", nil, bar)
        borderFrame:SetAllPoints(bar)
        borderFrame:SetFrameLevel((bar:GetFrameLevel() or 1) + 2)
        bar._vf_borderFrame = borderFrame
    end
    PP.CreateBorder(bar._vf_borderFrame, 1, { r = 0, g = 0, b = 0, a = 1 }, true)
    PP.ShowBorder(bar._vf_borderFrame)
end

--- 应用样式到单个BuffBar帧
local function ApplyBuffBarFrameStyle(frame, cfg, frameWidth, frameHeight)
    if not frame or not cfg then return end

    -- 行帧不走路径 ApplyButtonStyle；需同步图标样式的 Debuff 红框 / 播疫 / CD 动画等隐藏（见 StyleApply.ApplyViewerItemVisualHides）
    StyleApply.ApplyViewerItemVisualHides(frame)

    local barStyleVer = _buffBarStyleVersion
    local iconPosition = cfg.iconPosition or "LEFT"

    -- 脏检查：版本+尺寸+图标位置均未变则跳过
    if frame._vf_barStyled
        and frame._vf_barStyleVer == barStyleVer
        and frame._vf_barW == frameWidth
        and frame._vf_barH == frameHeight
        and frame._vf_barIconPos == iconPosition
    then
        return
    end

    frame._vf_barCfg = cfg
    frame:SetSize(frameWidth, frameHeight)

    local icon = frame.Icon
    local bar = frame.Bar or frame.StatusBar
    local nameText = (bar and bar.Name) or frame.Name or frame.SpellName or frame.NameText
    local durationText = (bar and bar.Duration) or frame.Duration or frame.DurationText
        or StyleApply.GetCooldownFontString(frame)
    local appText = (icon and (icon.Applications or icon.Count))
        or StyleApply.GetStackFontString(frame)
        or frame.ApplicationsText

    local iconGap = cfg.iconGap or 0

    -- ===== 一次性隐藏系统默认元素 =====
    if not frame._vf_barHidesDone then
        if bar then
            if bar.BarBG then
                bar.BarBG:Hide()
                bar.BarBG:SetAlpha(0)
                if not frame._vf_barBGHooked then
                    frame._vf_barBGHooked = true
                    hooksecurefunc(bar.BarBG, "Show", function(self)
                        self:Hide()
                        self:SetAlpha(0)
                    end)
                end
            end
            if bar.Pip then
                bar.Pip:Hide()
                bar.Pip:SetAlpha(0)
                if not frame._vf_pipHooked then
                    frame._vf_pipHooked = true
                    hooksecurefunc(bar.Pip, "Show", function(self)
                        self:Hide()
                        self:SetAlpha(0)
                    end)
                end
            end
        end
        frame._vf_barHidesDone = true
    end

    -- ===== 图标 Show hook（一次性） =====
    if icon and not frame._vf_iconShowHooked then
        frame._vf_iconShowHooked = true
        hooksecurefunc(icon, "Show", function(self)
            local localCfg = frame._vf_barCfg
            if localCfg and localCfg.iconPosition == "HIDDEN" then
                self:Hide()
            end
        end)
    end

    -- ===== 图标布局 =====
    if bar and bar.ClearAllPoints then
        bar:ClearAllPoints()
        bar:SetHeight(frameHeight)

        if bar.SetStatusBarTexture then
            bar:SetStatusBarTexture(ResolveStatusBarTexture(cfg.barTexture))
        end
        if bar.SetStatusBarColor and cfg.barColor then
            local c = cfg.barColor
            bar:SetStatusBarColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)
        end

        if icon and iconPosition ~= "HIDDEN" then
            icon:Show()
            icon:SetSize(frameHeight, frameHeight)
            icon:ClearAllPoints()

            if iconPosition == "RIGHT" then
                icon:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
                bar:SetPoint("LEFT", frame, "LEFT", 0, 0)
                bar:SetPoint("RIGHT", icon, "LEFT", -iconGap, 0)
            else
                icon:SetPoint("LEFT", frame, "LEFT", 0, 0)
                bar:SetPoint("LEFT", icon, "RIGHT", iconGap, 0)
                bar:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
            end

            -- 图标纹理处理
            local iconTexture = icon.Icon
            if iconTexture then
                if iconTexture.ClearAllPoints then
                    iconTexture:ClearAllPoints()
                    iconTexture:SetAllPoints(icon)
                end
                if iconTexture.SetTexCoord then
                    iconTexture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                end
                -- 移除圆形遮罩
                for _, region in ipairs({ icon:GetRegions() }) do
                    if region and region.IsObjectType and region:IsObjectType("MaskTexture")
                        and iconTexture.RemoveMaskTexture then
                        pcall(iconTexture.RemoveMaskTexture, iconTexture, region)
                    end
                end
            end
            HideIconOverlays(icon)
        else
            -- 图标隐藏：bar占满整个帧
            bar:SetPoint("LEFT", frame, "LEFT", 0, 0)
            bar:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
            if icon then icon:Hide() end
        end
    elseif icon then
        if iconPosition == "HIDDEN" then
            icon:Hide()
        else
            icon:Show()
            icon:SetSize(frameHeight, frameHeight)
        end
    end

    -- ===== 背景 =====
    local bgTex = EnsureBarBackground(bar)
    if bgTex and cfg.barBackgroundColor then
        local bc = cfg.barBackgroundColor
        bgTex:SetTexture(ResolveStatusBarTexture(cfg.barTexture))
        bgTex:SetVertexColor(bc.r or 0.1, bc.g or 0.1, bc.b or 0.1, bc.a or 0.8)
        bgTex:Show()
    end

    -- ===== 边框 =====
    EnsureBarBorder(bar)

    -- ===== 文本容器 =====
    if bar and not frame._vf_barTextContainer then
        local tc = CreateFrame("Frame", nil, bar)
        tc:SetAllPoints(bar)
        tc:SetFrameLevel((bar:GetFrameLevel() or 1) + 4)
        frame._vf_barTextContainer = tc
    end
    local textContainer = frame._vf_barTextContainer

    -- ===== 名称文本 =====
    if nameText then
        HookBarTextVisibility(frame, "_vf_nameHook", nameText, "showName")
        if cfg.showName == false then
            nameText:Hide()
        else
            if textContainer then
                nameText:SetParent(textContainer)
                textContainer:Show()
            end
            nameText:Show()
            nameText:SetAlpha(1)
            if nameText.SetDrawLayer then
                nameText:SetDrawLayer("OVERLAY", 7)
            end
            StyleApply.ApplyFontStyle(nameText, cfg.nameFont, "_vf_bar_name")
        end
    end

    -- ===== 持续时间文本 =====
    if durationText then
        HookBarTextVisibility(frame, "_vf_durHook", durationText, "showDuration")
        if cfg.showDuration == false then
            durationText:Hide()
        else
            if textContainer then
                durationText:SetParent(textContainer)
                textContainer:Show()
            end
            durationText:Show()
            durationText:SetAlpha(1)
            if durationText.SetDrawLayer then
                durationText:SetDrawLayer("OVERLAY", 7)
            end
            StyleApply.ApplyFontStyle(durationText, cfg.durationFont, "_vf_bar_dur")
        end
    end

    -- ===== 层数文本=====
    if appText then
        HookBarTextVisibility(frame, "_vf_stackHook", appText, "showStack")
        if cfg.showStack == false then
            appText:Hide()
            if frame._vf_barAppContainer then
                frame._vf_barAppContainer:Hide()
            end
        else
            -- 确保层数文本容器存在（parent为bar，层级高于bar）
            if bar and not frame._vf_barAppContainer then
                local container = CreateFrame("Frame", nil, bar)
                container:SetAllPoints(bar)
                container:SetFrameLevel((bar:GetFrameLevel() or 1) + 4)
                frame._vf_barAppContainer = container
            end
            if frame._vf_barAppContainer then
                frame._vf_barAppContainer:Show()
                -- 将层数文本从icon重新parent到bar的子容器
                appText:SetParent(frame._vf_barAppContainer)
            end
            appText:Show()
            appText:SetAlpha(1)
            if appText.SetDrawLayer then
                appText:SetDrawLayer("OVERLAY", 7)
            end
            StyleApply.ApplyFontStyle(appText, cfg.stackFont, "_vf_bar_stack")
        end
    end

    -- 记录版本号
    frame._vf_barStyled = true
    frame._vf_barStyleVer = barStyleVer
    frame._vf_barW = frameWidth
    frame._vf_barH = frameHeight
    frame._vf_barIconPos = iconPosition
end

--- 收集→排序→样式→定位
local function RefreshBuffBarViewer(viewer, cfg)
    if not viewer or not cfg then return false end
    if viewer._vf_refreshing then
        viewer._vf_needsReRefresh = true
        return false
    end
    if not IsViewerReady(viewer) then return false end

    viewer._vf_refreshing = true
    viewer._vf_needsReRefresh = false

    local width = ResolveBuffBarWidth(cfg)
    local height = cfg.barHeight or 20
    local spacing = cfg.barSpacing or 1
    local barLevel = (viewer.GetFrameLevel and viewer:GetFrameLevel() or 0) + 1
    local frames = CollectBuffBarFrames(viewer)
    local count = #frames

    if count == 0 then
        local targetW = math.max(1, width)
        local targetH = math.max(1, height)
        if math.abs((viewer:GetWidth() or 0) - targetW) >= 0.1
            or math.abs((viewer:GetHeight() or 0) - targetH) >= 0.1 then
            viewer:SetSize(targetW, targetH)
        end
        viewer._vf_refreshing = false
        if viewer._vf_needsReRefresh then
            viewer._vf_needsReRefresh = false
            QueueBuffBarRefresh()
        end
        return true
    end

    local containerHeight = (count * height) + ((count - 1) * spacing)
    local targetH = math.max(height, containerHeight)
    if math.abs((viewer:GetWidth() or 0) - width) >= 0.1
        or math.abs((viewer:GetHeight() or 0) - targetH) >= 0.1 then
        viewer:SetSize(width, targetH)
    end

    for i = 1, count do
        local frame = frames[i]
        local offset = (i - 1) * (height + spacing)

        if frame:GetParent() ~= viewer then
            frame:SetParent(viewer)
        end
        if frame.SetFrameLevel then
            frame:SetFrameLevel(barLevel)
        end

        ApplyBuffBarFrameStyle(frame, cfg, width, height)

        -- BuffBar 当前临时仅支持“居中锚点下的固定排布”。方向配置先不启用，避免与系统 EditMode 锚点策略冲突。
        StyleLayout.SetPointCached(frame, "TOPLEFT", viewer, "TOPLEFT", 0, -offset)
        frame:SetAlpha(1)
    end

    viewer._vf_refreshing = false

    if viewer._vf_needsReRefresh then
        viewer._vf_needsReRefresh = false
        QueueBuffBarRefresh()
    end

    return true
end

-- =========================================================
-- SECTION 6: 技能 Viewer 刷新
-- =========================================================

local _lastLayoutNotifyEssWidth, _lastLayoutNotifyUtilWidth

local function GetSkillsDB()
    local get = VFlow and VFlow.Store and VFlow.Store.getModuleRef
    return get and get("VFlow.Skills")
end

local function ResolveSkillViewerAndConfig(viewerName)
    local db = GetSkillsDB()
    if not db then
        return nil, nil
    end
    if viewerName == "EssentialCooldownViewer" and EssentialCooldownViewer then
        return EssentialCooldownViewer, db.importantSkills
    end
    if viewerName == "UtilityCooldownViewer" and UtilityCooldownViewer then
        return UtilityCooldownViewer, db.efficiencySkills
    end
    return nil, nil
end

local function MergeSkillGroupBuckets(target, source)
    if not source then
        return
    end
    for groupIndex, bucket in pairs(source) do
        target[groupIndex] = target[groupIndex] or {}
        local out = target[groupIndex]
        for _, icon in ipairs(bucket) do
            out[#out + 1] = icon
        end
    end
end

local function EnsureSkillViewModels(context)
    context.skillViewModels = context.skillViewModels or {}
    context.skillGroupBuckets = context.skillGroupBuckets or {}

    for viewerName in pairs(context.dirtySkillViewers or {}) do
        if not context.skillViewModels[viewerName] then
            local viewer, cfg = ResolveSkillViewerAndConfig(viewerName)
            local viewModel = SkillViewModel and SkillViewModel.BuildViewModel and SkillViewModel.BuildViewModel(viewer, cfg)
            if viewModel then
                context.skillViewModels[viewerName] = viewModel
                MergeSkillGroupBuckets(context.skillGroupBuckets, viewModel.groupBuckets)
            end
        end
    end
end

local function RunSkillDataPhase(context)
    EnsureSkillViewModels(context)
end

local function RunSkillLayoutPhase(context)
    EnsureSkillViewModels(context)
    context.viewerLayoutResults = context.viewerLayoutResults or {}
    wipe(context.viewerLayoutResults)

    for viewerName in pairs(context.dirtySkillViewers or {}) do
        local viewModel = context.skillViewModels and context.skillViewModels[viewerName]
        local layoutResult = SkillLayoutPass and SkillLayoutPass.LayoutViewer and SkillLayoutPass.LayoutViewer(viewModel)
        if layoutResult then
            layoutResult.rowCells = viewModel.rowCells
            context.viewerLayoutResults[#context.viewerLayoutResults + 1] = layoutResult
        end
    end
end

local function RunSkillGroupLayoutPhase(context)
    if SkillGroupLayoutPass and SkillGroupLayoutPass.Layout then
        SkillGroupLayoutPass.Layout(context)
    end
end

local function RunSkillStylePhase(context)
    if SkillStylePass and SkillStylePass.Apply then
        SkillStylePass.Apply(context)
    end
end

local function RunSkillCooldownOnlyPhase()
    if SkillStylePass and SkillStylePass.RefreshCooldownOnly then
        SkillStylePass.RefreshCooldownOnly()
    end
end

local function ConsumeSkillViewerWidthChange(force)
    local ew = _G.EssentialCooldownViewer and _G.EssentialCooldownViewer:GetWidth() or 0
    local uw = _G.UtilityCooldownViewer and _G.UtilityCooldownViewer:GetWidth() or 0
    if not force
        and _lastLayoutNotifyEssWidth ~= nil
        and _lastLayoutNotifyUtilWidth ~= nil
        and math.abs(ew - _lastLayoutNotifyEssWidth) < 0.5
        and math.abs(uw - _lastLayoutNotifyUtilWidth) < 0.5 then
        return false
    end
    _lastLayoutNotifyEssWidth = ew
    _lastLayoutNotifyUtilWidth = uw
    return true
end

local function NotifySkillViewerLayoutDependents(force)
    if not ConsumeSkillViewerWidthChange(force) then
        return
    end
    if VFlow.ResourceBars and VFlow.ResourceBars.OnSkillViewerLayoutChanged then
        VFlow.ResourceBars.OnSkillViewerLayoutChanged()
    end
    if VFlow.CustomMonitorGroups and VFlow.CustomMonitorGroups.OnSkillViewerLayoutChanged then
        VFlow.CustomMonitorGroups.OnSkillViewerLayoutChanged()
    end
end

local RefreshSkillViewer

local function FinishSkillViewerRefresh(viewer)
    if not viewer then return end
    viewer._vf_refreshing = nil
    viewer._vf_needsReRefresh = nil
end

RefreshSkillViewer = function(viewer, cfg)
    if not viewer or not cfg then return end
    local context = {
        dirtySkillViewers = { [viewer:GetName()] = true },
        skillViewModels = {},
        skillGroupBuckets = {},
        viewerLayoutResults = {},
    }
    local viewModel = SkillViewModel and SkillViewModel.BuildViewModel and SkillViewModel.BuildViewModel(viewer, cfg)
    if not viewModel then
        return
    end
    context.skillViewModels[viewer:GetName()] = viewModel
    context.skillGroupBuckets = viewModel.groupBuckets or {}
    local layoutResult = SkillLayoutPass and SkillLayoutPass.LayoutViewer and SkillLayoutPass.LayoutViewer(viewModel)
    if layoutResult then
        layoutResult.rowCells = viewModel.rowCells
        context.viewerLayoutResults[1] = layoutResult
    end
    RunSkillGroupLayoutPhase(context)
    RunSkillStylePhase(context)
    if SkillPostPass and SkillPostPass.RunHighlights then
        SkillPostPass.RunHighlights(context)
    end
    if SkillPostPass and SkillPostPass.RunDependents then
        SkillPostPass.RunDependents(context)
    end
    FinishSkillViewerRefresh(viewer)
end

local function RegisterViewerRefreshPhases()
    if viewerPhaseRegistered or not RefreshBus then
        return
    end
    viewerPhaseRegistered = true

    RefreshBus.register(RefreshBus.SCOPES.SKILL_GROUP_MAP, "CooldownStyle_SkillGroupMap", RunSkillDataPhase)
    RefreshBus.register(RefreshBus.SCOPES.SKILL_DATA, "CooldownStyle_SkillData", RunSkillDataPhase)
    RefreshBus.register(RefreshBus.SCOPES.ITEM_APPEND_LAYOUT, "CooldownStyle_ItemAppend", RunSkillDataPhase)
    RefreshBus.register(RefreshBus.SCOPES.SKILL_LAYOUT, "CooldownStyle_SkillLayout", RunSkillLayoutPhase)
    RefreshBus.register(RefreshBus.SCOPES.SKILL_GROUP_LAYOUT, "CooldownStyle_SkillGroupLayout", RunSkillGroupLayoutPhase)
    RefreshBus.register(RefreshBus.SCOPES.SKILL_STYLE, "CooldownStyle_SkillStyle", RunSkillStylePhase)
    RefreshBus.register(RefreshBus.SCOPES.SKILL_COOLDOWN, "CooldownStyle_SkillCooldownOnly", function()
        RunSkillCooldownOnlyPhase()
    end)
    RefreshBus.register(RefreshBus.SCOPES.BUFF_LAYOUT, "CooldownStyle_BuffLayout", function(context)
        if context.dirtyViewers and context.dirtyViewers[QK_BUFF_ICONS] then
            DoBuffRefresh(0)
        end
    end)
    RefreshBus.register(RefreshBus.SCOPES.BUFFBAR_LAYOUT, "CooldownStyle_BuffBarLayout", function(context)
        if context.dirtyViewers and context.dirtyViewers[QK_BUFF_BAR] then
            DoBuffBarRefresh(0)
        end
    end)
    RefreshBus.register(RefreshBus.SCOPES.HIGHLIGHT, "CooldownStyle_Highlight", function(context)
        if SkillPostPass and SkillPostPass.RunHighlights then
            SkillPostPass.RunHighlights(context)
        end
    end)
    RefreshBus.register(RefreshBus.SCOPES.DEPENDENT_LAYOUT, "CooldownStyle_Dependents", function(context)
        if SkillPostPass and SkillPostPass.RunDependents then
            SkillPostPass.RunDependents(context)
        end
    end)
end

local function CopyRequestOpts(opts)
    local out = {}
    for key, value in pairs(opts or {}) do
        out[key] = value
    end
    return out
end

local function RequestSkillRefresh(scopeOrScopes, opts)
    if not (RefreshBus and RefreshBus.requestAllSkillViewers) then
        return
    end

    opts = opts or {}
    if opts.viewers then
        RefreshBus.requestSkillViewers(scopeOrScopes, opts.viewers, opts)
    else
        RefreshBus.requestAllSkillViewers(scopeOrScopes, opts)
    end
end

local function RequestDelayedSkillRefresh(delay, scopeOrScopes, opts)
    if delay and delay > 0 then
        if skillRefreshPending then
            return
        end
        skillRefreshPending = true
        C_Timer.After(delay, function()
            skillRefreshPending = false
            RequestSkillRefresh(scopeOrScopes, opts)
        end)
        return
    end
    RequestSkillRefresh(scopeOrScopes, opts)
end

local function RequestNamedViewers(scopeOrScopes, viewerNames, opts)
    if not (RefreshBus and RefreshBus.requestViewers) then
        return
    end
    RefreshBus.requestViewers(scopeOrScopes, viewerNames, opts or {})
end

VFlow.RequestSkillRefresh = RequestSkillRefresh
RegisterViewerRefreshPhases()

if SkillPostPass and SkillPostPass.registerHighlight then
    SkillPostPass.registerHighlight("CooldownStyle_SkillHighlightViewer", function(context)
        for _, layoutResult in ipairs(context.viewerLayoutResults or {}) do
            ScanCooldownViewerIcons(layoutResult.viewer, layoutResult.allIcons)
        end
        ScanSkillGroupCustomHighlights()
    end)
end

if SkillPostPass and SkillPostPass.registerDependent then
    SkillPostPass.registerDependent("CooldownStyle_SkillDependents", function(context)
        local force = context and context.flags and context.flags.forceDependentLayout
        NotifySkillViewerLayoutDependents(force == true)
    end)
end

-- =========================================================
-- SECTION 7: BUFF Viewer 刷新
-- =========================================================

IsViewerReady = function(viewer)
    if not viewer then return false end
    if viewer.IsInitialized and not viewer:IsInitialized() then return false end
    if EditModeManagerFrame and EditModeManagerFrame.layoutApplyInProgress then return false end
    return true
end

local function HideFrameOffscreen(frame)
    if not frame then return end
    frame:SetAlpha(0)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", -5000, 0)
end

local function ComputeReserveSlots(viewer, isH, w, h, spacingX, spacingY, iconLimit)
    local reserve = iconLimit or 20
    if reserve < 1 then reserve = 20 end

    if isH then
        local vw = viewer and viewer:GetWidth() or 0
        local step = w + spacingX
        if step > 0 and vw > 0 then
            local bySize = math.floor((vw + spacingX) / step)
            if bySize > reserve then reserve = bySize end
        end
        return reserve
    end

    local vh = viewer and viewer:GetHeight() or 0
    local step = h + spacingY
    if step > 0 and vh > 0 then
        local bySize = math.floor((vh + spacingY) / step)
        if bySize > reserve then reserve = bySize end
    end
    return reserve
end

local function ComputeSlotOffset(slot, totalSlots, isH, w, h, spacingX, spacingY, iconDir)
    if isH then
        local step = w + spacingX
        return (2 * slot - totalSlots + 1) * step / 2 * iconDir, 0
    end
    local step = h + spacingY
    return 0, (2 * slot - totalSlots + 1) * step / 2 * iconDir
end

local function RefreshBuffViewer(viewer, cfg)
    if not viewer or not cfg then return false end
    if viewer._vf_refreshing then
        viewer._vf_needsReRefresh = true
        return false
    end
    if not IsViewerReady(viewer) then return false end
    viewer._vf_refreshing = true

    local allIcons = StyleLayout.CollectIcons(viewer)

    local mainVisible, groupBuckets = {}, {}
    if VFlow.BuffGroups and VFlow.BuffGroups.classifyIcons then
        mainVisible, groupBuckets = VFlow.BuffGroups.classifyIcons(allIcons)
    else
        mainVisible = allIcons
    end

    local w = cfg.width or 40
    local h = cfg.height or 40
    local spacingX = cfg.spacingX or 2
    local spacingY = cfg.spacingY or 2
    local iconLimit = viewer.iconLimit or 20
    if iconLimit < 1 then iconLimit = 20 end

    local isH = (viewer.isHorizontal ~= false)
    local iconDir = (viewer.iconDirection == 1) and 1 or -1
    local minSize = 400

    if isH then
        local blockW = iconLimit * (w + spacingX) - spacingX
        local targetW = math.max(minSize, blockW)
        local curW = viewer:GetWidth()
        if not curW or abs(curW - targetW) >= 1 then
            viewer:SetSize(targetW, h)
        end
    else
        local blockH = iconLimit * (h + spacingY) - spacingY
        local targetH = math.max(minSize, blockH)
        local curH = viewer:GetHeight()
        if not curH or abs(curH - targetH) >= 1 then
            viewer:SetSize(w, targetH)
        end
    end

    local visible = {}
    local hasNilTex = false
    local maxLayoutSlot = 0
    for i = 1, #mainVisible do
        local icon = mainVisible[i]
        local slot = (icon.layoutIndex or i) - 1
        if slot > maxLayoutSlot then
            maxLayoutSlot = slot
        end

        local shown = icon:IsShown()
        if shown and not (icon.Icon and icon.Icon:GetTexture()) then
            hasNilTex = true
            if cfg.dynamicLayout then
                HideFrameOffscreen(icon)
            end
        elseif shown then
            visible[#visible + 1] = icon
        end
    end

    local count = #visible
    local reserveSlots = ComputeReserveSlots(viewer, isH, w, h, spacingX, spacingY, iconLimit)
    local totalSlots = reserveSlots
    if totalSlots < 1 then totalSlots = iconLimit end
    if cfg.dynamicLayout and count > totalSlots then totalSlots = count end
    local usedSlots = math.max(maxLayoutSlot + 1, count)
    if not cfg.dynamicLayout and usedSlots > totalSlots then
        totalSlots = usedSlots
    end
    local fixedSlotOffset = 0
    if not cfg.dynamicLayout then
        fixedSlotOffset = (totalSlots - usedSlots) / 2
    end

    local startSlot = 0
    if cfg.dynamicLayout then
        local growDir = cfg.growDirection or "center"
        if growDir == "center" then
            startSlot = (totalSlots - count) / 2
        elseif growDir == "end" then
            startSlot = totalSlots - count
        end
    end

    for i = 1, count do
        local button = visible[i]

        local slot = cfg.dynamicLayout and (startSlot + i - 1) or (((button.layoutIndex or i) - 1) + fixedSlotOffset)
        if slot < 0 then slot = 0 end
        button._vf_slot = slot

        local x, y = ComputeSlotOffset(slot, totalSlots, isH, w, h, spacingX, spacingY, iconDir)

        StyleApply.ApplyIconSize(button, w, h)
        -- BUFF 仍沿用旧链路（本轮重构重点是技能组刷新）；后续可单独将 BUFF 也接入 RefreshBus。
        StyleApply.ApplyButtonStyleIfStale(button, cfg)

        if MasqueSupport and MasqueSupport:IsActive() then
            MasqueSupport:RegisterButton(button, button.Icon)
        end

        button._vf_cdmKind = "buff"

        if button:GetParent() ~= viewer then
            button:SetParent(viewer)
        end

        StyleLayout.SetPointCached(button, "CENTER", viewer, "CENTER", x, y)
        button:SetAlpha(1)
    end

    if VFlow.BuffGroups and VFlow.BuffGroups.layoutBuffGroups then
        VFlow.BuffGroups.layoutBuffGroups(groupBuckets)
    end

    ScanCooldownViewerIcons(viewer, allIcons)
    ScanBuffGroupCustomHighlights()

    viewer._vf_refreshing = false

    if viewer._vf_needsReRefresh then
        viewer._vf_needsReRefresh = false
        if RequestBuffRefresh then
            RequestBuffRefresh()
        end
    end

    if hasNilTex then
        C_Timer.After(0.05, function()
            if RequestBuffRefresh then
                RequestBuffRefresh()
            end
        end)
    end

    return true
end

-- =========================================================
-- SECTION 8: Hooks & ViewerRefreshQueue
-- =========================================================

local hooked = false
local SetupHooks
DoBuffRefresh = function(attempt)
    local viewer, cfg = GetBuffViewerAndConfig()
    if not viewer or not cfg then
        return
    end
    if not IsViewerReady(viewer) then
        if (attempt or 0) < MAX_BUFF_READY_RETRIES then
            C_Timer.After(0.05, function()
                DoBuffRefresh((attempt or 0) + 1)
            end)
        end
        return
    end

    local ok = RefreshBuffViewer(viewer, cfg)
    if not ok then
        if viewer and viewer._vf_needsReRefresh then
            -- 重入已由 RefreshBuffViewer 标记，由当前刷新末尾再次入队
        elseif (attempt or 0) < MAX_BUFF_READY_RETRIES then
            C_Timer.After(0.05, function()
                DoBuffRefresh((attempt or 0) + 1)
            end)
        end
        return
    end
end

--- @param opt table|nil opt.immediate 为 true 时本帧立即刷新 Buff 图标（含自定义 Buff 组布局）
RequestBuffRefresh = function(opt)
    opt = opt or {}
    if ViewerRuntime and ViewerRuntime.request then
        ViewerRuntime.request(QK_BUFF_ICONS, "manual", opt)
        return
    end
    RequestNamedViewers(RefreshBus.PRESETS.BUFF_FULL, { QK_BUFF_ICONS }, opt)
end

DoBuffBarRefresh = function(attempt)
    local viewer, cfg = GetBuffBarViewerAndConfig()
    if not viewer or not cfg then
        return
    end
    if not IsViewerReady(viewer) then
        if (attempt or 0) < MAX_BUFFBAR_READY_RETRIES then
            C_Timer.After(0.05, function()
                DoBuffBarRefresh((attempt or 0) + 1)
            end)
        end
        return
    end

    local ok = RefreshBuffBarViewer(viewer, cfg)
    if not ok then
        if viewer and viewer._vf_needsReRefresh then
            -- 重入已由 RefreshBuffBarViewer 标记，由当前刷新末尾再次入队
        elseif (attempt or 0) < MAX_BUFFBAR_READY_RETRIES then
            C_Timer.After(0.05, function()
                DoBuffBarRefresh((attempt or 0) + 1)
            end)
        end
        return
    end
end

--- @param opt table|nil opt.immediate 为 true 时同帧刷新（RefreshData / Layout /池 Release）
RequestBuffBarRefresh = function(opt)
    QueueBuffBarRefresh(opt)
end

if Profiler and Profiler.registerCount then
    Profiler.registerCount("CDS:GetBuffViewerAndConfig", function()
        return GetBuffViewerAndConfig
    end, function(fn)
        GetBuffViewerAndConfig = fn
    end)
    Profiler.registerCount("CDS:GetBuffBarViewerAndConfig", function()
        return GetBuffBarViewerAndConfig
    end, function(fn)
        GetBuffBarViewerAndConfig = fn
    end)
    Profiler.registerCount("CDS:CollectBuffBarFrames", function()
        return CollectBuffBarFrames
    end, function(fn)
        CollectBuffBarFrames = fn
    end)
    Profiler.registerCount("CDS:DoBuffRefresh", function()
        return DoBuffRefresh
    end, function(fn)
        DoBuffRefresh = fn
    end)
    Profiler.registerCount("CDS:RequestBuffRefresh", function()
        return RequestBuffRefresh
    end, function(fn)
        RequestBuffRefresh = fn
    end)
    Profiler.registerCount("CDS:DoBuffBarRefresh", function()
        return DoBuffBarRefresh
    end, function(fn)
        DoBuffBarRefresh = fn
    end)
    Profiler.registerCount("CDS:RequestBuffBarRefresh", function()
        return RequestBuffBarRefresh
    end, function(fn)
        RequestBuffBarRefresh = fn
    end)
end

if Profiler and Profiler.registerScope then
    Profiler.registerScope("CDS:customHLFlush_OnUpdate", function()
        return customHLFlushOnUpdate
    end, function(fn)
        customHLFlushOnUpdate = fn
        customHLFlushFrame:SetScript("OnUpdate", fn)
    end)
    Profiler.registerScope("CDS:RefreshAllOtherFeatureHighlights", function()
        return RefreshAllOtherFeatureHighlights
    end, function(fn)
        RefreshAllOtherFeatureHighlights = fn
    end)
    Profiler.registerScope("CDS:RefreshBuffBarViewer", function()
        return RefreshBuffBarViewer
    end, function(fn)
        RefreshBuffBarViewer = fn
    end)
    Profiler.registerScope("CDS:RefreshSkillViewer", function()
        return RefreshSkillViewer
    end, function(fn)
        RefreshSkillViewer = fn
    end)
    Profiler.registerScope("CDS:RefreshBuffViewer", function()
        return RefreshBuffViewer
    end, function(fn)
        RefreshBuffViewer = fn
    end)
end

local function RequestInitialViewerRefresh()
    RequestSkillRefresh(RefreshBus.PRESETS.SKILL_FULL)

    local get = VFlow and VFlow.Store and VFlow.Store.getModuleRef
    local buffsDB = get and get("VFlow.Buffs")
    local buffBarDB = get and get("VFlow.BuffBar")

    if buffsDB and buffsDB.buffMonitor then
        RequestBuffRefresh()
    end

    if buffBarDB then
        RequestBuffBarRefresh()
    end
end

local function RequestKeybindStyleRefresh(delay)
    BumpButtonStyleVersion()
    RequestDelayedSkillRefresh(delay, RefreshBus.PRESETS.SKILL_STYLE)
end

VFlow.RequestKeybindStyleRefresh = RequestKeybindStyleRefresh

SetupHooks = function()
    if hooked then return end

    local queueBuffIconAfterHighlight
    queueBuffIconAfterHighlight = function(frame)
        if not frame then return end
        StyleLayout.InvalidateCooldownViewerInfoCache(frame)
        frame._vf_cdmKind = "buff"
        local viewer, cfg = GetBuffViewerAndConfig()
        if not viewer or not cfg then return end
        TouchCustomHighlight(frame)
        RequestBuffRefresh()
    end

    if Profiler and Profiler.registerCount then
        Profiler.registerCount("CDS:queueBuffIconAfterHighlight", function()
            return queueBuffIconAfterHighlight
        end, function(fn)
            queueBuffIconAfterHighlight = fn
        end)
    end

    local function enforceScaleOnViewer(viewer)
        if not viewer then return end
        if viewer.SetScale and viewer:GetScale() ~= 1 then
            viewer:SetScale(1)
        end
        if viewer.itemFramePool then
            for frame in viewer.itemFramePool:EnumerateActive() do
                if frame and frame.SetScale and frame:GetScale() ~= 1 then
                    frame:SetScale(1)
                end
            end
        end
    end

    local function HookSkillFrameForCustomHighlight(viewer, frame)
        if not frame then return end
        if viewer then StyleLayout.InvalidateCollectIconsCache(viewer) end
        frame._vf_cdmKind = "skill"
        if frame.OnCooldownIDSet and not frame._vf_skillCDHooked then
            frame._vf_skillCDHooked = true
            hooksecurefunc(frame, "OnCooldownIDSet", function(self)
                StyleLayout.InvalidateCooldownViewerInfoCache(self)
                TouchCustomHighlight(self)
            end)
        end
        EnsureCustomHighlightHooks(frame)
        TouchCustomHighlight(frame)
    end

    local function registerSkillViewer(name, enablePoolRelease)
        ViewerRuntime.register({
            name = name,
            lockViewerScale = true,
            lockFrameScale = true,
            invalidateCollectIcons = true,
            hookRefreshLayout = true,
            hookRefreshData = false,
            hookUpdateLayout = false,
            hookPoolRelease = enablePoolRelease == true,
            requestMap = {
                refreshLayout = RefreshBus.PRESETS.SKILL_LAYOUT,
                onShow = RefreshBus.PRESETS.SKILL_FULL,
                acquire = {
                    RefreshBus.SCOPES.SKILL_DATA,
                    RefreshBus.SCOPES.ITEM_APPEND_LAYOUT,
                    RefreshBus.SCOPES.SKILL_LAYOUT,
                    RefreshBus.SCOPES.SKILL_GROUP_LAYOUT,
                    RefreshBus.SCOPES.HIGHLIGHT,
                    RefreshBus.SCOPES.DEPENDENT_LAYOUT,
                },
                poolRelease = RefreshBus.PRESETS.SKILL_LAYOUT,
            },
            requestHandler = function(scopes, viewers, opts)
                local reqOpts = CopyRequestOpts(opts)
                reqOpts.viewers = viewers
                RequestSkillRefresh(scopes, reqOpts)
            end,
            onSetup = function(viewer)
                enforceScaleOnViewer(viewer)
                if viewer.UpdateSystemSettingIconSize then
                    hooksecurefunc(viewer, "UpdateSystemSettingIconSize", function()
                        enforceScaleOnViewer(viewer)
                    end)
                end
            end,
            onShow = function(viewer)
                enforceScaleOnViewer(viewer)
            end,
            onAcquireFrame = function(viewer, frame)
                HookSkillFrameForCustomHighlight(viewer, frame)
            end,
        })
    end

    registerSkillViewer(QK_ESSENTIAL, false)
    registerSkillViewer(QK_UTILITY, true)

    ViewerRuntime.register({
        name = QK_BUFF_ICONS,
        lockViewerScale = true,
        lockFrameScale = true,
        invalidateCollectIcons = true,
        hookRefreshLayout = true,
        hookRefreshData = true,
        hookUpdateLayout = true,
        requestMap = {
            manual = RefreshBus.PRESETS.BUFF_FULL,
            refreshLayout = RefreshBus.PRESETS.BUFF_FULL,
            refreshData = RefreshBus.PRESETS.BUFF_FULL,
            updateLayout = RefreshBus.PRESETS.BUFF_FULL,
            onShow = RefreshBus.PRESETS.BUFF_FULL,
            acquire = RefreshBus.PRESETS.BUFF_FULL,
        },
        requestHandler = function(scopes, viewers, opts)
            RequestNamedViewers(scopes, viewers, opts)
        end,
        onSetup = function(viewer)
            enforceScaleOnViewer(viewer)
        end,
        onAcquireFrame = function(_, frame)
            if frame.OnCooldownIDSet and not frame._vf_cdIDHooked then
                frame._vf_cdIDHooked = true
                hooksecurefunc(frame, "OnCooldownIDSet", function(self)
                    StyleLayout.InvalidateCooldownViewerInfoCache(self)
                    queueBuffIconAfterHighlight(self)
                end)
            end
            if frame.OnActiveStateChanged and not frame._vf_activeStateHooked then
                frame._vf_activeStateHooked = true
                hooksecurefunc(frame, "OnActiveStateChanged", function(self)
                    if not self then return end
                    self._vf_cdmKind = "buff"
                    TouchCustomHighlight(self)
                    RequestBuffRefresh()
                end)
            end
            frame._vf_cdmKind = "buff"
            TouchCustomHighlight(frame)
        end,
    })

    ViewerRuntime.register({
        name = QK_BUFF_BAR,
        lockViewerScale = false,
        lockFrameScale = true,
        invalidateCollectIcons = false,
        hookRefreshLayout = false,
        hookRefreshData = false,
        hookUpdateLayout = false,
        hookPoolRelease = true,
        requestMap = {
            manual = RefreshBus.PRESETS.BUFFBAR_FULL,
            onShow = RefreshBus.PRESETS.BUFFBAR_FULL,
            acquire = RefreshBus.PRESETS.BUFFBAR_FULL,
            poolRelease = RefreshBus.PRESETS.BUFFBAR_FULL,
        },
        requestHandler = function(scopes, viewers, opts)
            RequestNamedViewers(scopes, viewers, opts)
        end,
        onAcquireFrame = function(_, frame)
            local viewer, cfg = GetBuffBarViewerAndConfig()
            if not viewer or not cfg then return end

            if frame.SetScale then frame:SetScale(1) end

            if frame.OnActiveStateChanged and not frame._vf_buffBarActiveStateHooked then
                frame._vf_buffBarActiveStateHooked = true
                frame._vf_barLastShown = frame.IsShown and frame:IsShown() or false
                hooksecurefunc(frame, "OnActiveStateChanged", function(self)
                    if not self then return end
                    local shown = self.IsShown and self:IsShown() or false
                    if self._vf_barLastShown == shown then
                        return
                    end
                    self._vf_barLastShown = shown
                    RequestBuffBarRefresh()
                end)
            end

            frame._vf_barStyled = false
            frame._vf_barLastShown = frame.IsShown and frame:IsShown() or false
            ApplyBuffBarFrameStyle(frame, cfg, ResolveBuffBarWidth(cfg), cfg.barHeight or 20)
        end,
    })

    if CooldownViewerBuffIconItemMixin and CooldownViewerBuffIconItemMixin.OnCooldownIDSet then
        hooksecurefunc(CooldownViewerBuffIconItemMixin, "OnCooldownIDSet", function(frame)
            if frame then StyleLayout.InvalidateCooldownViewerInfoCache(frame) end
            queueBuffIconAfterHighlight(frame)
        end)
    end
    if EventRegistry then
        EventRegistry:RegisterCallback("CooldownViewerSettings.OnDataChanged", function()
            RequestDelayedSkillRefresh(0.2, RefreshBus.PRESETS.SKILL_FULL)
        end)
    end

    ViewerRuntime.setupAll()
    hooked = true
end

-- =========================================================
-- SECTION 9: 初始化
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "VFlow.SkillStyle", function()
    InvalidateDBCache()
    BumpButtonStyleVersion()
    BumpBuffBarStyleVersion()
    if ViewerRefreshQueue then ViewerRefreshQueue.bumpVersion() end
    SetupHooks()
    C_Timer.After(0.5, RequestInitialViewerRefresh)
end)

-- =========================================================
-- SECTION 10: Store 监听
-- =========================================================

local function IsSkillStyleConfigKey(key)
    if not key then return false end
    return key:find("font")
        or key:find("border")
        or key:find("overlay")
        or key:find("glow")
        or key:find("keybind")
        or key:find("zoom")
        or key:find("color")
        or key:find("mask")
end

local function IsSkillGroupMapConfigKey(key)
    if not key then return false end
    return key:find("%.spellIDs$")
        or key:find("^customGroups%.%d+%.config%.spellIDs")
        or key:find("%.hideInCooldownManager$")
end

VFlow.Store.watch("VFlow.Skills", "CooldownStyle_Skills", function(key, value)
    if key:find("^customGroups%.%d+%.config%.")
        and (key:find("%.x$") or key:find("%.y$")
            or key:find("%.anchorFrame$") or key:find("%.relativePoint$")
            or key:find("%.playerAnchorPosition$")) then
        local groupIndex = tonumber(key:match("^customGroups%.(%d+)%."))
        RequestSkillRefresh(RefreshBus.SCOPES.SKILL_GROUP_LAYOUT, {
            groupIndex = groupIndex,
            flags = { reanchorOnly = true },
        })
        return
    end
    if IsSkillStyleConfigKey(key) then
        BumpButtonStyleVersion()
        if SkillStylePass and SkillStylePass.Invalidate then
            SkillStylePass.Invalidate()
        end
        RequestSkillRefresh(RefreshBus.PRESETS.SKILL_STYLE)
        return
    end

    if IsSkillGroupMapConfigKey(key) then
        RequestSkillRefresh(RefreshBus.PRESETS.SKILL_GROUP_MAP)
        return
    end

    RequestSkillRefresh(RefreshBus.PRESETS.SKILL_LAYOUT)
end)

VFlow.Store.watch("VFlow.Buffs", "CooldownStyle_Buffs", function(key, value)
    InvalidateDBCache()
    if key:find("%.x$") or key:find("%.y$")
        or key:find("%.anchorFrame$") or key:find("%.relativePoint$") or key:find("%.playerAnchorPosition$") then
        return
    end
    BumpButtonStyleVersion()
    if ViewerRefreshQueue then ViewerRefreshQueue.bumpVersion() end
    RequestBuffRefresh()
end)

VFlow.Store.watch("VFlow.BuffBar", "CooldownStyle_BuffBar", function(key, value)
    InvalidateDBCache()
    BumpButtonStyleVersion()
    BumpBuffBarStyleVersion()
    if ViewerRefreshQueue then ViewerRefreshQueue.bumpVersion() end
    RequestBuffBarRefresh()
end)

VFlow.Store.watch("VFlow.CustomMonitor", "CooldownStyle_CustomMonitor", function(key, value)
    if key:find("%.hideInCooldownManager$") then
        RequestSkillRefresh(RefreshBus.PRESETS.SKILL_LAYOUT)
    end
end)

VFlow.Store.watch("VFlow.OtherFeatures", "CooldownStyle_OtherHL", function(key, _)
    if not key then return end
    if key == "skillRules" or key:find("^skillRules%.") then
        BumpButtonStyleVersion()
        RequestSkillRefresh({
            RefreshBus.SCOPES.SKILL_STYLE,
            RefreshBus.SCOPES.HIGHLIGHT,
        })
    end
    if key == "highlightRules" or key:find("^highlightRules%.")
        or key == "highlightOnlyInCombat" then
        RequestSkillRefresh(RefreshBus.PRESETS.SKILL_HIGHLIGHT, { immediate = false })
        C_Timer.After(0, RefreshAllOtherFeatureHighlights)
    end
end)

VFlow.Store.watch("VFlow.StyleIcon", "CooldownStyle_StyleIcon", function(key, value)
    BumpButtonStyleVersion()
    BumpBuffBarStyleVersion()
    if SkillStylePass and SkillStylePass.Invalidate then
        SkillStylePass.Invalidate()
    end
    RequestSkillRefresh(RefreshBus.PRESETS.SKILL_STYLE)
    RequestBuffRefresh()
    RequestBuffBarRefresh()
end)

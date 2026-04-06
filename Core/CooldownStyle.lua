-- =========================================================
-- SECTION 1: 模块入口
-- CooldownStyle — 技能/BUFF 样式引擎
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local Utils = VFlow.Utils

local StyleApply = VFlow.StyleApply
local StyleLayout = VFlow.StyleLayout
local BuffRuntime = VFlow.BuffRuntime
local BuffBarRuntime = VFlow.BuffBarRuntime
local MasqueSupport = VFlow.MasqueSupport
local PP = VFlow.PixelPerfect
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
local abs = math.abs
local Profiler = VFlow.Profiler
local RequestBuffRefresh
local RequestBuffBarRefresh
local IsViewerReady
local MAX_BUFF_READY_RETRIES = 20
local MAX_BUFFBAR_READY_RETRIES = 20

-- =========================================================
-- SECTION 2: 样式版本与 DB 缓存
-- =========================================================
local _buttonStyleVersion = 0
VFlow._buttonStyleVersion = _buttonStyleVersion

local function BumpButtonStyleVersion()
    _buttonStyleVersion = _buttonStyleVersion + 1
    VFlow._buttonStyleVersion = _buttonStyleVersion
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
    Profiler.count("CDS:GetBuffViewerAndConfig")
    local viewer = _G.BuffIconCooldownViewer
    local cfg = _cachedBuffsDB and _cachedBuffsDB.buffMonitor
    return viewer, cfg
end

local function GetBuffBarViewerAndConfig()
    Profiler.count("CDS:GetBuffBarViewerAndConfig")
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
    Profiler.count("CDS:CollectBuffBarFrames")
    if not viewer then
        return {}
    end
    local frames = {}
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

--- 当前正在设置页选中的法术：以 highlightForm 为准（运行时编辑态）；其余法术读持久化的 highlightRules
local function GetOtherFeaturesHighlightRule(spellID)
    if not spellID then return nil end
    local db = GetOtherFeaturesDB()
    if not db then return nil end
    local form = db.highlightForm
    local formSid = form and tonumber(form.spellId)
    if formSid == spellID then
        if not form.enabled then return nil end
        return {
            enabled = true,
            source = NormalizeOtherFeaturesHighlightSource(form.source),
        }
    end
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
    local cdID = frame.cooldownID
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
local pendingCustomHLFrames = {}
local customHLFlushFrame = CreateFrame("Frame")
customHLFlushFrame:Hide()
customHLFlushFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    local _pt = Profiler.start("CDS:customHLFlush_OnUpdate")
    -- 单次刷新可能再次触发 CD hook 入队，同帧内多轮消化直到稳定（有上限防死循环）
    for _ = 1, 12 do
        local batch = pendingCustomHLFrames
        if not next(batch) then break end
        pendingCustomHLFrames = {}
        for f in pairs(batch) do
            if f and f.Icon then
                UpdateCustomHighlightForFrame(f)
            end
        end
    end
    Profiler.stop(_pt)
end)

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
    local _pt = Profiler.start("CDS:RefreshAllOtherFeatureHighlights")
    ScanCooldownViewerIcons(_G.EssentialCooldownViewer)
    ScanCooldownViewerIcons(_G.UtilityCooldownViewer)
    ScanCooldownViewerIcons(_G.BuffIconCooldownViewer)
    ScanSkillGroupCustomHighlights()
    ScanBuffGroupCustomHighlights()
    local bb = _G.BuffBarCooldownViewer
    if bb then
        local frames = CollectBuffBarFrames(bb)
        for i = 1, #frames do
            local f = frames[i]
            f._vf_cdmKind = "buff"
            TouchCustomHighlight(f)
        end
    end
    Profiler.stop(_pt)
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

    local barStyleVer = BuffBarRuntime and BuffBarRuntime.getStyleVersion() or 0
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
    local _pt = Profiler.start("CDS:RefreshBuffBarViewer")
    if not viewer or not cfg then Profiler.stop(_pt) return false end
    if viewer._vf_refreshing then
        -- 标记需要再次刷新，避免丢失刷新请求
        viewer._vf_needsReRefresh = true
        Profiler.stop(_pt)
        return false
    end
    if not IsViewerReady(viewer) then Profiler.stop(_pt) return false end
    viewer._vf_refreshing = true
    viewer._vf_needsReRefresh = false

    -- 1. 收集可见帧并排序
    local frames = CollectBuffBarFrames(viewer)
    local count = #frames

    local width = ResolveBuffBarWidth(cfg)
    local height = cfg.barHeight or 20
    local spacing = cfg.barSpacing or 1
    local growDir = cfg.growDirection or "DOWN"

    if count == 0 then
        viewer:SetSize(math.max(1, width), math.max(1, height))
        viewer._vf_refreshing = false
        Profiler.stop(_pt)
        StyleLayout.InvalidateCollectIconsCache(viewer)
        return true
    end

    local containerHeight = (count * height) + ((count - 1) * spacing)
    viewer:SetSize(width, math.max(height, containerHeight))

    -- 2. 对每个帧：样式 → 定位 → 显示
    for i = 1, count do
        local frame = frames[i]
        local offset = (i - 1) * (height + spacing)

        -- 样式
        ApplyBuffBarFrameStyle(frame, cfg, width, height)

        -- 定位
        frame:ClearAllPoints()
        if growDir == "UP" then
            frame:SetPoint("BOTTOM", viewer, "BOTTOM", 0, offset)
        else
            frame:SetPoint("TOP", viewer, "TOP", 0, -offset)
        end

        -- 确保可见
        frame:SetAlpha(1)
    end

    viewer._vf_refreshing = false

    -- 如果刷新期间有新的刷新请求被阻塞，延迟再刷一次
    if viewer._vf_needsReRefresh then
        viewer._vf_needsReRefresh = false
        C_Timer.After(0, function()
            RefreshBuffBarViewer(viewer, cfg)
        end)
    end

    Profiler.stop(_pt)
    StyleLayout.InvalidateCollectIconsCache(viewer)
    return true
end

-- =========================================================
-- SECTION 6: 技能 Viewer 刷新
-- =========================================================

local _lastLayoutNotifyEssWidth, _lastLayoutNotifyUtilWidth

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

local function RefreshSkillViewer(viewer, cfg)
    local _pt = Profiler.start("CDS:RefreshSkillViewer")
    if not viewer or not cfg then Profiler.stop(_pt) return end
    if viewer._vf_refreshing then Profiler.stop(_pt) return end
    viewer._vf_refreshing = true

    local allIcons = StyleLayout.CollectIcons(viewer)

    -- 分类图标：将自定义组的图标分离出去
    local mainVisible, groupBuckets = {}, {}
    if VFlow.SkillGroups and VFlow.SkillGroups.classifyIcons then
        mainVisible, groupBuckets = VFlow.SkillGroups.classifyIcons(allIcons)
        -- 过滤主viewer的可见图标
        mainVisible = StyleLayout.FilterVisible(mainVisible)
    else
        -- 降级：所有图标都显示在主viewer
        mainVisible = StyleLayout.FilterVisible(allIcons)
    end

    if VFlow.ItemGroups and VFlow.ItemGroups.processSkillViewerIcons then
        mainVisible = select(1, VFlow.ItemGroups.processSkillViewerIcons(viewer, mainVisible))
        mainVisible = StyleLayout.FilterVisible(mainVisible)
    end

    local appendOnly = VFlow.ItemGroups and VFlow.ItemGroups.viewerHasAppendEntries
        and VFlow.ItemGroups.viewerHasAppendEntries(viewer)

    if #mainVisible == 0 and not appendOnly then
        -- 隐藏所有无纹理的空图标，避免显示黑框
        for _, icon in ipairs(allIcons) do
            if icon:IsShown() and not (icon.Icon and icon.Icon:GetTexture()) then
                icon:SetAlpha(0)
            end
        end
        viewer:SetSize(1, 1)
        if VFlow.SkillGroups and VFlow.SkillGroups.layoutSkillGroups then
            VFlow.SkillGroups.layoutSkillGroups(groupBuckets)
        end
        if VFlow.ItemGroups and VFlow.ItemGroups.refreshStandaloneLayouts then
            VFlow.ItemGroups.refreshStandaloneLayouts()
        end
        ScanCooldownViewerIcons(viewer, allIcons)
        ScanSkillGroupCustomHighlights()
        viewer._vf_refreshing = false
        Profiler.stop(_pt)
        StyleLayout.InvalidateCollectIconsCache(viewer)
        NotifySkillViewerLayoutDependents()
        return
    end

    local limit = cfg.maxIconsPerRow or 8
    local rows = StyleLayout.BuildRows(limit, mainVisible)
    local growUp = (cfg.growDirection == "up")

    local iconW = cfg.iconWidth or 40
    local iconH = cfg.iconHeight or 40
    local row2W = cfg.secondRowIconWidth or iconW
    local row2H = cfg.secondRowIconHeight or iconH

    local isH = (viewer.isHorizontal ~= false)
    local iconDir = (viewer.iconDirection == 1) and 1 or -1
    local spacingX = cfg.spacingX
    local spacingY = cfg.spacingY
    local fixedRowLengthByLimit = (cfg.fixedRowLengthByLimit == true)
    local rowAnchor = cfg.rowAnchor or "center"

    local rowCells
    if VFlow.ItemGroups and VFlow.ItemGroups.mergeSkillRowsWithAppend then
        rowCells = VFlow.ItemGroups.mergeSkillRowsWithAppend(viewer, limit, rows)
    else
        rowCells = {}
        for ri, rIcons in ipairs(rows) do
            rowCells[ri] = {}
            for _, icon in ipairs(rIcons) do
                rowCells[ri][#rowCells[ri] + 1] = { frame = icon, isItem = false }
            end
        end
    end

    -- 本 Viewer 无追加物品格时：清技能按钮上的样式/尺寸幂等缓存，避免刚从追加切回单独分组时仍沿用合并布局下的状态
    local hasItemCells = false
    for _, r in ipairs(rowCells) do
        for _, c in ipairs(r) do
            if c.isItem then
                hasItemCells = true
                break
            end
        end
        if hasItemCells then break end
    end
    if not hasItemCells then
        for _, icon in ipairs(mainVisible) do
            if not icon._vf_itemAppendFrame then
                icon._vf_btnStyleVer = nil
                icon._vf_styleVer = nil
                icon._vf_w = nil
                icon._vf_h = nil
                icon._vf_zoomKey = nil
                icon._vf_cdSizeKey = nil
            end
        end
    end

    local function cellWidth(_, rowIdx)
        return (rowIdx == 1) and iconW or row2W
    end

    local function cellHeight(_, rowIdx)
        return (rowIdx == 1) and iconH or row2H
    end

    local function rowContentWidth(rCells, rowIdx)
        local sum = 0
        for i, cell in ipairs(rCells) do
            sum = sum + cellWidth(cell, rowIdx)
            if i < #rCells then
                sum = sum + spacingX
            end
        end
        return sum
    end

    local rowContentWs = {}
    for ri, cells in ipairs(rowCells) do
        rowContentWs[ri] = rowContentWidth(cells, ri)
    end
    local rowBaseWs = {}
    for rowIdx, _ in ipairs(rowCells) do
        local wSkill = (rowIdx == 1) and iconW or row2W
        local rowContentW = rowContentWs[rowIdx] or 0
        local slotBandW = math.max(limit, 1) * (wSkill + spacingX) - spacingX
        if fixedRowLengthByLimit then
            rowBaseWs[rowIdx] = math.max(slotBandW, rowContentW)
        else
            rowBaseWs[rowIdx] = rowContentW
        end
    end
    local maxRowW = 0
    for _, rb in ipairs(rowBaseWs) do
        if rb > maxRowW then maxRowW = rb end
    end
    if not fixedRowLengthByLimit then
        for ri = 1, #rowCells do
            rowBaseWs[ri] = maxRowW
        end
    end

    local numRows = #rowCells
    -- 各行最大高度，用于「向上增长」时按槽位镜像 y，避免次行被摆到 viewer TOP 之外导致编辑框错位
    local rowHeights = {}
    for rowIdx, rCells in ipairs(rowCells) do
        local rowMaxH = 0
        for _, cell in ipairs(rCells) do
            local h = cellHeight(cell, rowIdx)
            if h > rowMaxH then rowMaxH = h end
        end
        rowHeights[rowIdx] = rowMaxH
    end
    local prefixY = { [0] = 0 }
    for i = 1, numRows do
        prefixY[i] = prefixY[i - 1] + rowHeights[i] + (i < numRows and spacingY or 0)
    end

    local xAccum = 0

    for rowIdx, rCells in ipairs(rowCells) do
        local rowContentW = rowContentWs[rowIdx] or 0
        local rowBaseW = rowBaseWs[rowIdx] or maxRowW

        local alignOffset = rowBaseW - rowContentW
        local anchorOffset = 0
        if rowAnchor == "right" then
            anchorOffset = alignOffset
        elseif rowAnchor == "center" then
            anchorOffset = alignOffset / 2
        end
        local startX = ((maxRowW - rowBaseW) / 2 + anchorOffset) * iconDir
        if iconDir == -1 then startX = -startX end

        local wRow = (rowIdx == 1) and iconW or row2W
        local hRow = (rowIdx == 1) and iconH or row2H
        local wSnap, strideX = wRow, (wRow + (spacingX or 0))
        local curX = startX
        local hSnap = hRow
        if isH and PP and PP.NormalizeColumnStride and PP.PixelSnap then
            wSnap, strideX = PP.NormalizeColumnStride(wRow, spacingX or 0, viewer)
            hSnap = PP.PixelSnap(hRow, viewer)
            curX = PP.PixelSnap(startX, viewer)
        end

        local rowMaxH = 0
        local rowMaxW = 0

        for colIdx, cell in ipairs(rCells) do
            local button = cell.frame
            if not button then
                -- skip
            else
                local w = cellWidth(cell, rowIdx)
                local h = cellHeight(cell, rowIdx)
                if h > rowMaxH then rowMaxH = h end
                if w > rowMaxW then rowMaxW = w end

                if isH then
                    StyleApply.ApplyIconSize(button, wSnap, hSnap)
                else
                    StyleApply.ApplyIconSize(button, w, h)
                end

                local x, y
                if isH then
                    x = curX
                    -- 向下：第 k 行 y = -prefixY[k-1]；向上增长：第 k 行占用向下模式中第 (n-k+1) 行的垂直槽位，整体仍在 TOP 锚点下方向下延伸
                    local downSlot = growUp and (numRows - rowIdx) or (rowIdx - 1)
                    y = -prefixY[downSlot]
                    curX = curX + strideX * iconDir
                else
                    y = -(colIdx - 1) * (h + spacingY) * iconDir
                    x = growUp and -xAccum or xAccum
                end

                StyleLayout.SetPointCached(button, "TOPLEFT", viewer, "TOPLEFT", x, y)
                if button:IsShown() then button:SetAlpha(1) end

                if cell.isItem then
                    StyleApply.ApplyButtonStyleIfStale(button, cfg)
                    if VFlow.ItemGroups and VFlow.ItemGroups.refreshAppendFrameStack then
                        VFlow.ItemGroups.refreshAppendFrameStack(button, cell.entry)
                    end
                    if MasqueSupport and MasqueSupport:IsActive() then
                        MasqueSupport:RegisterButton(button, button.Icon)
                    end
                    button._vf_cdmKind = "skill"
                else
                    StyleApply.ApplyButtonStyleIfStale(button, cfg)
                    if MasqueSupport and MasqueSupport:IsActive() then
                        MasqueSupport:RegisterButton(button, button.Icon)
                    end
                    button._vf_cdmKind = "skill"
                end
            end
        end

        if not isH then
            xAccum = xAccum + rowMaxW + spacingX
        end
    end

    -- Viewer 内未参与本次布局的池化按钮仍可能带着上次的 _vf_border/发光，停在默认位置 → 少技能时出现「多出来的边框」
    local laidOutFrames = {}
    for _, r in ipairs(rowCells) do
        for _, cell in ipairs(r) do
            local f = cell.frame
            if f then laidOutFrames[f] = true end
        end
    end
    if groupBuckets then
        for _, bucket in pairs(groupBuckets) do
            if bucket then
                for _, icon in ipairs(bucket) do
                    if icon then laidOutFrames[icon] = true end
                end
            end
        end
    end
    for _, icon in ipairs(allIcons) do
        if not laidOutFrames[icon] then
            if StyleApply.HideCustomGlow then StyleApply.HideCustomGlow(icon) end
            if StyleApply.HideGlow then StyleApply.HideGlow(icon) end
            if icon._vf_border then icon._vf_border:Hide() end
            -- 池化格只 Hide 了边框时，幂等版本仍是最新 → ApplyButtonStyleIfStale / ApplyBeautify 会跳过，切天赋复用按钮后边框不恢复
            icon._vf_btnStyleVer = nil
            icon._vf_styleVer = nil
            if icon:IsShown() and not (icon.Icon and icon.Icon:GetTexture()) then
                icon:SetAlpha(0)
            end
        end
    end

    local bboxIcons = {}
    for _, r in ipairs(rowCells) do
        for _, cell in ipairs(r) do
            local f = cell.frame
            if f and f:IsShown() then
                bboxIcons[#bboxIcons + 1] = f
            end
        end
    end
    StyleLayout.UpdateViewerSizeToMatchIcons(viewer, #bboxIcons > 0 and bboxIcons or mainVisible)
    -- 固定行长：图标按 maxRowW 居中，viewer 不能窄于该行宽，否则底框与 TOPLEFT+startX 的按钮错位
    if fixedRowLengthByLimit and isH and maxRowW > 0 then
        local vw = viewer:GetWidth()
        if vw and vw < maxRowW then
            viewer:SetWidth(maxRowW)
        end
    end

    -- 布局自定义技能组
    if VFlow.SkillGroups and VFlow.SkillGroups.layoutSkillGroups then
        VFlow.SkillGroups.layoutSkillGroups(groupBuckets)
    end

    if VFlow.ItemGroups and VFlow.ItemGroups.refreshStandaloneLayouts then
        VFlow.ItemGroups.refreshStandaloneLayouts()
    end

    ScanCooldownViewerIcons(viewer, allIcons)
    ScanSkillGroupCustomHighlights()

    viewer._vf_refreshing = false
    Profiler.stop(_pt)
    StyleLayout.InvalidateCollectIconsCache(viewer)
    NotifySkillViewerLayoutDependents()
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

local function ProvisionalPlaceBuffFrame(frame, viewer, cfg)
    Profiler.count("CDS:ProvisionalPlaceBuffFrame")
    if not frame or not viewer or not cfg then return end
    if not frame:IsShown() then return end
    if not (frame.Icon and frame.Icon:GetTexture()) then return end

    local w = cfg.width or 40
    local h = cfg.height or 40
    local spacingX = cfg.spacingX or 2
    local spacingY = cfg.spacingY or 2
    local iconLimit = viewer.iconLimit or 20
    if iconLimit < 1 then iconLimit = 20 end

    local isH = (viewer.isHorizontal ~= false)
    local iconDir = (viewer.iconDirection == 1) and 1 or -1

    local visible = StyleLayout.FilterVisible(StyleLayout.CollectIcons(viewer))
    local idx = nil
    for i = 1, #visible do
        if visible[i] == frame then idx = i break end
    end
    if not idx then
        visible[#visible + 1] = frame
        Utils.sortByLayoutIndex(visible)
        for i = 1, #visible do
            if visible[i] == frame then idx = i break end
        end
    end
    if not idx then return end

    local totalSlots = ComputeReserveSlots(viewer, isH, w, h, spacingX, spacingY, iconLimit)
    local slot
    if cfg.dynamicLayout then
        local count = #visible
        if count > totalSlots then totalSlots = count end
        local startSlot = 0
        local growDir = cfg.growDirection or "center"
        if growDir == "center" then
            startSlot = (totalSlots - count) / 2
        elseif growDir == "end" then
            startSlot = totalSlots - count
        end
        slot = startSlot + (idx - 1)
    else
        local rawSlot = (frame.layoutIndex or idx) - 1
        if rawSlot < 0 then rawSlot = 0 end
        local maxSlot = rawSlot
        for i = 1, #visible do
            local s = (visible[i].layoutIndex or i) - 1
            if s > maxSlot then maxSlot = s end
        end
        local usedSlots = math.max(maxSlot + 1, #visible)
        if usedSlots > totalSlots then totalSlots = usedSlots end
        local slotOffset = (totalSlots - usedSlots) / 2
        slot = rawSlot + slotOffset
    end

    local x, y = ComputeSlotOffset(slot, totalSlots, isH, w, h, spacingX, spacingY, iconDir)

    -- 1. 先应用样式（帧还在原parent下）
    StyleApply.ApplyIconSize(frame, w, h)
    StyleApply.ApplyButtonStyleIfStale(frame, cfg)
    frame._vf_slot = slot

    -- 2. 再改父级
    if frame:GetParent() ~= UIParent then
        frame:SetParent(UIParent)
    end

    -- 3. 最后定位
    StyleLayout.SetPointCached(frame, "CENTER", viewer, "CENTER", x, y)

    -- 主组图标挂在 UIParent 上，viewer:Hide() 不会级联隐藏，需单独跟踪
    viewer._vf_detachedBuffIcons = viewer._vf_detachedBuffIcons or {}
    local list = viewer._vf_detachedBuffIcons
    local dup
    for i = 1, #list do
        if list[i] == frame then dup = true break end
    end
    if not dup then
        list[#list + 1] = frame
    end
    if not viewer:IsShown() then
        frame:Hide()
    end
end

--- BUFF 图标为布局需要 parent 到 UIParent，需与 BuffIconCooldownViewer 显隐同步（VisibilityControl）
local function HideBuffIconsDetachedFromViewer(viewer)
    if not viewer or not viewer._vf_detachedBuffIcons then return end
    for _, icon in ipairs(viewer._vf_detachedBuffIcons) do
        if icon and icon.Hide and icon.GetParent and icon:GetParent() == UIParent then
            icon:Hide()
        end
    end
end

local function RefreshBuffViewer(viewer, cfg)
    local _pt = Profiler.start("CDS:RefreshBuffViewer")
    if not viewer or not cfg then Profiler.stop(_pt) return false end
    if viewer._vf_refreshing then Profiler.stop(_pt) return false end
    if not IsViewerReady(viewer) then Profiler.stop(_pt) return false end
    viewer._vf_refreshing = true

    local allIcons = StyleLayout.CollectIcons(viewer)

    -- 三路分类：主组可见、自定义组、隐藏
    local mainVisible, groupBuckets = {}, {}
    if VFlow.BuffGroups and VFlow.BuffGroups.classifyIcons then
        mainVisible, groupBuckets = VFlow.BuffGroups.classifyIcons(allIcons)
    else
        -- 降级：如果BuffGroups未加载，所有图标归主组
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

    viewer._vf_detachedBuffIcons = {}

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

    -- 过滤主组可见图标
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

    -- 应用样式到主组图标（先样式，后SetParent，最后定位）
    for i = 1, count do
        local button = visible[i]

        local slot = cfg.dynamicLayout and (startSlot + i - 1) or (((button.layoutIndex or i) - 1) + fixedSlotOffset)
        if slot < 0 then slot = 0 end
        button._vf_slot = slot

        local x, y = ComputeSlotOffset(slot, totalSlots, isH, w, h, spacingX, spacingY, iconDir)

        -- 1. 先应用样式（帧还在原parent下，避免样式操作触发UIParent下的重渲染）
        StyleApply.ApplyIconSize(button, w, h)
        StyleApply.ApplyButtonStyleIfStale(button, cfg)

        if MasqueSupport and MasqueSupport:IsActive() then
            MasqueSupport:RegisterButton(button, button.Icon)
        end

        button._vf_cdmKind = "buff"

        -- 2. 再改父级（样式已稳定，不会再触发重渲染）
        if button:GetParent() ~= UIParent then
            button:SetParent(UIParent)
        end

        -- 3. 最后定位并显示
        StyleLayout.SetPointCached(button, "CENTER", viewer, "CENTER", x, y)
        button:SetAlpha(1)
        viewer._vf_detachedBuffIcons[#viewer._vf_detachedBuffIcons + 1] = button
    end

    -- 布局自定义组（样式应用在LayoutBuffGroups内部完成）
    if VFlow.BuffGroups and VFlow.BuffGroups.layoutBuffGroups then
        VFlow.BuffGroups.layoutBuffGroups(groupBuckets)
    end

    if not viewer:IsShown() then
        HideBuffIconsDetachedFromViewer(viewer)
    end

    ScanCooldownViewerIcons(viewer, allIcons)
    ScanBuffGroupCustomHighlights()

    viewer._vf_refreshing = false

    if hasNilTex and RequestBuffRefresh then
        C_Timer.After(0.05, function()
            RequestBuffRefresh()
        end)
    end

    Profiler.stop(_pt)
    StyleLayout.InvalidateCollectIconsCache(viewer)
    return true
end

-- =========================================================
-- SECTION 8: Hook 与 BuffRuntime 桥接
-- =========================================================

local hooked = false
local refreshPending = false
local SetupHooks
local buffRefreshPending = false
local buffBarRefreshPending = false
local DoBuffRefresh
local DoBuffBarRefresh

local function SetupBuffRuntimeHandlers()
    if not BuffRuntime then return end

    BuffRuntime.setHandlers({
        getViewer = function()
            local viewer = GetBuffViewerAndConfig()
            return viewer
        end,
        getConfig = function()
            local _, cfg = GetBuffViewerAndConfig()
            return cfg
        end,
        collectVisible = function(viewer, isDirty)
            if isDirty then
                StyleLayout.InvalidateCollectIconsCache(viewer)
            end
            return StyleLayout.FilterVisible(StyleLayout.CollectIcons(viewer))
        end,
        refresh = function(viewer, cfg)
            RefreshBuffViewer(viewer, cfg)
        end,
    })
end

local function SetupBuffBarRuntimeHandlers()
    if not BuffBarRuntime then return end

    BuffBarRuntime.setHandlers({
        getViewer = function()
            local viewer = GetBuffBarViewerAndConfig()
            return viewer
        end,
        getConfig = function()
            local _, cfg = GetBuffBarViewerAndConfig()
            return cfg
        end,
        collectVisible = function(viewer, isDirty)
            if isDirty then
                StyleLayout.InvalidateCollectIconsCache(viewer)
            end
            return CollectBuffBarFrames(viewer)
        end,
        refresh = function(viewer, cfg)
            RefreshBuffBarViewer(viewer, cfg)
        end,
    })
end

DoBuffRefresh = function(attempt)
    Profiler.count("CDS:DoBuffRefresh")
    local viewer, cfg = GetBuffViewerAndConfig()
    if not viewer or not cfg then
        if BuffRuntime then BuffRuntime.disable() end
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
        if (attempt or 0) < MAX_BUFF_READY_RETRIES then
            C_Timer.After(0.05, function()
                DoBuffRefresh((attempt or 0) + 1)
            end)
        end
        return
    end

    if not BuffRuntime then return end
    BuffRuntime.markDirty()
    BuffRuntime.enable()
end

RequestBuffRefresh = function()
    Profiler.count("CDS:RequestBuffRefresh")
    if buffRefreshPending then return end
    buffRefreshPending = true
    C_Timer.After(0, function()
        buffRefreshPending = false
        DoBuffRefresh(0)
    end)
    -- followup 由 BuffRuntime.enable() 的 watchdog 机制保证，不再双重调度
end

DoBuffBarRefresh = function(attempt)
    Profiler.count("CDS:DoBuffBarRefresh")
    local viewer, cfg = GetBuffBarViewerAndConfig()
    if not viewer or not cfg then
        if BuffBarRuntime then BuffBarRuntime.disable() end
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
    if ok then
        local frames = CollectBuffBarFrames(viewer)
        for i = 1, #frames do
            local f = frames[i]
            f._vf_cdmKind = "buff"
            TouchCustomHighlight(f)
        end
    end
    if not ok and (attempt or 0) < MAX_BUFFBAR_READY_RETRIES then
        C_Timer.After(0.05, function()
            DoBuffBarRefresh((attempt or 0) + 1)
        end)
        return
    end

    if not BuffBarRuntime then return end

    -- 始终启用runtime监控
    BuffBarRuntime.markDirty()
    BuffBarRuntime.enable()
end

RequestBuffBarRefresh = function()
    Profiler.count("CDS:RequestBuffBarRefresh")
    if buffBarRefreshPending then return end
    buffBarRefreshPending = true
    -- 延迟到帧末尾执行，与Release合并，避免同一帧内重复刷新
    C_Timer.After(0, function()
        buffBarRefreshPending = false
        DoBuffBarRefresh(0)
    end)
end

local function DoRefresh()
    local skillsDB = VFlow and VFlow.Store and VFlow.Store.getModuleRef and VFlow.Store.getModuleRef("VFlow.Skills")
    local buffsDB = VFlow and VFlow.Store and VFlow.Store.getModuleRef and VFlow.Store.getModuleRef("VFlow.Buffs")
    local buffBarDB = VFlow and VFlow.Store and VFlow.Store.getModuleRef and VFlow.Store.getModuleRef("VFlow.BuffBar")

    if skillsDB then
        if EssentialCooldownViewer and skillsDB.importantSkills then
            RefreshSkillViewer(EssentialCooldownViewer, skillsDB.importantSkills)
        end
        if UtilityCooldownViewer and skillsDB.efficiencySkills then
            RefreshSkillViewer(UtilityCooldownViewer, skillsDB.efficiencySkills)
        end
    end

    if buffsDB and buffsDB.buffMonitor then
        RequestBuffRefresh()
    end

    if buffBarDB then
        RequestBuffBarRefresh()
    end
end

--- 供其他 Core（如 ItemGroups）在装备/法术变化时触发技能 viewer 重排
VFlow.RequestCooldownStyleRefresh = DoRefresh

local function RequestRefresh(delay)
    if delay and delay > 0 then
        if refreshPending then return end
        refreshPending = true
        C_Timer.After(delay, function()
            refreshPending = false
            DoRefresh()
        end)
    else
        DoRefresh()
    end
end

local function RequestKeybindStyleRefresh(delay)
    BumpButtonStyleVersion()
    RequestRefresh(delay)
end

VFlow.RequestKeybindStyleRefresh = RequestKeybindStyleRefresh

SetupHooks = function()
    if hooked then return end
    SetupBuffRuntimeHandlers()
    SetupBuffBarRuntimeHandlers()

    local function SafeHook(obj, method, handler)
        if obj and obj[method] then
            hooksecurefunc(obj, method, handler)
        end
    end

    local skillHandler = function() RequestRefresh(0) end
    local buffHandler = function() RequestBuffRefresh() end
    local buffBarHandler = function() RequestBuffBarRefresh() end

    -- 帧末尾合并刷新：同一帧内多次 BuffBar Release 只做一次 DoBuffBarRefresh
    -- Release 时帧可能尚未完全隐藏，延迟到帧末尾确保状态一致
    local _pendingBarSyncRefresh = false
    local _barSyncRefreshFrame = CreateFrame("Frame")
    _barSyncRefreshFrame:Hide()
    _barSyncRefreshFrame:SetScript("OnUpdate", function(self)
        self:Hide()
        _pendingBarSyncRefresh = false
        local _pt = Profiler.start("CDS:barSync_OnUpdate")
        DoBuffBarRefresh(0)
        Profiler.stop(_pt)
    end)

    local buffBarReleaseHandler = function()
        if BuffBarCooldownViewer then
            StyleLayout.InvalidateCollectIconsCache(BuffBarCooldownViewer)
        end
        if BuffBarRuntime then BuffBarRuntime.markDirty() end
        if not _pendingBarSyncRefresh then
            _pendingBarSyncRefresh = true
            _barSyncRefreshFrame:Show()
        end
    end

    -- 帧末尾合并刷新：同一帧内多次 provisionalPlaceAndQueue 只做一次 DoBuffRefresh
    local _pendingSyncRefresh = false
    local _syncRefreshFrame = CreateFrame("Frame")
    _syncRefreshFrame:Hide()
    _syncRefreshFrame:SetScript("OnUpdate", function(self)
        self:Hide()
        _pendingSyncRefresh = false
        local _pt = Profiler.start("CDS:buffSync_OnUpdate")
        DoBuffRefresh(0)
        Profiler.stop(_pt)
    end)

    local function QueueBuffSyncRefresh()
        if not _pendingSyncRefresh then
            _pendingSyncRefresh = true
            _syncRefreshFrame:Show()
        end
    end

    -- OnCooldownIDSet时：先ApplyStyle建立缓存，再ProvisionalPlace定位
    -- 确保样式初始化在定位之前完成，首次触发不会因样式操作触发重渲染
    local provisionalPlaceAndQueue = function(frame)
        Profiler.count("CDS:provisionalPlaceAndQueue")
        if not frame then return end
        frame._vf_cdmKind = "buff"
        local viewer, cfg = GetBuffViewerAndConfig()
        if not viewer or not cfg then return end
        -- 分组帧由BuffGroups自己管理，不走主组provisional逻辑
        if VFlow.BuffGroups and VFlow.BuffGroups.isGroupFrame and VFlow.BuffGroups.isGroupFrame(frame) then
            frame._vf_cdmKind = "buff"
            TouchCustomHighlight(frame)
            -- 与主组一致走帧末合并刷新
            QueueBuffSyncRefresh()
            return
        end
        StyleApply.ApplyIconSize(frame, cfg.width or 40, cfg.height or 40)
        StyleApply.ApplyButtonStyleIfStale(frame, cfg)
        ProvisionalPlaceBuffFrame(frame, viewer, cfg)
        TouchCustomHighlight(frame)
        -- 合并同一帧内的多次刷新：OnUpdate 在当前帧末尾触发一次 DoBuffRefresh
        QueueBuffSyncRefresh()
    end

    local function enforceScaleOnViewer(viewer)
        if not viewer then return end
        -- 强制viewer本身scale为1
        if viewer.SetScale and viewer:GetScale() ~= 1 then
            viewer:SetScale(1)
        end
        -- 强制pool中所有帧scale为1
        if viewer.itemFramePool then
            for frame in viewer.itemFramePool:EnumerateActive() do
                if frame and frame.SetScale and frame:GetScale() ~= 1 then
                    frame:SetScale(1)
                end
            end
        end
    end

    local function hookScaleForViewer(viewer)
        if not viewer or viewer._vf_scaleHooked then return end
        viewer._vf_scaleHooked = true
        -- hook OnAcquireItemFrame，每个帧出池时强制scale为1
        if viewer.OnAcquireItemFrame then
            hooksecurefunc(viewer, "OnAcquireItemFrame", function(_, frame)
                StyleLayout.InvalidateCollectIconsCache(viewer)
                if frame and frame.SetScale and frame:GetScale() ~= 1 then
                    frame:SetScale(1)
                end
            end)
        end
        -- hook UpdateSystemSettingIconSize，阻止系统scale设置生效
        if viewer.UpdateSystemSettingIconSize then
            hooksecurefunc(viewer, "UpdateSystemSettingIconSize", function()
                enforceScaleOnViewer(viewer)
                StyleLayout.InvalidateCollectIconsCache(viewer)
            end)
        end
        if viewer.itemFramePool then
            hooksecurefunc(viewer.itemFramePool, "Acquire", function()
                StyleLayout.InvalidateCollectIconsCache(viewer)
            end)
            hooksecurefunc(viewer.itemFramePool, "Release", function()
                StyleLayout.InvalidateCollectIconsCache(viewer)
            end)
        end
    end

    if EssentialCooldownViewer then
        SafeHook(EssentialCooldownViewer, "RefreshLayout", skillHandler)
        hookScaleForViewer(EssentialCooldownViewer)
        enforceScaleOnViewer(EssentialCooldownViewer)
    end
    if UtilityCooldownViewer then
        SafeHook(UtilityCooldownViewer, "RefreshLayout", skillHandler)
        hookScaleForViewer(UtilityCooldownViewer)
        enforceScaleOnViewer(UtilityCooldownViewer)
    end

    local function HookSkillFrameForCustomHighlight(viewer, frame)
        if not frame then return end
        if viewer then StyleLayout.InvalidateCollectIconsCache(viewer) end
        frame._vf_cdmKind = "skill"
        if frame.OnCooldownIDSet and not frame._vf_skillCDHooked then
            frame._vf_skillCDHooked = true
            hooksecurefunc(frame, "OnCooldownIDSet", function(self)
                TouchCustomHighlight(self)
            end)
        end
        EnsureCustomHighlightHooks(frame)
        TouchCustomHighlight(frame)
    end

    if EssentialCooldownViewer and EssentialCooldownViewer.OnAcquireItemFrame then
        SafeHook(EssentialCooldownViewer, "OnAcquireItemFrame", HookSkillFrameForCustomHighlight)
    end
    if UtilityCooldownViewer and UtilityCooldownViewer.OnAcquireItemFrame then
        SafeHook(UtilityCooldownViewer, "OnAcquireItemFrame", HookSkillFrameForCustomHighlight)
    end

    if BuffIconCooldownViewer then
        SafeHook(BuffIconCooldownViewer, "RefreshLayout", buffHandler)
        SafeHook(BuffIconCooldownViewer, "RefreshData", buffHandler)
        SafeHook(BuffIconCooldownViewer, "UpdateLayout", buffHandler)
        SafeHook(BuffIconCooldownViewer, "Layout", buffHandler)
        SafeHook(BuffIconCooldownViewer, "SetPoint", buffHandler)
        BuffIconCooldownViewer:HookScript("OnShow", buffHandler)
        BuffIconCooldownViewer:HookScript("OnHide", function(self)
            HideBuffIconsDetachedFromViewer(self)
        end)
        -- OnAcquireItemFrame：只做最少初始化，不做样式应用
        SafeHook(BuffIconCooldownViewer, "OnAcquireItemFrame", function(_, frame)
            if not frame then return end
            StyleLayout.InvalidateCollectIconsCache(BuffIconCooldownViewer)
            if frame.SetScale and frame:GetScale() ~= 1 then
                frame:SetScale(1)
            end
            -- 直接hook帧本身的OnCooldownIDSet（帧用的Mixin与CooldownViewerBuffIconItemMixin不同）
            if frame.OnCooldownIDSet and not frame._vf_cdIDHooked then
                frame._vf_cdIDHooked = true
                hooksecurefunc(frame, "OnCooldownIDSet", function(self)
                    provisionalPlaceAndQueue(self)
                end)
            end
            if frame.OnActiveStateChanged and not frame._vf_activeStateHooked then
                frame._vf_activeStateHooked = true
                hooksecurefunc(frame, "OnActiveStateChanged", function(self)
                    provisionalPlaceAndQueue(self)
                end)
            end
            frame._vf_cdmKind = "buff"
            TouchCustomHighlight(frame)
            QueueBuffSyncRefresh()
        end)

        if BuffIconCooldownViewer.itemFramePool then
            hooksecurefunc(BuffIconCooldownViewer.itemFramePool, "Acquire", function(pool, frame)
                StyleLayout.InvalidateCollectIconsCache(BuffIconCooldownViewer)
                -- 最早时机，修正Scale
                if frame and frame.SetScale and frame:GetScale() ~= 1 then
                    frame:SetScale(1)
                end
            end)
            hooksecurefunc(BuffIconCooldownViewer.itemFramePool, "Release", function()
                StyleLayout.InvalidateCollectIconsCache(BuffIconCooldownViewer)
                buffHandler()
            end)
        end
    end

    if BuffBarCooldownViewer then
        SafeHook(BuffBarCooldownViewer, "RefreshData", buffBarHandler)
        BuffBarCooldownViewer:HookScript("OnShow", buffBarHandler)

        SafeHook(BuffBarCooldownViewer, "OnAcquireItemFrame", function(_, frame)
            if not frame then return end
            StyleLayout.InvalidateCollectIconsCache(BuffBarCooldownViewer)
            local viewer, cfg = GetBuffBarViewerAndConfig()
            if not viewer or not cfg then return end

            -- 强制scale为1
            if frame.SetScale then frame:SetScale(1) end

            -- 立即应用样式（强制，因为帧可能是复用的）
            frame._vf_barStyled = false
            local width = ResolveBuffBarWidth(cfg)
            local height = cfg.barHeight or 20
            ApplyBuffBarFrameStyle(frame, cfg, width, height)

            -- 标记runtime脏
            if BuffBarRuntime then BuffBarRuntime.markDirty() end
        end)

        if BuffBarCooldownViewer.itemFramePool then
            hooksecurefunc(BuffBarCooldownViewer.itemFramePool, "Acquire", function()
                StyleLayout.InvalidateCollectIconsCache(BuffBarCooldownViewer)
            end)
            hooksecurefunc(BuffBarCooldownViewer.itemFramePool, "Release", buffBarReleaseHandler)
        end
    end

    if CooldownViewerBuffIconItemMixin then
        if CooldownViewerBuffIconItemMixin.OnCooldownIDSet then
            hooksecurefunc(CooldownViewerBuffIconItemMixin, "OnCooldownIDSet", function(frame)
                provisionalPlaceAndQueue(frame)
            end)
        end
        if CooldownViewerBuffIconItemMixin.OnActiveStateChanged then
            hooksecurefunc(CooldownViewerBuffIconItemMixin, "OnActiveStateChanged", function(frame)
                provisionalPlaceAndQueue(frame)
            end)
        end
    end

    -- BuffBar 的 Mixin hook
    if CooldownViewerBuffBarItemMixin then
        if CooldownViewerBuffBarItemMixin.OnCooldownIDSet then
            hooksecurefunc(CooldownViewerBuffBarItemMixin, "OnCooldownIDSet", function(frame)
                if not frame then return end
                local viewer, cfg = GetBuffBarViewerAndConfig()
                if not viewer or not cfg then return end
                -- 强制scale为1
                if frame.SetScale then frame:SetScale(1) end
                -- 立即对单帧应用样式
                frame._vf_barStyled = false
                local width = ResolveBuffBarWidth(cfg)
                local height = cfg.barHeight or 20
                ApplyBuffBarFrameStyle(frame, cfg, width, height)
                -- 确保帧可见（OnAcquire时可能还没Show，现在有内容了）
                frame:SetAlpha(1)
                -- 同步刷新全局布局
                DoBuffBarRefresh(0)
            end)
        end
        if CooldownViewerBuffBarItemMixin.OnActiveStateChanged then
            hooksecurefunc(CooldownViewerBuffBarItemMixin, "OnActiveStateChanged", function(frame)
                if not frame then return end
                frame._vf_barStyled = false
                DoBuffBarRefresh(0)
            end)
        end
        if CooldownViewerBuffBarItemMixin.SetBarContent then
            hooksecurefunc(CooldownViewerBuffBarItemMixin, "SetBarContent", function(frame)
                if not frame then return end
                frame._vf_barStyled = false
                -- SetBarContent 更新了文本内容（层数等），立即重新样式化
                local viewer, cfg = GetBuffBarViewerAndConfig()
                if viewer and cfg then
                    local width = ResolveBuffBarWidth(cfg)
                    local height = cfg.barHeight or 20
                    ApplyBuffBarFrameStyle(frame, cfg, width, height)
                end
                -- 确保帧可见
                frame:SetAlpha(1)
                DoBuffBarRefresh(0)
            end)
        end
    end

    if EventRegistry then
        EventRegistry:RegisterCallback("CooldownViewerSettings.OnDataChanged", function()
            RequestRefresh(0.2)
        end)
    end

    hooked = true
end

-- =========================================================
-- SECTION 9: 初始化
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "VFlow.SkillStyle", function()
    InvalidateDBCache()
    BumpButtonStyleVersion()
    if BuffBarRuntime then BuffBarRuntime.bumpStyleVersion() end
    SetupHooks()
    RequestRefresh(0.5)
end)

-- =========================================================
-- SECTION 10: Store 监听
-- =========================================================

-- 监听技能模块配置变更
VFlow.Store.watch("VFlow.Skills", "CooldownStyle_Skills", function(key, value)
    if key:find("%.x$") or key:find("%.y$")
        or key:find("%.anchorFrame$") or key:find("%.relativePoint$") or key:find("%.playerAnchorPosition$") then
        return
    end
    BumpButtonStyleVersion()
    RequestRefresh(0)
end)

-- 监听BUFF模块配置变更
VFlow.Store.watch("VFlow.Buffs", "CooldownStyle_Buffs", function(key, value)
    InvalidateDBCache()
    -- 仅容器位置/依附变化：不触发样式引擎刷新
    if key:find("%.x$") or key:find("%.y$")
        or key:find("%.anchorFrame$") or key:find("%.relativePoint$") or key:find("%.playerAnchorPosition$") then
        return
    end
    BumpButtonStyleVersion()
    RequestRefresh(0)
end)

VFlow.Store.watch("VFlow.BuffBar", "CooldownStyle_BuffBar", function(key, value)
    InvalidateDBCache()
    BumpButtonStyleVersion()
    if BuffBarRuntime then BuffBarRuntime.bumpStyleVersion() end
    RequestBuffBarRefresh()
end)

-- 监听自定义监控模块配置变更（隐藏功能）
VFlow.Store.watch("VFlow.CustomMonitor", "CooldownStyle_CustomMonitor", function(key, value)
    -- 只有hideInCooldownManager变化时才刷新
    if key:find("%.hideInCooldownManager$") then
        RequestRefresh(0)
    end
end)

-- 其他功能：自定义高亮
VFlow.Store.watch("VFlow.OtherFeatures", "CooldownStyle_OtherHL", function(key, _)
    if not key then return end
    if key == "highlightRules" or key:find("^highlightRules%.")
        or key == "highlightOnlyInCombat"
        or key == "highlightForm" or key:find("^highlightForm%.") then
        C_Timer.After(0, RefreshAllOtherFeatureHighlights)
    end
end)

-- 监听美化模块配置变更
VFlow.Store.watch("VFlow.StyleIcon", "CooldownStyle_StyleIcon", function(key, value)
    BumpButtonStyleVersion()
    RequestRefresh(0)
    RequestBuffBarRefresh()
end)

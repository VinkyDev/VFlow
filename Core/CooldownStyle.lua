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
local PP = VFlow.PixelPerfect
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
local abs = math.abs
local Profiler = VFlow.Profiler
local ViewerRefreshQueue = VFlow.ViewerRefreshQueue
local QK_ESSENTIAL = ViewerRefreshQueue and ViewerRefreshQueue.KEY_ESSENTIAL or "EssentialCooldownViewer"
local QK_UTILITY = ViewerRefreshQueue and ViewerRefreshQueue.KEY_UTILITY or "UtilityCooldownViewer"
local QK_BUFF_ICONS = ViewerRefreshQueue and ViewerRefreshQueue.KEY_BUFF_ICONS or "BuffIconCooldownViewer"
local QK_BUFF_BAR = ViewerRefreshQueue and ViewerRefreshQueue.KEY_BUFF_BAR or "BuffBarCooldownViewer"
local RequestBuffRefresh
local RequestBuffBarRefresh
local IsViewerReady
local customHLFlushOnUpdate
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

local function NormalizeBuffBarGrowDirection(cfg)
    local g = cfg and cfg.growDirection
    if type(g) == "string" and string.upper(g) == "UP" then
        return "UP"
    end
    return "DOWN"
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

local function IsBuffBarSystemEditModeActive()
    return EditModeManagerFrame and EditModeManagerFrame:IsEditModeActive() == true
end

--- Buff 条真实布局区域（挂到 UIParent，避免与 CDM viewer 尺寸互相牵制）
local function GetOrCreateBuffBarLayoutHost(viewer)
    if not viewer then return nil end
    local host = viewer._vf_buffBarLayoutHost
    if not host then
        if viewer._vf_buffBarLayoutRoot and viewer._vf_buffBarLayoutRoot.Hide then
            viewer._vf_buffBarLayoutRoot:Hide()
        end
        viewer._vf_buffBarLayoutRoot = nil
        host = CreateFrame("Frame", "VFlow_BuffBarLayoutHost", UIParent)
        host:SetClipsChildren(false)
        viewer._vf_buffBarLayoutHost = host
    end
    return host
end

--- 将帧当前屏幕角点写入 layoutPos
local function PersistBuffBarLayoutPosFromRegion(region, cfg, growDir)
    if not region or not cfg then return end
    local lp = cfg.layoutPos
    if type(lp) ~= "table" then
        lp = {}
        cfg.layoutPos = lp
    end
    local left = region.GetLeft and region:GetLeft()
    local top = region.GetTop and region:GetTop()
    local bottom = region.GetBottom and region:GetBottom()
    if type(left) ~= "number" or type(top) ~= "number" or type(bottom) ~= "number" then
        return
    end
    lp.mode = "corner"
    lp.cornerLeft = left
    if growDir == "UP" then
        lp.cornerY = bottom
    else
        lp.cornerY = top
    end
end

local function PersistBuffBarLayoutIfShown()
    local viewer, cfg = GetBuffBarViewerAndConfig()
    if not viewer or not cfg then return end
    if viewer.IsShown and not viewer:IsShown() then return end
    PersistBuffBarLayoutPosFromRegion(viewer, cfg, NormalizeBuffBarGrowDirection(cfg))
end

local function ApplyBuffBarHostUIParentLayoutFromCfg(host, cfg, growDir)
    local lp = cfg.layoutPos
    if type(lp) == "table" and lp.mode == "corner" and type(lp.cornerLeft) == "number" and type(lp.cornerY) == "number" then
        if growDir == "UP" then
            host:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", lp.cornerLeft, lp.cornerY)
        else
            host:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", lp.cornerLeft, lp.cornerY)
        end
    else
        local relPoint = (lp and lp.relPoint) or "CENTER"
        local x = (lp and lp.x) or 0
        local y = (lp and lp.y) or -280
        local hostPoint = (growDir == "UP") and "BOTTOM" or "TOP"
        host:SetPoint(hostPoint, UIParent, relPoint, x, y)
    end
end

local function ApplyBuffBarHostLayout(viewer, host, cfg, growDir, width, contentH)
    if not viewer or not host or not cfg then return end
    local w = math.max(1, width)
    local h = math.max(1, contentH)
    host:SetSize(w, h)
    local strata = viewer.GetFrameStrata and viewer:GetFrameStrata() or "MEDIUM"
    host:SetFrameStrata(strata)
    local vl = viewer:GetFrameLevel() or 0
    host:SetFrameLevel(vl + 2)

    host:SetParent(UIParent)
    host:ClearAllPoints()

    if IsBuffBarSystemEditModeActive() then
        local left = viewer.GetLeft and viewer:GetLeft()
        local top = viewer.GetTop and viewer:GetTop()
        local bottom = viewer.GetBottom and viewer:GetBottom()
        if type(left) == "number" and type(top) == "number" and type(bottom) == "number" then
            if growDir == "UP" then
                host:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
            else
                host:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
            end
        else
            ApplyBuffBarHostUIParentLayoutFromCfg(host, cfg, growDir)
        end
    else
        ApplyBuffBarHostUIParentLayoutFromCfg(host, cfg, growDir)
    end

    if viewer.IsShown and viewer:IsShown() then
        host:Show()
    else
        host:Hide()
    end
end

local function SyncBuffBarViewerToHostGeometry(viewer, host)
    if not viewer or not host or not viewer.SetAllPoints then return end
    if not host.IsShown or not host:IsShown() then return end
    viewer:SetAllPoints(host)
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
    local bb = _G.BuffBarCooldownViewer
    if bb then
        local frames = CollectBuffBarFrames(bb)
        for i = 1, #frames do
            local f = frames[i]
            f._vf_cdmKind = "buff"
            TouchCustomHighlight(f)
        end
    end
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
    local growDir = NormalizeBuffBarGrowDirection(cfg)

    if viewer.itemFramePool then
        for frame in viewer.itemFramePool:EnumerateActive() do
            if frame and frame.cooldownInfo and frame.IsShown and not frame:IsShown() then
                frame._vf_barStyled = false
                ApplyBuffBarFrameStyle(frame, cfg, width, height)
            end
        end
    end

    local frames = CollectBuffBarFrames(viewer)
    local count = #frames

    local host = GetOrCreateBuffBarLayoutHost(viewer)
    if not host then
        viewer._vf_refreshing = false
        return false
    end

    local barLevel = (host:GetFrameLevel() or 0) + 1

    if count == 0 then
        ApplyBuffBarHostLayout(viewer, host, cfg, growDir, width, height)
        SyncBuffBarViewerToHostGeometry(viewer, host)
        viewer._vf_refreshing = false
        if viewer._vf_needsReRefresh then
            viewer._vf_needsReRefresh = false
            if ViewerRefreshQueue then
                ViewerRefreshQueue.request(QK_BUFF_BAR, false)
            else
                C_Timer.After(0, function()
                    RefreshBuffBarViewer(viewer, cfg)
                end)
            end
        end
        StyleLayout.InvalidateCollectIconsCache(viewer)
        return true
    end

    local containerHeight = (count * height) + ((count - 1) * spacing)
    ApplyBuffBarHostLayout(viewer, host, cfg, growDir, width, math.max(height, containerHeight))

    for i = 1, count do
        local frame = frames[i]
        local offset = (i - 1) * (height + spacing)

        if frame:GetParent() ~= host then
            frame:SetParent(host)
        end
        if frame.SetFrameLevel then
            frame:SetFrameLevel(barLevel)
        end

        ApplyBuffBarFrameStyle(frame, cfg, width, height)

        frame:ClearAllPoints()
        if growDir == "UP" then
            frame:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, offset)
        else
            frame:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -offset)
        end

        frame:SetAlpha(1)
    end

    SyncBuffBarViewerToHostGeometry(viewer, host)

    viewer._vf_refreshing = false

    if viewer._vf_needsReRefresh then
        viewer._vf_needsReRefresh = false
        if ViewerRefreshQueue then
            ViewerRefreshQueue.request(QK_BUFF_BAR, false)
        else
            C_Timer.After(0, function()
                RefreshBuffBarViewer(viewer, cfg)
            end)
        end
    end

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

local RefreshSkillViewer

local function FinishSkillViewerRefresh(viewer)
    if not viewer then return end
    viewer._vf_refreshing = false
    NotifySkillViewerLayoutDependents()
    if not viewer._vf_needsReRefresh then return end
    viewer._vf_needsReRefresh = nil
    if ViewerRefreshQueue then
        local qk
        if viewer == EssentialCooldownViewer then
            qk = QK_ESSENTIAL
        elseif viewer == UtilityCooldownViewer then
            qk = QK_UTILITY
        end
        if qk then
            ViewerRefreshQueue.request(qk, false)
        end
    else
        local get = VFlow.Store and VFlow.Store.getModuleRef
        local skillsDB = get and get("VFlow.Skills")
        if viewer == EssentialCooldownViewer and skillsDB and skillsDB.importantSkills then
            RefreshSkillViewer(viewer, skillsDB.importantSkills)
        elseif viewer == UtilityCooldownViewer and skillsDB and skillsDB.efficiencySkills then
            RefreshSkillViewer(viewer, skillsDB.efficiencySkills)
        end
    end
end

RefreshSkillViewer = function(viewer, cfg)
    if not viewer or not cfg then return end
    if viewer._vf_refreshing then return end
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
    end

    local appendOnly = false
    if #mainVisible == 0 and VFlow.ItemGroups and VFlow.ItemGroups.viewerHasAppendEntries then
        appendOnly = VFlow.ItemGroups.viewerHasAppendEntries(viewer)
    end

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
        FinishSkillViewerRefresh(viewer)
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

    FinishSkillViewerRefresh(viewer)
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
        if ViewerRefreshQueue then
            ViewerRefreshQueue.request(QK_BUFF_ICONS, false)
        elseif RequestBuffRefresh then
            RequestBuffRefresh()
        end
    end

    if hasNilTex then
        C_Timer.After(0.05, function()
            if ViewerRefreshQueue then
                ViewerRefreshQueue.request(QK_BUFF_ICONS, false)
            elseif RequestBuffRefresh then
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
local refreshPending = false
local SetupHooks
local DoBuffRefresh
local DoBuffBarRefresh

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
    if ViewerRefreshQueue then
        ViewerRefreshQueue.request(QK_BUFF_ICONS, opt.immediate == true)
    else
        DoBuffRefresh(0)
    end
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
    if ok then
        local frames = CollectBuffBarFrames(viewer)
        for i = 1, #frames do
            local f = frames[i]
            f._vf_cdmKind = "buff"
            TouchCustomHighlight(f)
        end
    end
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
    opt = opt or {}
    if ViewerRefreshQueue then
        ViewerRefreshQueue.request(QK_BUFF_BAR, opt.immediate == true)
    else
        DoBuffBarRefresh(0)
    end
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

local function DoRefresh()
    local get = VFlow and VFlow.Store and VFlow.Store.getModuleRef
    local buffsDB = get and get("VFlow.Buffs")
    local buffBarDB = get and get("VFlow.BuffBar")

    if ViewerRefreshQueue then
        ViewerRefreshQueue.request(QK_ESSENTIAL, false)
        ViewerRefreshQueue.request(QK_UTILITY, false)
    else
        local skillsDB = get and get("VFlow.Skills")
        if skillsDB then
            if EssentialCooldownViewer and skillsDB.importantSkills then
                RefreshSkillViewer(EssentialCooldownViewer, skillsDB.importantSkills)
            end
            if UtilityCooldownViewer and skillsDB.efficiencySkills then
                RefreshSkillViewer(UtilityCooldownViewer, skillsDB.efficiencySkills)
            end
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

    if ViewerRefreshQueue then
        local function getSkillsDB()
            return VFlow.Store and VFlow.Store.getModuleRef and VFlow.Store.getModuleRef("VFlow.Skills")
        end
        ViewerRefreshQueue.register(QK_ESSENTIAL, function()
            local db = getSkillsDB()
            if db and db.importantSkills and EssentialCooldownViewer then
                RefreshSkillViewer(EssentialCooldownViewer, db.importantSkills)
            end
        end)
        ViewerRefreshQueue.register(QK_UTILITY, function()
            local db = getSkillsDB()
            if db and db.efficiencySkills and UtilityCooldownViewer then
                RefreshSkillViewer(UtilityCooldownViewer, db.efficiencySkills)
            end
        end)
        ViewerRefreshQueue.register(QK_BUFF_ICONS, function()
            DoBuffRefresh(0)
        end)
        ViewerRefreshQueue.register(QK_BUFF_BAR, function()
            DoBuffBarRefresh(0)
        end)
    end

    local function SafeHook(obj, method, handler)
        if obj and obj[method] then
            hooksecurefunc(obj, method, handler)
        end
    end

    local function queueViewerRefresh(viewerName, immediate)
        local viewer = _G[viewerName]
        if viewer and viewer._vf_refreshing then
            viewer._vf_needsReRefresh = true
            return
        end
        if ViewerRefreshQueue then
            ViewerRefreshQueue.request(viewerName, immediate == true)
            return
        end
        local get = VFlow.Store and VFlow.Store.getModuleRef
        local skillsDB = get and get("VFlow.Skills")
        if viewerName == QK_BUFF_BAR then
            DoBuffBarRefresh(0)
        elseif viewerName == QK_BUFF_ICONS then
            DoBuffRefresh(0)
        elseif viewerName == QK_ESSENTIAL and skillsDB and skillsDB.importantSkills and EssentialCooldownViewer then
            RefreshSkillViewer(EssentialCooldownViewer, skillsDB.importantSkills)
        elseif viewerName == QK_UTILITY and skillsDB and skillsDB.efficiencySkills and UtilityCooldownViewer then
            RefreshSkillViewer(UtilityCooldownViewer, skillsDB.efficiencySkills)
        end
    end

    local function hookViewerLayoutDataAndShow(viewer, queueKey)
        if not viewer then return end
        SafeHook(viewer, "RefreshLayout", function()
            queueViewerRefresh(queueKey, false)
        end)
        SafeHook(viewer, "RefreshData", function()
            queueViewerRefresh(queueKey, false)
        end)
        viewer:HookScript("OnShow", function()
            queueViewerRefresh(queueKey, false)
        end)
        if viewer.UpdateLayout then
            SafeHook(viewer, "UpdateLayout", function()
                queueViewerRefresh(queueKey, false)
            end)
        elseif viewer.Layout then
            SafeHook(viewer, "Layout", function()
                queueViewerRefresh(queueKey, false)
            end)
        end
    end

    local buffBarReleaseHandler = function()
        if BuffBarCooldownViewer then
            StyleLayout.InvalidateCollectIconsCache(BuffBarCooldownViewer)
        end
        queueViewerRefresh(QK_BUFF_BAR, false)
    end

    local queueBuffIconAfterHighlight
    queueBuffIconAfterHighlight = function(frame)
        if not frame then return end
        StyleLayout.InvalidateCooldownViewerInfoCache(frame)
        frame._vf_cdmKind = "buff"
        local viewer, cfg = GetBuffViewerAndConfig()
        if not viewer or not cfg then return end
        TouchCustomHighlight(frame)
        queueViewerRefresh(QK_BUFF_ICONS, false)
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

    local function setupSkillCooldownViewer(viewer, queueKey, hookUtilityPoolRelease)
        if not viewer then return end
        enforceScaleOnViewer(viewer)
        if viewer.RefreshLayout then
            SafeHook(viewer, "RefreshLayout", function()
                queueViewerRefresh(queueKey, false)
            end)
        end
        viewer:HookScript("OnShow", function()
            enforceScaleOnViewer(viewer)
            queueViewerRefresh(queueKey, false)
        end)
        if viewer.UpdateSystemSettingIconSize then
            hooksecurefunc(viewer, "UpdateSystemSettingIconSize", function()
                enforceScaleOnViewer(viewer)
            end)
        end
        if viewer.OnAcquireItemFrame then
            SafeHook(viewer, "OnAcquireItemFrame", function(_, frame)
                if not frame then return end
                StyleLayout.InvalidateCollectIconsCache(viewer)
                if frame.SetScale and frame:GetScale() ~= 1 then
                    frame:SetScale(1)
                end
                HookSkillFrameForCustomHighlight(viewer, frame)
                queueViewerRefresh(queueKey, false)
            end)
        end
        if hookUtilityPoolRelease and viewer.itemFramePool and viewer.itemFramePool.Release then
            hooksecurefunc(viewer.itemFramePool, "Release", function()
                StyleLayout.InvalidateCollectIconsCache(viewer)
                queueViewerRefresh(queueKey, false)
            end)
        end
    end

    setupSkillCooldownViewer(EssentialCooldownViewer, QK_ESSENTIAL, false)
    setupSkillCooldownViewer(UtilityCooldownViewer, QK_UTILITY, true)

    if BuffIconCooldownViewer then
        hookViewerLayoutDataAndShow(BuffIconCooldownViewer, QK_BUFF_ICONS)
        SafeHook(BuffIconCooldownViewer, "OnAcquireItemFrame", function(_, frame)
            if not frame then return end
            StyleLayout.InvalidateCollectIconsCache(BuffIconCooldownViewer)
            if frame.SetScale and frame:GetScale() ~= 1 then
                frame:SetScale(1)
            end
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
                    queueViewerRefresh(QK_BUFF_ICONS, false)
                end)
            end
            frame._vf_cdmKind = "buff"
            TouchCustomHighlight(frame)
            queueViewerRefresh(QK_BUFF_ICONS, false)
        end)
    end

    if BuffBarCooldownViewer then
        hookViewerLayoutDataAndShow(BuffBarCooldownViewer, QK_BUFF_BAR)
        SafeHook(BuffBarCooldownViewer, "OnAcquireItemFrame", function(_, frame)
            if not frame then return end
            StyleLayout.InvalidateCollectIconsCache(BuffBarCooldownViewer)
            local viewer, cfg = GetBuffBarViewerAndConfig()
            if not viewer or not cfg then return end

            if frame.SetScale then frame:SetScale(1) end

            if frame.OnActiveStateChanged and not frame._vf_buffBarActiveStateHooked then
                frame._vf_buffBarActiveStateHooked = true
                hooksecurefunc(frame, "OnActiveStateChanged", function()
                    queueViewerRefresh(QK_BUFF_BAR, false)
                end)
            end

            frame._vf_barStyled = false
            local width = ResolveBuffBarWidth(cfg)
            local height = cfg.barHeight or 20
            ApplyBuffBarFrameStyle(frame, cfg, width, height)

            queueViewerRefresh(QK_BUFF_BAR, false)
        end)

        if BuffBarCooldownViewer.itemFramePool then
            hooksecurefunc(BuffBarCooldownViewer.itemFramePool, "Release", buffBarReleaseHandler)
        end

        if BuffBarCooldownViewer.Selection and not BuffBarCooldownViewer._vf_buffBarSelectionDragHooked then
            BuffBarCooldownViewer._vf_buffBarSelectionDragHooked = true
            BuffBarCooldownViewer.Selection:HookScript("OnDragStop", function()
                PersistBuffBarLayoutIfShown()
                queueViewerRefresh(QK_BUFF_BAR, false)
            end)
        end
    end

    if CooldownViewerBuffIconItemMixin and CooldownViewerBuffIconItemMixin.OnCooldownIDSet then
        hooksecurefunc(CooldownViewerBuffIconItemMixin, "OnCooldownIDSet", function(frame)
            if frame then StyleLayout.InvalidateCooldownViewerInfoCache(frame) end
            queueBuffIconAfterHighlight(frame)
        end)
    end


    if EditModeManagerFrame and not EditModeManagerFrame._vf_vflowBuffBarGeoSync then
        EditModeManagerFrame._vf_vflowBuffBarGeoSync = true
        local function syncBuffBarAfterSystemEditMode()
            C_Timer.After(0.05, function()
                local get = VFlow.Store and VFlow.Store.getModuleRef
                if not (get and get("VFlow.BuffBar")) then return end
                if not EditModeManagerFrame or not EditModeManagerFrame:IsEditModeActive() then
                    local viewer, cfg = GetBuffBarViewerAndConfig()
                    if viewer and cfg then
                        PersistBuffBarLayoutPosFromRegion(viewer, cfg, NormalizeBuffBarGrowDirection(cfg))
                    end
                end
                queueViewerRefresh(QK_BUFF_BAR, false)
            end)
        end
        hooksecurefunc(EditModeManagerFrame, "EnterEditMode", syncBuffBarAfterSystemEditMode)
        hooksecurefunc(EditModeManagerFrame, "ExitEditMode", syncBuffBarAfterSystemEditMode)
    end

    if C_EditMode and C_EditMode.SaveLayouts and not VFlow._buffBarEditSaveLayoutsHooked then
        local ok = pcall(function()
            hooksecurefunc(C_EditMode, "SaveLayouts", function()
                C_Timer.After(0, function()
                    local get = VFlow.Store and VFlow.Store.getModuleRef
                    if not (get and get("VFlow.BuffBar")) then return end
                    local viewer, cfg = GetBuffBarViewerAndConfig()
                    if viewer and cfg then
                        PersistBuffBarLayoutPosFromRegion(viewer, cfg, NormalizeBuffBarGrowDirection(cfg))
                    end
                    queueViewerRefresh(QK_BUFF_BAR, false)
                end)
            end)
        end)
        if ok then
            VFlow._buffBarEditSaveLayoutsHooked = true
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
    BumpBuffBarStyleVersion()
    if ViewerRefreshQueue then ViewerRefreshQueue.bumpVersion() end
    SetupHooks()
    RequestRefresh(0.5)
end)

-- =========================================================
-- SECTION 10: Store 监听
-- =========================================================

VFlow.Store.watch("VFlow.Skills", "CooldownStyle_Skills", function(key, value)
    if key:find("%.x$") or key:find("%.y$")
        or key:find("%.anchorFrame$") or key:find("%.relativePoint$") or key:find("%.playerAnchorPosition$") then
        return
    end
    BumpButtonStyleVersion()
    RequestRefresh(0)
end)

VFlow.Store.watch("VFlow.Buffs", "CooldownStyle_Buffs", function(key, value)
    InvalidateDBCache()
    if key:find("%.x$") or key:find("%.y$")
        or key:find("%.anchorFrame$") or key:find("%.relativePoint$") or key:find("%.playerAnchorPosition$") then
        return
    end
    BumpButtonStyleVersion()
    if ViewerRefreshQueue then ViewerRefreshQueue.bumpVersion() end
    RequestRefresh(0)
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
        RequestRefresh(0)
    end
end)

VFlow.Store.watch("VFlow.OtherFeatures", "CooldownStyle_OtherHL", function(key, _)
    if not key then return end
    if key == "highlightRules" or key:find("^highlightRules%.")
        or key == "highlightOnlyInCombat"
        or key == "highlightForm" or key:find("^highlightForm%.") then
        C_Timer.After(0, RefreshAllOtherFeatureHighlights)
    end
end)

VFlow.Store.watch("VFlow.StyleIcon", "CooldownStyle_StyleIcon", function(key, value)
    BumpButtonStyleVersion()
    BumpBuffBarStyleVersion()
    RequestRefresh(0)
    RequestBuffBarRefresh()
end)

-- StyleBuff — BUFF/BuffBar 样式 + 自定义高亮
local VFlow = _G.VFlow
if not VFlow then return end

local FD = VFlow.FD
local Utils = VFlow.Utils
local ModuleControlConstants = VFlow.ModuleControlConstants
local StyleApply = VFlow.StyleApply
local StyleLayout = VFlow.StyleLayout
local RefreshBus = VFlow.RefreshBus
local ViewerRuntime = VFlow.ViewerRuntime
local ViewerRefreshQueue = VFlow.ViewerRefreshQueue
local PP = VFlow.PixelPerfect
local MasqueSupport = VFlow.MasqueSupport
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
local abs = math.abs

local CORE_ENABLED = ModuleControlConstants.CORE_ENABLED
local BUFF_BAR_ENABLED = ModuleControlConstants.BUFF_BAR_ENABLED
if not (CORE_ENABLED or BUFF_BAR_ENABLED) then return end

local QK_BUFF_ICONS = "BuffIconCooldownViewer"
local QK_BUFF_BAR = "BuffBarCooldownViewer"
local MAX_BUFF_READY_RETRIES = 20
local MAX_BUFFBAR_READY_RETRIES = 20

-- =========================================================
-- DB 缓存
-- =========================================================
local _cachedBuffsDB
local _cachedBuffBarDB

local function InvalidateDBCache()
    local store = VFlow and VFlow.Store
    if not store or not store.getModuleRef then return end
    _cachedBuffsDB = CORE_ENABLED and store.getModuleRef("VFlow.Buffs") or nil
    _cachedBuffBarDB = BUFF_BAR_ENABLED and store.getModuleRef("VFlow.BuffBar") or nil
end

local function GetBuffViewerAndConfig()
    if not CORE_ENABLED then return nil, nil end
    local viewer = _G.BuffIconCooldownViewer
    local cfg = _cachedBuffsDB and _cachedBuffsDB.buffMonitor
    return viewer, cfg
end

local function GetBuffBarViewerAndConfig()
    if not BUFF_BAR_ENABLED then return nil, nil end
    local viewer = _G.BuffBarCooldownViewer
    return viewer, _cachedBuffBarDB
end

-- =========================================================
-- BuffBar 样式版本
-- =========================================================
local _buffBarStyleVersion = 0

local function BumpBuffBarStyleVersion()
    _buffBarStyleVersion = _buffBarStyleVersion + 1
end

-- =========================================================
-- Buff 条解析与帧收集
-- =========================================================

local function ResolveStatusBarTexture(textureName)
    if not textureName or textureName == "" or textureName == "默认" then
        return "Interface\\Buttons\\WHITE8X8"
    end
    if LSM then
        local path = LSM:Fetch("statusbar", textureName)
        if path then return path end
    end
    return textureName
end

local function ResolveBuffBarWidth(cfg)
    local width = cfg and cfg.barWidth or 200
    if not width or width <= 0 then return 200 end
    return width
end

local function CollectBuffBarFrames(viewer)
    if not viewer then return {} end
    local vfd = FD(viewer)
    local frames = vfd.cdf_bar_collect_work
    if not frames then
        frames = {}
        vfd.cdf_bar_collect_work = frames
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
-- 自定义高亮（SharedSettings / StyleGlow）
-- =========================================================

local SHARED_SETTINGS_KEY = "VFlow.OtherFeatures"

local function GetSharedSettingsDB()
    if not CORE_ENABLED then return nil end
    local store = VFlow.Store
    if not store or not store.getModuleRef then return nil end
    return store.getModuleRef(SHARED_SETTINGS_KEY)
end

local function GetSharedSettingsHighlightRule(spellID)
    if not spellID then return nil end
    local db = GetSharedSettingsDB()
    if not db then return nil end
    local rules = db.highlightRules
    if not rules then return nil end
    local r = rules[spellID] or rules[tostring(spellID)]
    if type(r) ~= "table" or not r.enabled then return nil end
    return r
end

local function SharedSettingsHighlightOnlyInCombat()
    local db = GetSharedSettingsDB()
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
            if spellID and spellID > 0 then return spellID end
        end
    end
    return nil
end

local function GetSpellStateWatcher()
    return VFlow.SpellStateWatcher
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
    local kind = FD(frame).cdmKind
    if kind == "skill" or kind == "buff" then
        return kind
    end
    return InferCdmKindFromParent(frame)
end

local function HighlightRuleMatchesKind(rule, kind)
    if not rule or not kind then return false end
    local src = rule.source
    if not src or src == "" then return true end
    if src == "skill" then return kind == "skill" end
    if src == "buff" then return kind == "buff" end
    return false
end

-- 仅受 GCD 锁时仍视为「可用」
local function SkillCooldownIsGcdOnly(spellID)
    if not spellID or not C_Spell or not C_Spell.GetSpellCooldown then return false end
    local ok, info = pcall(function() return C_Spell.GetSpellCooldown(spellID) end)
    if not ok or type(info) ~= "table" then return false end
    return info.isOnGCD == true
end

local function SkillIconAppearsReady(frame)
    if not frame or not frame:IsShown() then return false end
    local spellID = ResolveHighlightSpellID(frame)
    if spellID and SkillCooldownIsGcdOnly(spellID) then return true end
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
    if not CORE_ENABLED then return end
    if not StyleApply or not StyleApply.ShowCustomGlow or not StyleApply.HideCustomGlow then return end
    local kind = GetCdmFrameKind(frame)
    local spellID = ResolveHighlightSpellID(frame)
    local rule = spellID and GetSharedSettingsHighlightRule(spellID)
    local wantGlow = false
    if rule and HighlightRuleMatchesKind(rule, kind) then
        if kind == "skill" then
            wantGlow = SkillIconAppearsReady(frame)
        elseif kind == "buff" then
            wantGlow = BuffIconAppearsActive(frame)
        end
    end
    if wantGlow and SharedSettingsHighlightOnlyInCombat() and not IsPlayerInCombatForCustomHighlight() then
        wantGlow = false
    end
    if wantGlow then
        StyleApply.ShowCustomGlow(frame)
    else
        StyleApply.HideCustomGlow(frame)
    end
end

-- BUFF 激活瞬间会连续触发 CD 更新 / RefreshData / OnActiveStateChanged，合并到帧末只算一次
-- 技能图标也必须延迟：SetCooldown hook 若在暴雪 RefreshData/充能缓存链内同步调用 C_Spell.GetSpellCooldown，
-- 会使 spellChargeInfo.maxCharges 等 secret 带上 VFlow 污染
local pendingCustomHLBatch1, pendingCustomHLBatch2 = {}, {}
local pendingCustomHLFrames = pendingCustomHLBatch1
local customHLFlushFrame = CreateFrame("Frame")
customHLFlushFrame:Hide()
local function customHLFlushOnUpdate(self)
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
    if not CORE_ENABLED then return end
    if not frame then return end
    pendingCustomHLFrames[frame] = true
    customHLFlushFrame:Show()
end

local function EnsureCustomHighlightWatchOwner(frame)
    if not frame then return nil end
    local fd = FD(frame)
    if not fd.customHLWatchOwner then
        fd.customHLWatchOwner = { frame = frame }
    end
    return fd.customHLWatchOwner
end

local function ReleaseCustomHighlightWatcher(frame)
    if not frame then return end
    local fd = FD(frame)
    if not fd.customHLWatchedSpellID then return end
    local watcher = GetSpellStateWatcher()
    local ownerKey = fd.customHLWatchOwner
    if watcher and ownerKey then
        watcher.unwatch(ownerKey, fd.customHLWatchedSpellID)
    end
    fd.customHLWatchedSpellID = nil
end

local function SyncCustomHighlightWatcher(frame)
    if not CORE_ENABLED or not frame or not frame.Icon then return end

    local fd = FD(frame)
    local kind = GetCdmFrameKind(frame)
    local isShown = frame.IsShown and frame:IsShown()
    local spellID = isShown and ResolveHighlightSpellID(frame) or nil
    local rule = spellID and GetSharedSettingsHighlightRule(spellID)
    local shouldWatch = isShown and rule and HighlightRuleMatchesKind(rule, kind)

    if shouldWatch and spellID == fd.customHLWatchedSpellID then return end

    ReleaseCustomHighlightWatcher(frame)
    if not shouldWatch or not spellID then return end

    local watcher = GetSpellStateWatcher()
    if not watcher then return end

    local ownerKey = EnsureCustomHighlightWatchOwner(frame)
    if watcher.watch(ownerKey, spellID, function()
        RequestCustomHighlightUpdate(frame)
    end) then
        fd.customHLWatchedSpellID = spellID
    end
end

local function EnsureCustomHighlightHooks(frame)
    if not CORE_ENABLED then return end
    if not frame or frame._vf_customHLHooked then return end
    frame._vf_customHLHooked = true
    if frame.HookScript then
        frame:HookScript("OnShow", function(self)
            SyncCustomHighlightWatcher(self)
            RequestCustomHighlightUpdate(self)
        end)
        frame:HookScript("OnHide", function(self)
            pendingCustomHLFrames[self] = nil
            pendingCustomHLBatch1[self] = nil
            pendingCustomHLBatch2[self] = nil
            ReleaseCustomHighlightWatcher(self)
            if StyleApply and StyleApply.HideCustomGlow then
                StyleApply.HideCustomGlow(self)
            end
        end)
    end
end

local function TouchCustomHighlight(frame)
    if not CORE_ENABLED then return end
    if not frame or not frame.Icon then return end
    EnsureCustomHighlightHooks(frame)
    SyncCustomHighlightWatcher(frame)
    RequestCustomHighlightUpdate(frame)
end

local function ScanCooldownViewerIcons(viewer, icons)
    if not CORE_ENABLED then return end
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
    if not CORE_ENABLED then return end
    ScanCooldownViewerIcons(_G.EssentialCooldownViewer)
    ScanCooldownViewerIcons(_G.UtilityCooldownViewer)
    ScanCooldownViewerIcons(_G.BuffIconCooldownViewer)
    ScanSkillGroupCustomHighlights()
    ScanBuffGroupCustomHighlights()
end

if CORE_ENABLED then
    VFlow.on("PLAYER_REGEN_ENABLED", "VFlow.CustomHL.OutOfCombat", function()
        RefreshAllOtherFeatureHighlights()
    end)
    VFlow.on("PLAYER_REGEN_DISABLED", "VFlow.CustomHL.InCombat", function()
        RefreshAllOtherFeatureHighlights()
    end)
end

-- =========================================================
-- 工具函数
-- =========================================================

local function IsSafeEqual(v, expected)
    if type(v) == "number" and issecretvalue and issecretvalue(v) then return false end
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
-- BuffBar 辅助
-- =========================================================

local RequestBuffRefresh
local RequestBuffBarRefresh

local function QueueBuffBarRefresh(opt)
    if not BUFF_BAR_ENABLED then return end
    opt = opt or {}
    local viewer = _G.BuffBarCooldownViewer
    if viewer and FD(viewer).refreshing then
        FD(viewer).needsReRefresh = true
        return
    end
    if ViewerRuntime and ViewerRuntime.request then
        ViewerRuntime.request(QK_BUFF_BAR, "manual", opt)
        return
    end
    -- 运行时回退：StyleEngine 已加载
    local fn = VFlow._RequestNamedViewers
    if fn then
        fn(RefreshBus.PRESETS.BUFFBAR_FULL, { QK_BUFF_BAR }, opt)
    end
end

local function HookBarTextVisibility(frame, hookKey, textElement, cfgKey)
    if not frame or not textElement or frame[hookKey] then return end
    frame[hookKey] = true
    hooksecurefunc(textElement, "Show", function(self)
        local localCfg = FD(frame).barCfg
        if localCfg and localCfg[cfgKey] == false then
            self:Hide()
        end
    end)
end

local function EnsureBarBackground(bar)
    if not bar then return nil end
    local fd = FD(bar)
    if not fd.bg then
        local bg = bar:CreateTexture(nil, "BACKGROUND", nil, -1)
        bg:ClearAllPoints()
        bg:SetAllPoints(bar)
        fd.bg = bg
    end
    return fd.bg
end

local function EnsureBarBorder(bar)
    if not bar or not PP then return end
    local fd = FD(bar)
    if not fd.borderFrame then
        local borderFrame = CreateFrame("Frame", nil, bar)
        borderFrame:SetAllPoints(bar)
        borderFrame:SetFrameLevel((bar:GetFrameLevel() or 1) + 2)
        fd.borderFrame = borderFrame
    end
    PP.CreateBorder(fd.borderFrame, 1, { r = 0, g = 0, b = 0, a = 1 }, true)
    PP.ShowBorder(fd.borderFrame)
end

local function ApplyBuffBarFrameStyle(frame, cfg, frameWidth, frameHeight)
    if not frame or not cfg then return end

    StyleApply.ApplyViewerItemVisualHides(frame)

    local barStyleVer = _buffBarStyleVersion
    local iconPosition = cfg.iconPosition or "LEFT"

    local fd = FD(frame)

    -- 脏检查：版本+尺寸+图标位置均未变则跳过
    if fd.barStyled
        and fd.barStyleVer == barStyleVer
        and fd.barW == frameWidth
        and fd.barH == frameHeight
        and fd.barIconPos == iconPosition
    then
        return
    end

    fd.barCfg = cfg
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

    -- 一次性隐藏系统默认元素
    if not fd.barHidesDone then
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
        fd.barHidesDone = true
    end

    -- 图标 Show hook（一次性）
    if icon and not frame._vf_iconShowHooked then
        frame._vf_iconShowHooked = true
        hooksecurefunc(icon, "Show", function(self)
            local localCfg = FD(frame).barCfg
            if localCfg and localCfg.iconPosition == "HIDDEN" then
                self:Hide()
            end
        end)
    end

    -- 图标布局
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

    -- 背景
    local bgTex = EnsureBarBackground(bar)
    if bgTex and cfg.barBackgroundColor then
        local bc = cfg.barBackgroundColor
        bgTex:SetTexture(ResolveStatusBarTexture(cfg.barTexture))
        bgTex:SetVertexColor(bc.r or 0.1, bc.g or 0.1, bc.b or 0.1, bc.a or 0.8)
        bgTex:Show()
    end

    -- 边框
    EnsureBarBorder(bar)

    -- 文本容器
    if bar and not fd.barTextContainer then
        local tc = CreateFrame("Frame", nil, bar)
        tc:SetAllPoints(bar)
        tc:SetFrameLevel((bar:GetFrameLevel() or 1) + 4)
        fd.barTextContainer = tc
    end
    local textContainer = fd.barTextContainer

    -- 名称文本
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

    -- 持续时间文本
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

    -- 层数文本
    if appText then
        HookBarTextVisibility(frame, "_vf_stackHook", appText, "showStack")
        if cfg.showStack == false then
            appText:Hide()
            if fd.barAppContainer then
                fd.barAppContainer:Hide()
            end
        else
            if bar and not fd.barAppContainer then
                local container = CreateFrame("Frame", nil, bar)
                container:SetAllPoints(bar)
                container:SetFrameLevel((bar:GetFrameLevel() or 1) + 4)
                fd.barAppContainer = container
            end
            if fd.barAppContainer then
                fd.barAppContainer:Show()
                appText:SetParent(fd.barAppContainer)
            end
            appText:Show()
            appText:SetAlpha(1)
            if appText.SetDrawLayer then
                appText:SetDrawLayer("OVERLAY", 7)
            end
            StyleApply.ApplyFontStyle(appText, cfg.stackFont, "_vf_bar_stack")
        end
    end

    fd.barStyled = true
    fd.barStyleVer = barStyleVer
    fd.barW = frameWidth
    fd.barH = frameHeight
    fd.barIconPos = iconPosition
end

-- =========================================================
-- Viewer 刷新
-- =========================================================

local function IsViewerReady(viewer)
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

local function RefreshBuffBarViewer(viewer, cfg)
    if not viewer or not cfg then return false end
    local vfd = FD(viewer)
    if vfd.refreshing then
        vfd.needsReRefresh = true
        return false
    end
    if not IsViewerReady(viewer) then return false end

    vfd.refreshing = true
    vfd.needsReRefresh = false

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
        vfd.refreshing = false
        if vfd.needsReRefresh then
            vfd.needsReRefresh = false
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

        -- 当前仅支持"居中锚点下的固定排布"，避免与系统 EditMode 锚点策略冲突
        StyleLayout.SetPointCached(frame, "TOPLEFT", viewer, "TOPLEFT", 0, -offset)
        frame:SetAlpha(1)
    end

    vfd.refreshing = false

    if vfd.needsReRefresh then
        vfd.needsReRefresh = false
        QueueBuffBarRefresh()
    end

    return true
end

local function RefreshBuffViewer(viewer, cfg)
    if not viewer or not cfg then return false end
    local vfd = FD(viewer)
    if vfd.refreshing then
        vfd.needsReRefresh = true
        return false
    end
    if not IsViewerReady(viewer) then return false end
    vfd.refreshing = true

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
        FD(button).slot = slot

        local x, y = ComputeSlotOffset(slot, totalSlots, isH, w, h, spacingX, spacingY, iconDir)

        StyleApply.ApplyIconSize(button, w, h)
        StyleApply.ApplyButtonStyleIfStale(button, cfg)

        if MasqueSupport and MasqueSupport:IsActive() then
            MasqueSupport:RegisterButton(button, button.Icon)
        end

        FD(button).cdmKind = "buff"

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

    vfd.refreshing = false

    if vfd.needsReRefresh then
        vfd.needsReRefresh = false
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
-- 刷新请求入口
-- =========================================================

local function DoBuffRefresh(attempt)
    local viewer, cfg = GetBuffViewerAndConfig()
    if not viewer or not cfg then return end
    if not IsViewerReady(viewer) then
        if (attempt or 0) < MAX_BUFF_READY_RETRIES then
            C_Timer.After(0.05, function() DoBuffRefresh((attempt or 0) + 1) end)
        end
        return
    end
    local ok = RefreshBuffViewer(viewer, cfg)
    if not ok then
        if viewer and FD(viewer).needsReRefresh then
            -- 重入已标记，由刷新末尾再次入队
        elseif (attempt or 0) < MAX_BUFF_READY_RETRIES then
            C_Timer.After(0.05, function() DoBuffRefresh((attempt or 0) + 1) end)
        end
    end
end

RequestBuffRefresh = function(opt)
    opt = opt or {}
    if ViewerRuntime and ViewerRuntime.request then
        ViewerRuntime.request(QK_BUFF_ICONS, "manual", opt)
        return
    end
    local fn = VFlow._RequestNamedViewers
    if fn then
        fn(RefreshBus.PRESETS.BUFF_FULL, { QK_BUFF_ICONS }, opt)
    end
end

local function DoBuffBarRefresh(attempt)
    local viewer, cfg = GetBuffBarViewerAndConfig()
    if not viewer or not cfg then return end
    if not IsViewerReady(viewer) then
        if (attempt or 0) < MAX_BUFFBAR_READY_RETRIES then
            C_Timer.After(0.05, function() DoBuffBarRefresh((attempt or 0) + 1) end)
        end
        return
    end
    local ok = RefreshBuffBarViewer(viewer, cfg)
    if not ok then
        if viewer and FD(viewer).needsReRefresh then
            -- 重入已标记，由刷新末尾再次入队
        elseif (attempt or 0) < MAX_BUFFBAR_READY_RETRIES then
            C_Timer.After(0.05, function() DoBuffBarRefresh((attempt or 0) + 1) end)
        end
    end
end

RequestBuffBarRefresh = function(opt)
    QueueBuffBarRefresh(opt)
end

-- =========================================================
-- 导出
-- =========================================================

VFlow.StyleBuff = {
    InvalidateDBCache = InvalidateDBCache,
    GetBuffViewerAndConfig = GetBuffViewerAndConfig,
    GetBuffBarViewerAndConfig = GetBuffBarViewerAndConfig,
    BumpBuffBarStyleVersion = BumpBuffBarStyleVersion,
    ResolveBuffBarWidth = ResolveBuffBarWidth,
    ApplyBuffBarFrameStyle = ApplyBuffBarFrameStyle,
    TouchCustomHighlight = TouchCustomHighlight,
    EnsureCustomHighlightHooks = EnsureCustomHighlightHooks,
    ScanCooldownViewerIcons = ScanCooldownViewerIcons,
    ScanSkillGroupCustomHighlights = ScanSkillGroupCustomHighlights,
    RefreshAllOtherFeatureHighlights = RefreshAllOtherFeatureHighlights,
    DoBuffRefresh = DoBuffRefresh,
    DoBuffBarRefresh = DoBuffBarRefresh,
    RequestBuffRefresh = RequestBuffRefresh,
    RequestBuffBarRefresh = RequestBuffBarRefresh,
}
